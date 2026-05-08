"""Type text into the currently focused macOS text field.

Fast path uses NSPasteboard + Quartz CGEvent (no subprocess, no temp files).
"""

from AppKit import NSPasteboard, NSPasteboardTypeString
from Quartz import (
    CGEventCreateKeyboardEvent,
    CGEventPost,
    CGEventSetFlags,
    CGEventSourceCreate,
    kCGEventFlagMaskCommand,
    kCGEventSourceStateHIDSystemState,
    kCGHIDEventTap,
)


def _post_key(keycode: int, flags: int = 0) -> None:
    """Post a key down/up event via Quartz."""
    src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
    down = CGEventCreateKeyboardEvent(src, keycode, True)
    up = CGEventCreateKeyboardEvent(src, keycode, False)
    if flags:
        CGEventSetFlags(down, flags)
        CGEventSetFlags(up, flags)
    CGEventPost(kCGHIDEventTap, down)
    CGEventPost(kCGHIDEventTap, up)


def type_text(text: str) -> None:
    """Type text via AppleScript keystroke. Best for short ASCII text."""
    import subprocess

    safe = text.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(
        ["osascript", "-e", f'tell application "System Events" to keystroke "{safe}"'],
        check=True,
        capture_output=True,
    )


def paste_text(text: str, restore_clipboard: bool = True) -> None:
    """Copy text to clipboard via NSPasteboard, paste with Cmd+V, optionally restore previous clipboard."""
    saved = None
    if restore_clipboard:
        pb = NSPasteboard.generalPasteboard()
        saved = pb.stringForType_(NSPasteboardTypeString)

    # Write directly to pasteboard (no temp file, no subprocess)
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)

    # Paste via Quartz CGEvent — 'v' keycode is 9, Cmd is kCGEventFlagMaskCommand
    _post_key(9, kCGEventFlagMaskCommand)

    # Restore clipboard in background (non-blocking)
    if restore_clipboard and saved is not None:
        import threading

        def _restore():
            pb2 = NSPasteboard.generalPasteboard()
            pb2.clearContents()
            pb2.setString_forType_(saved, NSPasteboardTypeString)

        threading.Thread(target=_restore, daemon=True).start()
