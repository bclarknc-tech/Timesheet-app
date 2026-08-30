"""Remote voice bridge: lets a browser (on any device, anywhere Tailscale
reaches) talk to Jarvis without needing a mic or speakers on this machine.

This machine runs the heavy stuff - Whisper, Kokoro, the Claude session -
same as main.py does locally. The difference is where the mic and speakers
live: instead of sounddevice talking to local hardware, this server takes
recorded audio over a WebSocket from the browser client (static/index.html),
transcribes it, runs it through the same Brain turn logic main.py uses, and
streams synthesized speech back over the same WebSocket.

One conversation at a time, matching the local app's single-session design
- a second browser connecting while one is already active gets rejected
outright rather than silently taking over or interleaving with the first.

RemoteMouth below is a drop-in replacement for mouth.Mouth: it implements
the same speak()/end_turn() interface SentenceBatcher and Brain.handle_turn()
already call, so brain.py needed zero changes to be reused here. Only the
"how audio actually reaches the user" part differs.
"""

from __future__ import annotations

import asyncio
import io
import wave

import httpx
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

import importlib.util, sys, pathlib
# Prefer the project root on import so voice-line imports resolve to the
# repository root's modules (ears, mouth, etc.).
_project_root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_project_root))
_root = _project_root / "brain.py"
_spec = importlib.util.spec_from_file_location("brain", str(_root))
_root_brain = importlib.util.module_from_spec(_spec)
sys.modules["brain"] = _root_brain
_spec.loader.exec_module(_root_brain)
import ears

KOKORO_URL = "http://127.0.0.1:8880/v1/audio/speech"
DEFAULT_VOICE = "bm_lewis"
SAMPLE_RATE = 24000
CERT_FILE = r"C:\Users\Public\voice-line-cert.crt"
KEY_FILE = r"C:\Users\Public\voice-line-cert.key"
HOST_PORT = 443

# This machine (the spare PC) runs as the jarvis-remote account, but the
# real vault lives under Brian's own OneDrive-synced profile on the SAME
# machine - jarvis-remote already has read/write access to it directly, so
# there's no separate synced copy to keep in sync, just one real vault.
IDENTITY_CWD = r"C:\Users\BrianClark\OneDrive\Desktop\My Jarvis"

_END_TURN = object()


def _pcm_to_wav_bytes(pcm_int16: bytes, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_int16)
    return buf.getvalue()


async def _webm_to_pcm16(webm_bytes: bytes) -> bytes:
    """Browsers record webm/opus, not raw PCM - ffmpeg (already installed
    as a Kokoro dependency) converts it to the raw 16kHz mono PCM16 that
    ears.transcribe_pcm() expects, matching what the local app's mic
    capture produces directly."""
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-i", "pipe:0", "-f", "s16le", "-ar", "16000", "-ac", "1", "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    pcm, _ = await proc.communicate(webm_bytes)
    return pcm


class RemoteMouth:
    """Same public interface as mouth.Mouth (speak/end_turn/is_speaking/
    interrupt/start_thinking_sound/stop_thinking_sound), but instead of
    playing audio on local hardware, synthesizes each sentence and ships it
    to the connected browser over the WebSocket as a WAV blob, plus JSON
    state messages so the client UI can show idle/thinking/speaking."""

    def __init__(self, ws: WebSocket):
        self.ws = ws
        self.sentence_q: asyncio.Queue = asyncio.Queue()
        self._synth_task: asyncio.Task | None = None
        self._speaking_started = False
        self._interrupt_flag = asyncio.Event()
        self._http = httpx.AsyncClient(timeout=30.0)
        self._send_lock = asyncio.Lock()

    async def start(self) -> None:
        self._synth_task = asyncio.create_task(self._synth_worker())

    async def shutdown(self) -> None:
        if self._synth_task is not None:
            self._synth_task.cancel()
        await self._http.aclose()

    async def speak(self, sentence: str) -> None:
        sentence = sentence.strip()
        if not sentence:
            return
        await self.sentence_q.put(sentence)

    async def end_turn(self) -> None:
        await self.sentence_q.put(_END_TURN)

    def is_speaking(self) -> bool:
        return self._speaking_started

    async def interrupt(self) -> None:
        self._interrupt_flag.set()
        while not self.sentence_q.empty():
            try:
                self.sentence_q.get_nowait()
            except asyncio.QueueEmpty:
                break
        await self._send_json({"type": "interrupt"})
        self._speaking_started = False
        await asyncio.sleep(0)
        self._interrupt_flag.clear()

    def start_thinking_sound(self) -> None:
        asyncio.ensure_future(self._send_json({"type": "state", "state": "thinking"}))

    def stop_thinking_sound(self) -> None:
        pass  # the "speaking" state message (sent once real audio is ready) covers this

    async def _synth_worker(self) -> None:
        while True:
            item = await self.sentence_q.get()
            if item is _END_TURN:
                await self._send_json({"type": "turn_end"})
                self._speaking_started = False
                continue
            if self._interrupt_flag.is_set():
                continue
            pcm = await self._synthesize(item)
            if pcm and not self._interrupt_flag.is_set():
                if not self._speaking_started:
                    self._speaking_started = True
                    await self._send_json({"type": "state", "state": "speaking"})
                wav_bytes = _pcm_to_wav_bytes(pcm, SAMPLE_RATE)
                await self._send_bytes(wav_bytes)

    async def _synthesize(self, sentence: str) -> bytes | None:
        try:
            resp = await self._http.post(
                KOKORO_URL,
                json={
                    "model": "kokoro",
                    "input": sentence,
                    "voice": DEFAULT_VOICE,
                    "response_format": "pcm",
                },
            )
            resp.raise_for_status()
            return resp.content
        except Exception:
            return None

    async def _send_json(self, obj: dict) -> None:
        try:
            async with self._send_lock:
                await self.ws.send_json(obj)
        except Exception:
            pass

    async def _send_bytes(self, data: bytes) -> None:
        try:
            async with self._send_lock:
                await self.ws.send_bytes(data)
        except Exception:
            pass


