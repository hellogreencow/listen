"""Optional audio feedback. Disabled by default for low-key operation."""

import subprocess

# Cache the sound setting to avoid reading config from disk on every press/release.
# App layer calls set_enabled() at startup and whenever the setting changes.
_enabled = False


def set_enabled(flag: bool) -> None:
    global _enabled
    _enabled = flag


def _play(name: str) -> None:
    if not _enabled:
        return
    script = f'do shell script "afplay /System/Library/Sounds/{name}.aiff"'
    subprocess.Popen(
        ["osascript", "-e", script],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def start() -> None:
    _play("Tink")


def stop() -> None:
    _play("Glass")


def error() -> None:
    _play("Basso")
