"""Global hold-to-talk key listener.

pynput's global listener works out of the box on a normal Windows console
process - no special OS permission gate, just make sure microphone access
is allowed for desktop apps under Windows Settings > Privacy & security >
Microphone.

CRITICAL: the OS fires key-repeat on_press events continuously while a key
is held. Without a held-state flag, every repeat looks like a fresh press,
which restarts recording over and over and kills every reply before it
speaks. The held flag below is what makes a single physical hold into
exactly one press event and exactly one release event.

pynput's listener runs on its own thread; events are handed to the asyncio
loop with call_soon_threadsafe (never asyncio.add_reader - see main.py for
why).
"""

from __future__ import annotations

import asyncio

from pynput import keyboard

# Default PTT keys: accept Right Ctrl, Left Ctrl, or Space so hardware
# like Stream Decks can be mapped to any of them without code changes.
PTT_KEY = {keyboard.Key.ctrl_r, keyboard.Key.ctrl_l, keyboard.Key.space}

PRESS = "press"
RELEASE = "release"


class PTTListener:
    def __init__(self, loop: asyncio.AbstractEventLoop, key=PTT_KEY):
        self.loop = loop
        # Accept either a single key or an iterable of keys; normalize to a set
        if isinstance(key, set):
            self.keys = set(key)
        else:
            try:
                # allow tuples/lists
                self.keys = set(key)
            except Exception:
                self.keys = {key}
        self.events: asyncio.Queue[str] = asyncio.Queue()
        self._held = False
        self._listener: keyboard.Listener | None = None

    def start(self) -> None:
        self._listener = keyboard.Listener(
            on_press=self._on_press, on_release=self._on_release
        )
        self._listener.start()

    def stop(self) -> None:
        if self._listener is not None:
            self._listener.stop()
            self._listener = None

    def _on_press(self, key) -> None:
        # Accept any configured PTT key
        if key not in self.keys:
            return
        if self._held:
            return  # key-repeat while held - not a new press
        self._held = True
        self.loop.call_soon_threadsafe(self.events.put_nowait, PRESS)

    def _on_release(self, key) -> None:
        if key not in self.keys:
            return
        self._held = False
        self.loop.call_soon_threadsafe(self.events.put_nowait, RELEASE)

    async def next_event(self) -> str:
        return await self.events.get()
