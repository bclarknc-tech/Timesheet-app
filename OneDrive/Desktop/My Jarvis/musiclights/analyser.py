r"""Music analyser - listens to whatever is coming out of Brian's speakers and
publishes a small signal bus the lighting render loop can read.

!! THIS DOCSTRING CARRIES AN r PREFIX because it contains Windows paths. Without
it, `~\musiclights` is read as the escape sequence \m and Python prints a
SyntaxWarning on every single launch - noise in a log whose whole job is to make
a real failure visible. (Do not spell the prefix out with quote characters in
here either; a literal triple quote inside a docstring ends it.)

DESIGN, and why it mirrors the voice line:
  This is a PUBLISHER ONLY. It never talks to any lighting hardware. The render
  loop reads the bus as a consumer, exactly the way it reads the voice bus. If
  this process dies, crashes or is never started, the voice lighting carries on
  without noticing - the failure-isolation rule this whole project runs on.

  It also runs in its OWN venv (~\musiclights\.venv) so nothing here can disturb
  the voice line's Python environment.

!! IT WILL ALSO HEAR JARVIS TALKING. TTS plays through the same speakers, so
this bus goes hot whenever Jarvis speaks. That is NOT filtered here on purpose -
the analyser reports what it hears and stays dumb. The render loop already knows
when TTS is live (its own bus says so) and decides who wins. Trying to subtract
the voice here would mean two processes guessing about each other.

!! AUTO-GAIN IS NOT OPTIONAL. Brian said "whatever music I play" - quiet tracks,
loud tracks, different apps at different volumes. A fixed threshold works for
exactly one of those. Bands are normalised against a slowly-decaying running
maximum so anything reads.
"""
import json
import os
import sys
import time
import traceback
from collections import deque

import numpy as np
import soundcard as sc

SR         = 48000
BLOCK      = 1024                 # ~21 ms -> ~47 updates/sec
BUS_PATH   = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".music_bus")
LOG_PATH   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "analyser.log")
WRITE_HZ   = 30.0                 # bus writes/sec; the loop reads far slower than this
SILENCE    = 0.0015               # rms below this = nothing is playing

BANDS = (("bass", 20, 250), ("mid", 250, 2000), ("treble", 2000, 9000))

REPLACE_RETRIES = 8               # see atomic_write(); 8x2 ms measured at 0.0% loss
REPLACE_BACKOFF = 0.002


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)


def atomic_write(path, text):
    """Temp + rename, so a reader never sees a half-written bus file.
    Same rule signals.py uses on the voice bus.

    !! THE TEMP NAME IS PER-PROCESS. A shared '.tmp' looked fine until two
    copies ran at once, and then os.replace failed with WinError 5 (access
    denied) because each process had the other's temp file open. The bus simply
    stopped updating while the analyser looked perfectly healthy - it was still
    capturing, still logging 'alive'. Unique names make the race impossible
    rather than unlikely.

    !! THE REPLACE IS RETRIED, AND THAT IS THE WHOLE FIX FOR WinError 5 (2026-08-02).
    Windows will not let os.replace() replace a file that ANY handle is open on -
    share-delete or not. voice-lights.ps1 reads this bus ~44x/sec, so a plain
    replace loses the race about one time in five, and this log had ~23,000 of
    them. MEASURED on a scratch file with that exact reader:

        no reader at all ....... 0 of 583 failed  (rules out Defender/filesystem)
        with reader, no retry .. 110 of 583 (18.9%)
        retry x3 ...............   2 of 579  (0.3%)
        retry x8 ...............   0 of 583  (0.0%)

    A collision clears as soon as the reader closes its handle, which is why a
    couple of milliseconds is enough. Worst case here is 16 ms and only on a
    collision; this runs on the capture loop, which has no callback deadline.
    signals.py uses a SMALLER budget on purpose - see the note there."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    for attempt in range(REPLACE_RETRIES + 1):
        try:
            os.replace(tmp, path)
            return
        except OSError:
            if attempt == REPLACE_RETRIES:
                # Drop the temp rather than leave it to accumulate, then let the
                # caller log it. A missed frame costs nothing here.
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
            time.sleep(REPLACE_BACKOFF)


class Envelope:
    """Fast attack, slow release - the shape that makes lights track syllables
    and beats instead of smearing. Same idea as the render loop's own envelopes."""
    def __init__(self, attack=0.55, release=0.12):
        self.v = 0.0
        self.a = attack
        self.r = release

    def push(self, x):
        k = self.a if x > self.v else self.r
        self.v += (x - self.v) * k
        return self.v


