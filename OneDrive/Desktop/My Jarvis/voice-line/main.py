"""Entry point: the turn loop, hold-to-talk wiring, typed input.

Windows gotcha that shapes this whole file: the default asyncio event loop
on Windows is ProactorEventLoop (needed by the Claude Agent SDK for
subprocess handling), and Proactor does NOT implement
asyncio.add_reader(). So input is never read that way here - the PTT key
listener (pynput) and the typed-line reader (msvcrt) both run on their own
background threads and hand events to the asyncio loop with
call_soon_threadsafe / run_coroutine_threadsafe.

Typed input is first-class: a typed line goes into the exact same handler
as a spoken utterance, so the reply is spoken aloud, typing while it talks
interrupts playback, and the quit phrases work typed too.
"""

from __future__ import annotations

import argparse
import asyncio
import ctypes
import msvcrt
import os
import re
import sys
import threading

import importlib.util, sys, pathlib
# Prefer the project root on import so voice-line imports (ears, mouth, etc.)
# resolve to the unified modules in the repository root instead of the
# voice-line subfolder's copies.
_project_root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_project_root))
_root = _project_root / "brain.py"
_spec = importlib.util.spec_from_file_location("brain", str(_root))
_root_brain = importlib.util.module_from_spec(_spec)
sys.modules["brain"] = _root_brain
_spec.loader.exec_module(_root_brain)
brain = _root_brain
import ears
import fastpath
import mouth
import ptt
import signals
import timing

def _resolve_identity_cwd() -> str:
    r"""The folder CLAUDE.md and the vault live in - Jarvis's identity.

    Resolved from the current user's profile, NEVER hardcoded. This path sits
    on OneDrive-synced storage that lands on several of Brian's machines under
    different Windows usernames (bclar on the office PC, BrianClark on the
    spare), so a baked-in absolute path is only ever correct on whichever
    machine last wrote it. CLAUDE.md records this exact trap biting four
    separate times; this file was the fifth, found 2026-08-02.

    Deliberately NOT applied to remote_server.py, which keeps its hardcoded
    C:\Users\BrianClark\... path on purpose: the voice-line-remote service runs
    as LocalSystem, where expanduser("~") resolves to
    C:\Windows\System32\config\systemprofile - so "fixing" it the same way
    would break the browser client. Do not tidy that one to match this.
    """
    return os.path.join(os.path.expanduser("~"), "OneDrive", "Desktop", "My Jarvis")


IDENTITY_CWD = _resolve_identity_cwd()


def _check_identity_cwd() -> None:
    """Refuse to start if the vault folder isn't where we resolved it.

    Without this the SDK is simply handed a bad cwd: connect() fails and
    brain.py speaks "Sorry, I couldn't connect on my end." - which sounds like
    an auth or network fault and sends the next session chasing the wrong
    thing entirely. And if it ever did come up, it would be generic Claude
    Code with no identity, no vault and none of the standing rules, while
    still sounding perfectly fine. Both are the silent-failure signature this
    system keeps getting bitten by, so fail loudly and name the actual path.
    """
    if os.path.isdir(IDENTITY_CWD):
        return
    print(
        "\n[voice-line] FATAL: cannot find the Jarvis vault folder.\n"
        f"  Resolved to: {IDENTITY_CWD}\n"
        f"  From:        {os.path.expanduser('~')}\n"
        "  That folder does not exist. Check OneDrive is synced and that the\n"
        "  'My Jarvis' folder is on this account's Desktop. Refusing to start\n"
        "  rather than come up without the vault and the standing rules.\n",
        file=sys.stderr,
    )
    raise SystemExit(1)


GREETING = "Hey Brian, how are you today? How can I help?"

# --- typed input: console mode + paste handling -----------------------------

STD_INPUT_HANDLE = -10
STD_OUTPUT_HANDLE = -11
ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200
ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

PASTE_START = "\x1b[200~"
PASTE_END = "\x1b[201~"
PASTE_ECHO_THRESHOLD = 60  # longer than this, echo a count instead of the text

_GUTTER_RE = re.compile(r"^\s*(?:\d+[:.)]\s+|[>|│]\s?)+")


