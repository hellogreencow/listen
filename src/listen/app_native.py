"""Listen — Fast voice-to-text for macOS.

Menubar-only via rumps. Zero pill. Zero emoji. Plain text only.
All UI updates dispatched to main thread via callAfter.
NO custom NSWindow/NSAlert/NSView — those crash inside py2app.
"""

import json
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

import rumps
from Foundation import NSWorkspace
from PyObjCTools.AppHelper import callAfter

ACCESSIBILITY_PANE = (
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
)

from . import sounds
from .hotkey import HotkeyListener
from .providers import registry
from .recorder import AudioRecorder
from .settings import load, save
from .typer import paste_text, type_text

_DEBUG = os.environ.get("LISTEN_DEBUG", "0") == "1"
LOG_PATH = Path.home() / ".listen" / "debug.log"

HOTKEY_PRESETS = [
    ("Right Control", "ctrl_r"),
    ("Right Option", "alt_r"),
    ("F13", "f13"),
    ("F14", "f14"),
    ("F15", "f15"),
    ("Left Control", "ctrl"),
    ("Left Option", "alt"),
    ("Left Command", "cmd"),
    ("Right Command", "cmd_r"),
]


def log(msg: str) -> None:
    if _DEBUG:
        ts = time.strftime("%H:%M:%S")
        line = f"[{ts}] {msg}\n"
        try:
            with open(LOG_PATH, "a") as f:
                f.write(line)
        except Exception:
            pass


def notify(title: str, subtitle: str) -> None:
    try:
        rumps.notification(title, "", subtitle)
    except Exception:
        pass


def _set_title(app, text: str) -> None:
    """Always run on main thread."""
    app.title = text


def _sync_menu_items(app) -> None:
    """Always run on main thread."""
    s = app.settings
    app._mi_stt.title = f"STT: {s.get('stt_provider', 'elevenlabs')}"
    app._mi_interp.title = f"Interpreter: {s.get('interpreter_provider', 'openrouter')}"
    app._mi_cleanup.title = f"Cleanup: {'on' if s.get('cleanup_enabled', True) else 'off'}"
    app._mi_paste.title = f"Paste mode: {'paste' if s.get('use_paste', True) else 'type'}"
    hk = s.get("hotkey", "ctrl_r")
    app._mi_hk.title = f"Hotkey: {hk}"


APP_MODES = {
    "default": "Clean up the following voice transcription. Fix grammar and punctuation. Preserve the original meaning. Only return the cleaned text, no intro:\n\n{text}",
    "email": "Rewrite the following as a professional email. Add proper greeting and sign-off if missing. Only return the email text:\n\n{text}",
    "slack": "Rewrite the following as a casual Slack message. Keep it short and friendly. Only return the message:\n\n{text}",
    "code": "Convert the following speech into a code comment or docstring. Use proper formatting. Only return the comment:\n\n{text}",
    "notes": "Format the following as clean bullet-point notes. Remove filler words. Only return the notes:\n\n{text}",
    "casual": "Clean up the following casual speech. Remove ums and ahs. Keep the casual tone. Only return the text:\n\n{text}",
}

APP_DETECTION = {
    "Mail": "email", "Gmail": "email", "Outlook": "email",
    "Slack": "slack", "Discord": "slack", "Telegram": "slack",
    "Messages": "slack", "WhatsApp": "slack",
    "Cursor": "code", "Code": "code", "Xcode": "code",
    "PyCharm": "code", "Terminal": "code", "iTerm": "code",
    "Notes": "notes", "Notion": "notes", "Obsidian": "notes",
}


def detect_mode() -> str:
    try:
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        name = app.localizedName() if app else ""
    except Exception:
        return "default"
    for key, mode in APP_DETECTION.items():
        if key in name:
            return mode
    return "default"