class AutoGain:
    """Normalise against a decaying running maximum so quiet and loud material
    both fill the range. Floor prevents silence from being amplified into noise."""
    def __init__(self, decay=0.9995, floor=1e-4):
        self.peak = floor
        self.decay = decay
        self.floor = floor

    def push(self, x):
        self.peak = max(x, self.peak * self.decay, self.floor)
        return min(1.0, x / self.peak)


MUTEX_NAME = "JarvisMusicAnalyserSingleton"

# Held for the life of the process. Windows drops a mutex automatically when the
# owning process ends, however it ends, which is the whole point of using one.
_mutex_handle = None


def take_lock():
    """Single instance, via a Windows NAMED MUTEX. Returns False if one is live.

    !! THIS REPLACED A PID-FILE LOCK ON 2026-08-02, AND THE OLD ONE HAD NEVER
    WORKED ONCE. The autostart launched a second analyser alongside a healthy one
    and it took the lock away from it rather than exiting; both then fought over
    the bus. Three separate faults, all now gone because the mechanism is gone:

      1. The real check called psutil.Process(pid).create_time(), but psutil is
         NOT installed in ~\\musiclights\\.venv - so that branch never ran at all
         and it silently fell through to a weak fallback every single time.
      2. The stored stamp was time.time() taken AT LOCK TIME, compared against
         the process CREATION time. soundcard and numpy take well over the 1.0 s
         tolerance to import, so a live process read as stale even with psutil.
      3. The fallback was os.kill(pid, 0), which on Windows is not a probe -
         CPython maps any signal but CTRL_C_EVENT/CTRL_BREAK_EVENT to
         TerminateProcess, so the "is it alive?" test can KILL the other copy.

    A named mutex has none of those moving parts: no pid to go stale, no clock
    arithmetic, no dependency, and nothing that can touch another process. The
    kernel owns the lifetime.

    !! DO NOT go back to a pid file "so it's greppable." The log line below is
    the greppable part, and it costs nothing.
    """
    global _mutex_handle
    if os.name != "nt":
        return True  # not Windows; this project only ever runs here

    import ctypes

    ERROR_ALREADY_EXISTS = 183
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p)
        kernel32.CreateMutexW.restype = ctypes.c_void_p
        handle = kernel32.CreateMutexW(None, False, MUTEX_NAME)
        err = ctypes.get_last_error()
    except Exception as e:
        # Fail OPEN, exactly as the old code did: a broken guard must never be
        # the reason Brian has no music lighting. A duplicate is the lesser bug.
        log("could not create mutex (%s) - continuing anyway" % e)
        return True

    if not handle:
        log("could not create mutex (err %d) - continuing anyway" % err)
        return True
    if err == ERROR_ALREADY_EXISTS:
        log("another analyser is already running - exiting")
        return False

    _mutex_handle = handle
    return True


