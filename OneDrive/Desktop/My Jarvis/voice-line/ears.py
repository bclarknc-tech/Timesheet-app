"""Mic capture and transcription.

Hold-to-talk (default): the mic is opened fresh on each press and fully
closed after each release, so room audio and music never leak into the
transcriber between holds.

--open-mic (legacy, optional): webrtcvad endpoints an always-open stream.
Know the tradeoff before choosing it - with an always-open mic, audio
playing in the room (a video, music, even another voice assistant) can get
picked up as speech and trigger replies to dialogue never meant for this
assistant. That false-trigger risk is why hold-to-talk is the default.
"""

from __future__ import annotations

import asyncio
import io
import re
import time
import wave

import httpx
import numpy as np
import sounddevice as sd
import webrtcvad

import signals

WHISPER_URL = "http://127.0.0.1:2022/inference"  # the real route - whisper-server.exe
                                                    # only exposes /inference, not the
                                                    # OpenAI-style /v1/audio/transcriptions
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"

RELEASE_TAIL_SECONDS = 0.18
# Allow short hardware button taps (e.g., Stream Deck) to register.
# Lowered from 0.25s to 0.05s to accept quick key-triggered holds.
MIN_HOLD_SECONDS = 0.05

# Open-mic VAD tuning
VAD_FRAME_MS = 30
VAD_FRAME_SAMPLES = int(SAMPLE_RATE * VAD_FRAME_MS / 1000)
VAD_AGGRESSIVENESS = 2
MIN_SPEECH_MS = 240
SILENCE_HANGOVER_FRAMES = 12  # ~360ms of trailing silence ends an utterance
SPEECH_START_FRAMES = 3  # ~90ms of speech to confirm an utterance started

_BRACKET_MARKER_RE = re.compile(r"\[[^\]]*\]")


def _pcm_to_wav_bytes(pcm_int16: np.ndarray, sample_rate: int = SAMPLE_RATE) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_int16.tobytes())
    return buf.getvalue()


def strip_non_speech_markers(text: str) -> str:
    """Strip bracketed non-speech markers whisper emits, e.g. [SIGHS], [BLANK_AUDIO]."""
    return _BRACKET_MARKER_RE.sub("", text).strip()


class Ears:
    """Hold-to-talk mic capture. One recording session per hold."""

    def __init__(self, whisper_url: str = WHISPER_URL):
        self.whisper_url = whisper_url
        self._stream: sd.InputStream | None = None
        self._frames: list[np.ndarray] = []
        self._recording = False
        self._start_time = 0.0

    def start_recording(self) -> None:
        if self._recording:
            return
        self._frames = []
        self._recording = True
        self._start_time = time.monotonic()

        def callback(indata, frames, time_info, status):
            if not self._recording:
                return
            self._frames.append(indata.copy())
            # Publish the mic to the visualiser bus so the analyser can draw
            # Brian's voice, not just Jarvis's. signals throttles this to
            # 15/sec internally, so it is a cheap no-op on most callbacks.
            #
            # Wrapped defensively and deliberately: this runs on PortAudio's
            # own callback thread, and an exception escaping here would take
            # the capture stream down with it - losing the transcription,
            # which matters infinitely more than the animation. signals'
            # writers already swallow their own errors; this is the second
            # belt for anything raised before them (e.g. numpy on indata).
            try:
                signals.write_waveform(signals.downsample_to_64(indata), src="mic")
            except Exception:
                pass

        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            callback=callback,
        )
        self._stream.start()

    async def stop_recording(self) -> bytes | None:
        """Stop capture (after a short tail) and return raw int16 PCM bytes.

        Returns None if the hold was too short to be a real press (taps
        under ~250ms are ignored, per spec) or if nothing was captured.
        """
        if not self._recording or self._stream is None:
            return None

        held_seconds = time.monotonic() - self._start_time

        # Keep recording through the release tail so the last word survives.
        await asyncio.sleep(RELEASE_TAIL_SECONDS)

        self._recording = False
        stream = self._stream
        self._stream = None
        stream.stop()
        stream.close()  # mic fully closed between holds

        # Drop the mic trace as soon as the hold ends. Without this the last
        # published frame stays "fresh" for the bus's 2s window, so the
        # analyser would keep showing Brian's waveform for a beat or two into
        # thinking, after he has already stopped talking.
        try:
            signals.clear_waveform()
        except Exception:
            pass

        if held_seconds < MIN_HOLD_SECONDS:
            return None

        if not self._frames:
            return None

        pcm = np.concatenate(self._frames, axis=0).reshape(-1).astype(np.int16)
        self._frames = []
        if pcm.size == 0:
            return None
        return pcm.tobytes()

    async def transcribe(self, pcm_bytes: bytes) -> str:
        pcm = np.frombuffer(pcm_bytes, dtype=np.int16)
        wav_bytes = _pcm_to_wav_bytes(pcm)
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                self.whisper_url,
                files={"file": ("audio.wav", wav_bytes, "audio/wav")},
                data={"response_format": "json"},
            )
            resp.raise_for_status()
            data = resp.json()
        return (data.get("text") or "").strip()