class ListenApp(rumps.App):

    def __init__(self):
        super().__init__("Listen", quit_button=None)

        self.recorder = AudioRecorder()
        self.hotkey: Optional[HotkeyListener] = None
        self.recording = False
        self.record_start_time: float = 0.0
        self.settings = load()
        self.stt = None
        self.interpreter = None
        self.current_mode = "default"

        self.init_providers()
        sounds.set_enabled(self.settings.get("sound_enabled", False))
        self.start_hotkey()
        self.build_menu()

        hk = self.settings.get("hotkey", "ctrl_r").replace("_", " ").title()
        notify("Listen", f"Hold {hk} to record")

    # ── Menu construction ──────────────────────────────────

    def build_menu(self):
        # STT submenu
        stt_items = []
        for name, key in [("ElevenLabs", "elevenlabs"), ("OpenAI", "openai"),
                          ("Groq", "groq"), ("Local Whisper", "local")]:
            mi = rumps.MenuItem(name, callback=self.set_stt)
            mi._provider = key
            stt_items.append(mi)
        self._mi_stt_parent = rumps.MenuItem("STT: ...")
        self._mi_stt_parent.menu = stt_items

        # Interpreter submenu
        interp_items = []
        for name, key in [("OpenRouter", "openrouter"), ("OpenAI", "openai"),
                          ("Groq", "groq")]:
            mi = rumps.MenuItem(name, callback=self.set_interp)
            mi._provider = key
            interp_items.append(mi)
        self._mi_interp_parent = rumps.MenuItem("Interpreter: ...")
        self._mi_interp_parent.menu = interp_items

        # Hotkey submenu
        hk_items = []
        for label, key in HOTKEY_PRESETS:
            mi = rumps.MenuItem(label, callback=self.set_hotkey)
            mi._hotkey = key
            hk_items.append(mi)
        self._mi_hk_parent = rumps.MenuItem("Hotkey: ...")
        self._mi_hk_parent.menu = hk_items

        # Mode submenu
        mode_items = []
        for label, key in [("Auto", "auto"), ("Default", "default"), ("Email", "email"),
                           ("Slack", "slack"), ("Code", "code"), ("Notes", "notes"),
                           ("Casual", "casual")]:
            mi = rumps.MenuItem(label, callback=self.set_mode)
            mi._mode = key
            mode_items.append(mi)
        self._mi_mode_parent = rumps.MenuItem("Mode: auto")
        self._mi_mode_parent.menu = mode_items

        self._mi_record = rumps.MenuItem("Record", callback=self.do_record)
        self._mi_test = rumps.MenuItem("Test Recording", callback=self.test_record)
        self._mi_cleanup = rumps.MenuItem("Toggle Cleanup", callback=self.toggle_cleanup)
        self._mi_paste = rumps.MenuItem("Toggle Paste Mode", callback=self.toggle_paste)
        self._mi_prefs = rumps.MenuItem("Preferences…", callback=self.show_prefs)
        self._mi_open_config = rumps.MenuItem("Open Config Folder", callback=self.open_config)
        self._mi_reload = rumps.MenuItem("Reload Config", callback=self.reload_config)
        self._mi_grant = rumps.MenuItem("Re-prompt Accessibility", callback=self.prompt_accessibility)
        self._mi_quit = rumps.MenuItem("Quit", callback=self.quit_app)

        self.menu = [
            self._mi_record,
            self._mi_test,
            None,
            self._mi_mode_parent,
            self._mi_stt_parent,
            self._mi_interp_parent,
            self._mi_hk_parent,
            None,
            self._mi_cleanup,
            self._mi_paste,
            None,
            self._mi_prefs,
            self._mi_open_config,
            self._mi_reload,
            self._mi_grant,
            self._mi_quit,
        ]
        callAfter(_sync_menu_items, self)

    # ── Providers ──────────────────────────────────────────

    def init_providers(self):
        s = self.settings
        try:
            self.stt = registry.get_stt(s["stt_provider"], s)
        except Exception as e:
            self.stt = None
            log(f"stt init failed: {e}")
        try:
            if s.get("cleanup_enabled", True):
                self.interpreter = registry.get_interpreter(s["interpreter_provider"], s)
            else:
                self.interpreter = None
        except Exception as e:
            self.interpreter = None
            log(f"interpreter init failed: {e}")
        if self.stt and hasattr(self.stt, "session"):
            threading.Thread(target=self._warm_stt, daemon=True).start()

    def _warm_stt(self):
        try:
            if hasattr(self.stt, "session"):
                self.stt.session.head("https://api.elevenlabs.io/v1", timeout=5)
        except Exception:
            pass

    # ── Hotkey ─────────────────────────────────────────────

    def start_hotkey(self):
        if self.hotkey:
            self.hotkey.stop()
        key = self.settings.get("hotkey", "ctrl_r")
        self.hotkey = HotkeyListener(
            key_name=key,
            on_press=self.on_press,
            on_release=self.on_release,
        )
        self.hotkey.start()

    def on_press(self):
        if self.recording:
            return
        if not self.stt:
            return
        self.recording = True
        self.record_start_time = time.time()
        self.current_mode = detect_mode()
        callAfter(_set_title, self, "listening...")
        try:
            self.recorder.start()
        except Exception as e:
            log(f"recorder.start() failed: {e}")
            self.recording = False
            callAfter(_set_title, self, "Listen")
            notify("Listen", f"Recording failed: {e}")

    def on_release(self):
        if not self.recording:
            return
        self.recording = False
        threading.Thread(target=self._process_thread, daemon=True).start()

    def _process_thread(self):
        try:
            self._do_process()
        except Exception as e:
            log(f"process error: {e}")
            callAfter(_set_title, self, "Listen")

    def _do_process(self):
        t0 = time.perf_counter()

        try:
            path = self.recorder.stop()
        except Exception as e:
            log(f"recorder.stop() failed: {e}")
            callAfter(_set_title, self, "Listen")
            return

        sounds.stop()
        callAfter(_set_title, self, "thinking...")

        self.current_mode = detect_mode()

        t1 = time.perf_counter()
        try:
            text = self.stt.transcribe(path)
            t2 = time.perf_counter()
            log(f"transcribed in {(t2-t1)*1000:.0f}ms: {text[:60]}...")
        except Exception as e:
            log(f"transcription failed: {e}")
            callAfter(_set_title, self, "Listen")
            return

        if self.interpreter and text:
            t3 = time.perf_counter()
            try:
                mode_prompt = APP_MODES.get(self.current_mode, APP_MODES["default"])
                text = self.interpreter.interpret(text, instruction=mode_prompt)
                t4 = time.perf_counter()
                log(f"interpreted in {(t4-t3)*1000:.0f}ms: {text[:60]}...")
            except Exception as e:
                log(f"interpretation failed: {e}")

        try:
            path.unlink()
        except Exception:
            pass

        t5 = time.perf_counter()
        try:
            if self.settings.get("use_paste", True):
                paste_text(text)
            else:
                type_text(text)
            t6 = time.perf_counter()
            log(f"paste OK in {(t6-t5)*1000:.0f}ms")
        except Exception as e:
            log(f"paste failed: {e}")
            try:
                subprocess.run(f"echo '{text}' | pbcopy", shell=True, check=True)
                notify("Listen", "Copied to clipboard")
            except Exception:
                pass

        total = (time.perf_counter() - t0) * 1000
        callAfter(_set_title, self, "Listen")
        log(f"done — total after release: {total:.0f}ms")

    # ── Menu actions ───────────────────────────────────────

    def do_record(self, sender):
        if not self.stt:
            notify("Listen", "No STT configured")
            return
        self.on_press()
        time.sleep(3)
        self.on_release()

    def test_record(self, sender):
        if not self.stt:
            notify("Listen", "No STT configured")
            return
        threading.Thread(target=self._test_thread, daemon=True).start()

    def _test_thread(self):
        try:
            self.on_press()
            time.sleep(3)
            self.on_release()
            time.sleep(8)
            notify("Listen", "Test complete — check output")
        except Exception as e:
            notify("Listen", f"Test failed: {e}")

    def set_mode(self, sender):
        mode = getattr(sender, "_mode", "default")
        self.current_mode = mode
        callAfter(_sync_menu_items, self)
        notify("Listen", f"Mode: {mode}")

    def set_stt(self, sender):
        provider = getattr(sender, "_provider", "elevenlabs")
        self.settings["stt_provider"] = provider
        save(self.settings)
        self.init_providers()
        callAfter(_sync_menu_items, self)
        notify("Listen", f"STT: {provider}")

    def set_interp(self, sender):
        provider = getattr(sender, "_provider", "openrouter")
        self.settings["interpreter_provider"] = provider
        save(self.settings)
        self.init_providers()
        callAfter(_sync_menu_items, self)
        notify("Listen", f"Interpreter: {provider}")

    def set_hotkey(self, sender):
        key = getattr(sender, "_hotkey", "ctrl_r")
        self.settings["hotkey"] = key
        save(self.settings)
        self.start_hotkey()
        callAfter(_sync_menu_items, self)
        notify("Listen", f"Hotkey: {key}")

    def toggle_cleanup(self, sender):
        self.settings["cleanup_enabled"] = not self.settings.get("cleanup_enabled", True)
        save(self.settings)
        self.init_providers()
        callAfter(_sync_menu_items, self)
        notify("Listen", f"Cleanup {'on' if self.settings['cleanup_enabled'] else 'off'}")

    def toggle_paste(self, sender):
        self.settings["use_paste"] = not self.settings.get("use_paste", True)
        save(self.settings)
        callAfter(_sync_menu_items, self)
        notify("Listen", f"Paste mode: {'paste' if self.settings['use_paste'] else 'type'}")

    def open_config(self, sender):
        config_dir = Path.home() / ".listen"
        config_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(["open", str(config_dir)])

    def show_prefs(self, sender):
        """Native rumps.Window — safe inside py2app, no custom NSWindow."""
        body = json.dumps(self.settings, indent=2)
        win = rumps.Window(
            title="Listen — Preferences",
            message=(
                "Edit and click OK to save. Changes apply immediately.\n"
                "Keys: stt_provider, interpreter_provider, hotkey, "
                "cleanup_enabled, use_paste, sound_enabled, and API keys."
            ),
            default_text=body,
            ok="Save",
            cancel="Cancel",
            dimensions=(560, 360),
        )
        resp = win.run()
        if not resp.clicked:
            return
        try:
            new_cfg = json.loads(resp.text)
            if not isinstance(new_cfg, dict):
                raise ValueError("config must be a JSON object")
        except Exception as e:
            rumps.alert("Listen — Invalid config", f"{e}\n\nSettings NOT saved.")
            return
        self.settings = {**self.settings, **new_cfg}
        save(self.settings)
        self.init_providers()
        self.start_hotkey()
        sounds.set_enabled(self.settings.get("sound_enabled", False))
        callAfter(_sync_menu_items, self)
        notify("Listen", "Settings saved")

    def prompt_accessibility(self, sender):
        try:
            from ApplicationServices import (
                AXIsProcessTrustedWithOptions,
                kAXTrustedCheckOptionPrompt,
            )
            AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
        except Exception as e:
            log(f"accessibility prompt failed: {e}")
        subprocess.run(["open", ACCESSIBILITY_PANE])

    def reload_config(self, sender):
        self.settings = load()
        self.init_providers()
        self.start_hotkey()
        callAfter(_sync_menu_items, self)
        notify("Listen", "Config reloaded")

    def quit_app(self, sender):
        if self.hotkey:
            self.hotkey.stop()
        rumps.quit_application()


def main():
    try:
        from ApplicationServices import (
            AXIsProcessTrusted,
            AXIsProcessTrustedWithOptions,
            kAXTrustedCheckOptionPrompt,
        )
        if not AXIsProcessTrusted():
            # Show the system prompt (non-blocking) and open the pane directly
            AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
            subprocess.run(["open", ACCESSIBILITY_PANE])
            notify("Listen", "Grant Accessibility, then quit & relaunch")
    except Exception:
        pass
    ListenApp().run()


if __name__ == "__main__":
    main()