def main():
    log("=== analyser starting (pid %d) ===" % os.getpid())
    if not take_lock():
        return 0

    freqs = np.fft.rfftfreq(BLOCK, 1.0 / SR)
    band_idx = {n: (freqs >= lo) & (freqs < hi) for n, lo, hi in BANDS}
    window = np.hanning(BLOCK)

    gains = {n: AutoGain() for n, _, _ in BANDS}
    envs = {n: Envelope() for n, _, _ in BANDS}
    lvl_gain, lvl_env = AutoGain(), Envelope(attack=0.5, release=0.08)

    # Beat detection: compare this block's bass energy to the recent average.
    # ~1 s of history at this block rate.
    hist = deque(maxlen=45)
    last_beat = 0.0
    beat_count = 0

    # Random color cycling for beat pulse mode
    import random
    next_color_time = time.time()
    current_hue = random.randint(0, 360)

    last_write = 0.0
    last_device_check = 0.0
    frames_seen = 0
    started = time.time()
    current_speaker = None
    rec = None

    def reconnect_to_device():
        nonlocal rec, current_speaker
        try:
            speaker = sc.default_speaker()
            log("default speaker: %s" % speaker.name)
            mic = sc.get_microphone(speaker.name, include_loopback=True)
            log("loopback: %s" % mic.name)
            if current_speaker != speaker.name:
                if rec is not None:
                    try:
                        rec.__exit__(None, None, None)
                    except Exception as e:
                        log("error closing recorder: %s" % e)
                current_speaker = speaker.name
                log("switched to: %s" % mic.name)
                rec = mic.recorder(samplerate=SR, channels=2, blocksize=BLOCK)
                rec.__enter__()
            return True
        except Exception as e:
            log("reconnect failed: %s" % e)
            return False

    try:
        if not reconnect_to_device():
            log("FATAL: could not open initial loopback")
            return 1

        log("capturing")
        check_count = 0
        while True:
            # Check for device switch every ~2 seconds
            now = time.time()
            if (now - last_device_check) > 2.0:
                last_device_check = now
                check_count += 1
                try:
                    speaker = sc.default_speaker()
                    log("check %d: default=%s current=%s" % (check_count, speaker.name, current_speaker))
                    if speaker.name != current_speaker:
                        log("DEVICE CHANGED: %s -> %s" % (current_speaker, speaker.name))
                        reconnect_to_device()
                except Exception as e:
                    log("device check error: %s" % e)

            data = rec.record(numframes=BLOCK)
            frames_seen += 1
            mono = data.mean(axis=1)

            rms = float(np.sqrt(np.mean(mono ** 2)))
            playing = rms > SILENCE

            spec = np.abs(np.fft.rfft(mono * window))
            raw = {}
            for n, _, _ in BANDS:
                b = spec[band_idx[n]]
                raw[n] = float(b.mean()) if b.size else 0.0

            if playing:
                vals = {n: envs[n].push(gains[n].push(raw[n])) for n, _, _ in BANDS}
                level = lvl_env.push(lvl_gain.push(rms))
            else:
                vals = {n: envs[n].push(0.0) for n, _, _ in BANDS}
                level = lvl_env.push(0.0)

            beat = False
            now = time.time()
            if playing:
                hist.append(raw["bass"])
                if len(hist) >= 12:
                    avg = float(np.mean(hist))
                    if raw["bass"] > avg * 1.45 and (now - last_beat) > 0.18:
                        beat = True
                        last_beat = now
                        beat_count += 1

            # Change color randomly or on beat
            if now >= next_color_time or beat:
                current_hue = random.randint(0, 360)
                next_color_time = now + random.uniform(2.0, 6.0)

            if (now - last_write) >= (1.0 / WRITE_HZ):
                last_write = now
                payload = {
                    "ts": now,
                    "playing": bool(playing),
                    "level": round(level, 4),
                    "bass": round(vals["bass"], 4),
                    "mid": round(vals["mid"], 4),
                    "treble": round(vals["treble"], 4),
                    "beat": bool(beat),
                    "beats": beat_count,
                    "rms": round(rms, 5),
                    "hue": current_hue,
                }
                try:
                    atomic_write(BUS_PATH, json.dumps(payload))
                except Exception as e:
                    log("bus write failed: %s" % e)

            if frames_seen % 2000 == 0:
                log("alive: %.0fs  blocks=%d  rms=%.4f playing=%s beats=%d"
                    % (time.time() - started, frames_seen, rms, playing, beat_count))
    except KeyboardInterrupt:
        log("stopped by keyboard")
    except Exception:
        log("FATAL:\n" + traceback.format_exc())
        return 1
    finally:
        if rec is not None:
            try:
                rec.__exit__(None, None, None)
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