def _enable_vt_console_modes() -> None:
    """Enable ENABLE_VIRTUAL_TERMINAL_INPUT so Windows Terminal's
    bracketed-paste escape sequences reach us instead of being swallowed by
    the console's default line-editing layer."""
    try:
        kernel32 = ctypes.windll.kernel32
        for handle_id, extra_flag in (
            (STD_INPUT_HANDLE, ENABLE_VIRTUAL_TERMINAL_INPUT),
            (STD_OUTPUT_HANDLE, ENABLE_VIRTUAL_TERMINAL_PROCESSING),
        ):
            handle = kernel32.GetStdHandle(handle_id)
            mode = ctypes.c_uint32()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                kernel32.SetConsoleMode(handle, mode.value | extra_flag)
    except Exception:
        pass


def _clean_paste(text: str) -> str:
    """Scrub gutter glyphs (line numbers, '>' quote markers, '|' rules) and
    hard line-wraps out of pasted text, assembling it into flowing prose."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [_GUTTER_RE.sub("", ln).rstrip() for ln in text.split("\n")]

    paragraphs: list[str] = []
    current: list[str] = []
    for ln in lines:
        if ln.strip() == "":
            if current:
                paragraphs.append(" ".join(current))
                current = []
        else:
            current.append(ln.strip())
    if current:
        paragraphs.append(" ".join(current))
    return "\n\n".join(paragraphs).strip()


class TypedInput:
    """Character-level console reader on a background thread (msvcrt has no
    termios/cbreak on Windows). Runs a tiny line editor on top, with
    paste-aware assembly: a bracketed paste is buffered invisibly and
    committed as one block instead of echoing keystroke by keystroke."""

    def __init__(self, loop: asyncio.AbstractEventLoop, on_keypress=None):
        self.loop = loop
        self.on_keypress = on_keypress  # called on every real character, from the bg thread
        self.lines: asyncio.Queue[str] = asyncio.Queue()
        self._thread = None
        self._stop = False

    def start(self) -> None:
        _enable_vt_console_modes()
        try:
            sys.stdout.write("\x1b[?2004h")  # ask the terminal for bracketed paste
            sys.stdout.flush()
        except Exception:
            pass

        self._thread = threading.Thread(target=self._read_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop = True
        try:
            sys.stdout.write("\x1b[?2004l")
            sys.stdout.flush()
        except Exception:
            pass

    def _read_loop(self) -> None:
        buf: list[str] = []
        paste_mode = False
        paste_buf: list[str] = []
        escape_buf = ""

        while not self._stop:
            try:
                ch = msvcrt.getwch()
            except Exception:
                break

            if self.on_keypress is not None:
                try:
                    self.on_keypress()
                except Exception:
                    pass

            if paste_mode:
                paste_buf.append(ch)
                tail = "".join(paste_buf[-len(PASTE_END) :])
                if tail == PASTE_END:
                    full = "".join(paste_buf)[: -len(PASTE_END)]
                    paste_mode = False
                    paste_buf = []
                    self._commit_paste(buf, full)
                continue

            if ch == "\x1b" or escape_buf:
                escape_buf += ch
                if PASTE_START.startswith(escape_buf):
                    if escape_buf == PASTE_START:
                        paste_mode = True
                        paste_buf = []
                        escape_buf = ""
                    continue
                escape_buf = ""
                continue

            if ch in ("\r", "\n"):
                line = "".join(buf)
                buf = []
                sys.stdout.write("\n")
                sys.stdout.flush()
                self.loop.call_soon_threadsafe(self.lines.put_nowait, line)
            elif ch in ("\x08", "\x7f"):
                if buf:
                    buf.pop()
                    sys.stdout.write("\b \b")
                    sys.stdout.flush()
            else:
                buf.append(ch)
                sys.stdout.write(ch)
                sys.stdout.flush()

    def _commit_paste(self, buf: list[str], raw_text: str) -> None:
        cleaned = _clean_paste(raw_text)
        buf.extend(cleaned)
        try:
            if len(cleaned) > PASTE_ECHO_THRESHOLD:
                sys.stdout.write(f"[pasted {len(cleaned)} characters]")
            else:
                sys.stdout.write(cleaned)
            sys.stdout.flush()
        except Exception:
            pass

    async def next_line(self) -> str:
        return await self.lines.get()


# --- the turn loop -----------------------------------------------------------


async def run(open_mic: bool, ptt_key=ptt.PTT_KEY) -> None:
    loop = asyncio.get_running_loop()

    m = mouth.Mouth()
    await m.start()

    b = brain.Brain(cwd=IDENTITY_CWD, mouth=m)
    await b.start()

    current_turn_task: asyncio.Task | None = None
    warmup_task: asyncio.Task | None = None
    quit_event = asyncio.Event()

    async def interrupt_current() -> None:
        nonlocal current_turn_task
        await m.interrupt()
        await b.interrupt()
        # warmup() and a real turn share one client stream (query + a
        # receive_response() loop) - interrupting the CLI mid-warmup is
        # fine, but warmup_task itself must be allowed to actually unwind
        # before anything sends a new query, or two receive_response()
        # iterators race on the same messages.
        if warmup_task is not None and not warmup_task.done():
            try:
                await warmup_task
            except (asyncio.CancelledError, Exception):
                pass
        if current_turn_task is not None and not current_turn_task.done():
            # b.interrupt() (above) already told handle_turn() to drain its
            # response silently to that turn's ResultMessage rather than
            # stop dead - cancelling the task here instead would abandon
            # that drain and leave the interrupted turn's trailing messages
            # sitting in the SDK's shared queue, where the NEXT turn's
            # receive_response() would mistake them for its own result
            # (the root cause of the one-turn-behind lag). Only cancel as a
            # last resort if the drain itself never reaches a ResultMessage.
            try:
                await asyncio.wait_for(current_turn_task, timeout=10.0)
            except asyncio.TimeoutError:
                current_turn_task.cancel()
                try:
                    await current_turn_task
                except (asyncio.CancelledError, Exception):
                    pass
            except (asyncio.CancelledError, Exception):
                pass
        current_turn_task = None

    async def start_turn(text: str) -> None:
        nonlocal current_turn_task
        if current_turn_task is not None and not current_turn_task.done():
            await interrupt_current()
        current_turn_task = asyncio.ensure_future(_handle_turn(text))

    async def _handle_turn(text: str) -> None:
        # Never let a real query overlap warmup()'s in-flight query on the
        # same client stream - wait for it to finish first (usually already
        # has, by the time speech was captured and transcribed).
        if warmup_task is not None and not warmup_task.done():
            try:
                await warmup_task
            except Exception:
                pass

        if brain.is_quit_phrase(text):
            signals.write_state("thinking")
            await m.speak("Goodbye.")
            await m.end_turn()
            while m.is_speaking() or not m.audio_q.empty() or not m.sentence_q.empty():
                await asyncio.sleep(0.1)
            quit_event.set()
            return
        signals.write_state("thinking")
        m.start_thinking_sound()
        timing.mark("brain_handle_turn_call")
        try:
            await b.handle_turn(text)
        finally:
            m.stop_thinking_sound()

    def on_typed_keypress() -> None:
        if m.is_speaking():
            asyncio.run_coroutine_threadsafe(interrupt_current(), loop)

    typed = TypedInput(loop, on_keypress=on_typed_keypress)
    typed.start()

    e = ears.Ears()
    ptt_listener: ptt.PTTListener | None = None
    open_mic_task: asyncio.Task | None = None

    async def on_open_mic_utterance(text: str) -> None:
        await start_turn(text)

    if open_mic:
        listener = ears.OpenMicListener()
        open_mic_task = asyncio.ensure_future(listener.listen(on_open_mic_utterance))
    else:
        ptt_listener = ptt.PTTListener(loop, key=ptt_key)
        ptt_listener.start()

    # Hide the first-turn prompt-cache toll behind a spoken greeting: the
    # greeting plays immediately while warmup() pays that toll in the
    # background, so the user's real first turn already lands warm.
    await m.speak(GREETING)
    await m.end_turn()
    warmup_task = asyncio.ensure_future(b.warmup())

    print(
        f"Voice line running. Hold {ptt_key} to talk"
        + (" (--open-mic active)" if open_mic else "")
        + ", or type and press Enter. Say 'goodbye' to end (Ctrl-C also works)."
    )

    pending_typed = asyncio.ensure_future(typed.next_line())
    pending_ptt = asyncio.ensure_future(ptt_listener.next_event()) if ptt_listener else None
    # quit_event can be set by a turn task that --open-mic (or a stray
    # background task) spawned outside this loop's control, after this
    # iteration's wait-set was already snapshotted - so quit needs its own
    # standing future here rather than piggybacking on current_turn_task
    # being present, or a "goodbye" via open-mic would never actually end
    # the session until some unrelated event also fired.
    pending_quit = asyncio.ensure_future(quit_event.wait())
    recording = False

    try:
        while not quit_event.is_set():
            waiters = [pending_typed, pending_quit]
            if pending_ptt is not None:
                waiters.append(pending_ptt)
            if current_turn_task is not None:
                waiters.append(current_turn_task)

            done, _ = await asyncio.wait(waiters, return_when=asyncio.FIRST_COMPLETED)

            if quit_event.is_set():
                break

            if pending_ptt is not None and pending_ptt in done:
                event = pending_ptt.result()
                pending_ptt = asyncio.ensure_future(ptt_listener.next_event())

                if event == ptt.PRESS:
                    if m.is_speaking() or (
                        current_turn_task is not None and not current_turn_task.done()
                    ):
                        await interrupt_current()
                    signals.write_state("listening")
                    e.start_recording()
                    recording = True

                elif event == ptt.RELEASE and recording:
                    recording = False
                    timing.start_turn("ptt_release")
                    signals.write_state("thinking")
                    m.start_thinking_sound()
                    pcm = await e.stop_recording()
                    timing.mark("pcm_captured")
                    if pcm is None:
                        m.stop_thinking_sound()
                        signals.write_state("idle")
                    else:
                        text = await e.transcribe(pcm)
                        timing.mark("transcribed")
                        text = ears.strip_non_speech_markers(text)
                        m.stop_thinking_sound()
                        if not text:
                            signals.write_state("idle")
                        # ⚠ FAST PATH, added 2026-08-01. Short device commands
                        # ("click", "volume up seven") are dispatched straight to
                        # the TV daemon and the model is never woken - measured
                        # 8.0 s -> ~0.45 s, because the model was 94% of the wait.
                        #
                        # fastpath.try_handle FAILS OPEN by contract: anything it
                        # does not recognise, and any exception inside it, returns
                        # False and falls through to start_turn() exactly as
                        # before. Deleting the two lines below restores the old
                        # behaviour completely; creating ~/voice-line/FASTPATH_OFF
                        # disables it with no code change at all.
                        elif fastpath.try_handle(text):
                            print(f"> {text}   [fast path]")
                            signals.write_state("idle")
                        else:
                            print(f"> {text}")
                            await start_turn(text)

            if pending_typed in done:
                line = pending_typed.result().strip()
                pending_typed = asyncio.ensure_future(typed.next_line())
                if line:
                    timing.start_turn("typed_line")
                    await start_turn(line)

            if current_turn_task is not None and current_turn_task.done():
                try:
                    current_turn_task.result()
                except (asyncio.CancelledError, Exception):
                    pass
                current_turn_task = None

    except KeyboardInterrupt:
        pass
    finally:
        for task in (pending_typed, pending_ptt, pending_quit, open_mic_task, warmup_task, current_turn_task):
            if task is not None and not task.done():
                task.cancel()
        typed.stop()
        if ptt_listener is not None:
            ptt_listener.stop()
        await m.shutdown()
        await b.shutdown()


def main() -> None:
    parser = argparse.ArgumentParser(description="Voice line - hold-to-talk voice conversation")
    parser.add_argument(
        "--open-mic",
        action="store_true",
        help="Legacy always-open mic with VAD endpointing, instead of hold-to-talk. "
        "Room audio (video, music, another assistant's voice) can false-trigger this.",
    )
    args = parser.parse_args()
    # After parse_args so --help still works on a machine without the vault.
    _check_identity_cwd()
    try:
        asyncio.run(run(open_mic=args.open_mic))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