app = FastAPI()


@app.get("/")
async def index() -> FileResponse:
    return FileResponse("static/index.html")


app.mount("/static", StaticFiles(directory="static"), name="static")


@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket) -> None:
    # No single-session lock: each connection gets its own independent
    # Brain, so one device's connection dying messily can never leave a
    # stuck flag that locks out every other device (this bit us for real -
    # a PC tab closing mid-turn once left every later connection, including
    # a phone on a totally different network path, rejected for good).
    await websocket.accept()

    b = brain.Brain(cwd=IDENTITY_CWD, mouth=None)  # mouth set per-connection below
    mouth = RemoteMouth(websocket)
    b.mouth = mouth
    await mouth.start()
    await b.start()

    current_turn_task: asyncio.Task | None = None

    async def interrupt_current() -> None:
        nonlocal current_turn_task
        await mouth.interrupt()
        await b.interrupt()
        if current_turn_task is not None and not current_turn_task.done():
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

    async def handle_turn(text: str) -> None:
        await mouth._send_json({"type": "state", "state": "thinking"})
        try:
            await b.handle_turn(text)
        finally:
            pass

    try:
        await mouth._send_json({"type": "state", "state": "idle"})
        await b.warmup()

        while True:
            message = await websocket.receive()
            if message.get("type") == "websocket.disconnect":
                break

            if "bytes" in message and message["bytes"] is not None:
                # A finished recording came in - if Jarvis is mid-turn or
                # mid-speech, this doubles as a barge-in interrupt, same as
                # pressing PTT again mid-reply does in the local app.
                if current_turn_task is not None and not current_turn_task.done():
                    await interrupt_current()
                elif mouth.is_speaking():
                    await interrupt_current()

                pcm16 = await _webm_to_pcm16(message["bytes"])
                if not pcm16:
                    await mouth._send_json({"type": "state", "state": "idle"})
                    continue

                text = await ears.transcribe_pcm(pcm16)
                text = ears.strip_non_speech_markers(text)
                if not text:
                    await mouth._send_json({"type": "state", "state": "idle"})
                    continue

                await mouth._send_json({"type": "transcript", "text": text})

                if brain.is_quit_phrase(text):
                    await mouth._send_json({"type": "state", "state": "thinking"})
                    continue

                current_turn_task = asyncio.ensure_future(handle_turn(text))

            elif "text" in message and message["text"] is not None:
                import json
                try:
                    control = json.loads(message["text"])
                except Exception:
                    continue
                if control.get("type") == "interrupt":
                    await interrupt_current()

    except (WebSocketDisconnect, ConnectionResetError, Exception):
        pass
    finally:
        if current_turn_task is not None and not current_turn_task.done():
            current_turn_task.cancel()
        await mouth.shutdown()
        await b.shutdown()


if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=HOST_PORT,
        ssl_certfile=CERT_FILE,
        ssl_keyfile=KEY_FILE,
    )