async def transcribe_pcm(pcm_bytes: bytes, whisper_url: str = WHISPER_URL) -> str:
    """Standalone helper (used by open-mic mode too)."""
    ears = Ears(whisper_url)
    return await ears.transcribe(pcm_bytes)


class OpenMicListener:
    """Legacy always-open mic with webrtcvad endpointing.

    Discards any utterance with less than 240ms of actual speech, and
    strips bracketed non-speech markers whisper emits (e.g. [SIGHS],
    [BLANK_AUDIO]) from the final transcript.
    """

    def __init__(self, whisper_url: str = WHISPER_URL):
        self.whisper_url = whisper_url
        self.vad = webrtcvad.Vad(VAD_AGGRESSIVENESS)

    async def listen(self, on_utterance):
        """Run forever, calling on_utterance(text) for each finalized utterance."""
        loop = asyncio.get_running_loop()
        frame_queue: asyncio.Queue[bytes] = asyncio.Queue()

        def callback(indata, frames, time_info, status):
            loop.call_soon_threadsafe(frame_queue.put_nowait, bytes(indata))

        stream = sd.RawInputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=VAD_FRAME_SAMPLES,
            callback=callback,
        )
        stream.start()

        in_speech = False
        speech_frames: list[bytes] = []
        speech_run = 0
        silence_run = 0

        try:
            while True:
                frame = await frame_queue.get()
                if len(frame) != VAD_FRAME_SAMPLES * 2:
                    continue  # partial frame, skip
                is_speech = self.vad.is_speech(frame, SAMPLE_RATE)

                if not in_speech:
                    if is_speech:
                        speech_run += 1
                        speech_frames.append(frame)
                        if speech_run >= SPEECH_START_FRAMES:
                            in_speech = True
                            silence_run = 0
                    else:
                        speech_run = 0
                        speech_frames = []
                else:
                    speech_frames.append(frame)
                    if is_speech:
                        silence_run = 0
                    else:
                        silence_run += 1
                        if silence_run >= SILENCE_HANGOVER_FRAMES:
                            # utterance ended
                            in_speech = False
                            speech_run = 0
                            utterance = b"".join(speech_frames)
                            speech_frames = []
                            speech_ms = (len(utterance) / 2) / SAMPLE_RATE * 1000
                            if speech_ms >= MIN_SPEECH_MS:
                                text = await self.transcribe(utterance)
                                text = strip_non_speech_markers(text)
                                if text:
                                    await on_utterance(text)
        finally:
            stream.stop()
            stream.close()

    async def transcribe(self, pcm_bytes: bytes) -> str:
        pcm = np.frombuffer(pcm_bytes, dtype=np.int16)
        wav_bytes = _pcm_to_wav_bytes(pcm)
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                self.whisper_url,
                files={"file": ("audio.wav", wav_bytes, "audio/wav")},
                data={"response_format": "json"},
            )
            resp.raise_for_status()
            data = resp.json()
        return (data.get("text") or "").strip()
