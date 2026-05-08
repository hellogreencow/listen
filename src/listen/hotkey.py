"""Global hotkey listener using pynput."""

import threading
from typing import Callable, Optional, Union

from pynput import keyboard

class HotkeyListener:
    """Listens for a global hotkey and calls callbacks on press/release."""

    def __init__(
        self,
        key_name: str = "alt_r",
        on_press: Optional[Callable[[], None]] = None,
        on_release: Optional[Callable[[], None]] = None,
    ):
        self.key_name = key_name
        self.on_press = on_press
        self.on_release = on_release
        self._listener: Optional[keyboard.Listener] = None
        self._pressed = False
        self._lock = threading.Lock()

    def _resolve_key(self) -> Union[keyboard.Key, keyboard.KeyCode]:
        """Convert key name to pynput Key object."""
        # Handle special keys
        try:
            return getattr(keyboard.Key, self.key_name)
        except AttributeError:
            pass
        # Handle single characters
        if len(self.key_name) == 1:
            return keyboard.KeyCode.from_char(self.key_name)
        # Try parsing as hex keycode
        try:
            return keyboard.KeyCode(int(self.key_name, 16))
        except ValueError:
            raise ValueError(f"Unknown key: {self.key_name}")

    def _on_press(self, key):
        target = self._resolve_key()
        if key == target:
            with self._lock:
                if not self._pressed:
                    self._pressed = True
                    if self.on_press:
                        try:
                            self.on_press()
                        except Exception as e:
                            print(f"[hotkey] press error: {e}")

    def _on_release(self, key):
        target = self._resolve_key()
        if key == target:
            with self._lock:
                if self._pressed:
                    self._pressed = False
                    if self.on_release:
                        try:
                            self.on_release()
                        except Exception as e:
                            print(f"[hotkey] release error: {e}")

    def start(self) -> None:
        """Start listening in a background thread."""
        self._listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
            suppress=False,
        )
        self._listener.start()
        print(f"[hotkey] listening for '{self.key_name}' (hold to record)")

    def stop(self) -> None:
        """Stop listening."""
        if self._listener:
            self._listener.stop()
            self._listener = None
            print("[hotkey] stopped")
