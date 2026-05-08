"""Listen — Fast voice-to-text for macOS.

Menubar-only via rumps. Zero pill. Zero emoji. Plain text only.
"""

import os
import subprocess
import threading
import time
import traceback
from pathlib import Path
from typing import Optional

import objc
import rumps
from AppKit import (
    NSAlert,
    NSAlertFirstButtonReturn,
    NSColor,
    NSFont,
    NSMakeRect,
    NSSecureTextField,
    NSTextField,
    NSView,
    NSWindow,
    NSButton,
    NSSwitchButton,
    NSVisualEffectView,
    NSWorkspace,
)
from Foundation import NSObject

from . import sounds
from .hotkey import HotkeyListener
from .providers import registry
from .recorder import AudioRecorder
from .settings import load, save
from .typer import paste_text, type_text


_DEBUG = os.environ.get("LISTEN_DEBUG", "0") == "1"
LOG_PATH = Path.home() / ".listen" / "debug.log"


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


class _SectionView(NSView):
    """Rounded card for preferences."""

    def initWithFrame_title_(self, frame, title):
        self = objc.super(_SectionView, self).initWithFrame_(frame)
        if self is None:
            return None
        self.setWantsLayer_(True)
        self.layer().setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.12, 1.0).CGColor())
        self.layer().setCornerRadius_(10.0)
        self.layer().setBorderWidth_(0.5)
        self.layer().setBorderColor_(NSColor.colorWithCalibratedWhite_alpha_(0.25, 1.0).CGColor())

        lbl = NSTextField.alloc().initWithFrame_(NSMakeRect(16, frame.size.height - 30, 200, 20))
        lbl.setStringValue_(title)
        lbl.setEditable_(False)
        lbl.setBordered_(False)
        lbl.setBackgroundColor_(NSColor.clearColor())
        lbl.setTextColor_(NSColor.whiteColor())
        lbl.setFont_(NSFont.boldSystemFontOfSize_(11))
        self.addSubview_(lbl)
        return self


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

    def build_menu(self):
        self.menu = [
            rumps.MenuItem("Record", callback=self.do_record),
            None,
            rumps.MenuItem("Mode: auto", callback=self.cycle_mode),
            rumps.MenuItem("STT: elevenlabs", callback=self.choose_stt),
            rumps.MenuItem("Interpreter: openrouter", callback=self.choose_interp),
            None,
            rumps.MenuItem("Toggle Cleanup", callback=self.toggle_cleanup),
            None,
            rumps.MenuItem("Preferences...", callback=self.show_prefs),
            rumps.MenuItem("Quit", callback=self.quit_app),
        ]
        self.sync_titles()

    def sync_titles(self):
        s = self.settings
        for item in self.menu:
            if item is None:
                continue
            if item.title.startswith("STT:"):
                item.title = f"STT: {s.get('stt_provider', 'elevenlabs')}"
            elif item.title.startswith("Interpreter:"):
                item.title = f"Interpreter: {s.get('interpreter_provider', 'openrouter')}"
            elif item.title.startswith("Mode:"):
                item.title = f"Mode: {self.current_mode}"

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
        self.hotkey = HotkeyListener(
            key_name=self.settings.get("hotkey", "alt_r"),
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
        self.title = "listening..."
        try:
            self.recorder.start()
        except Exception as e:
            log(f"recorder.start() failed: {e}")
            self.recording = False
            self.title = "Listen"
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
            self.title = "Listen"

    def _do_process(self):
        t0 = time.perf_counter()

        try:
            path = self.recorder.stop()
        except Exception as e:
            log(f"recorder.stop() failed: {e}")
            self.title = "Listen"
            return

        sounds.stop()
        self.title = "Thinking..."

        self.current_mode = detect_mode()

        t1 = time.perf_counter()
        try:
            text = self.stt.transcribe(path)
            t2 = time.perf_counter()
            log(f"transcribed in {(t2-t1)*1000:.0f}ms: {text[:60]}...")
        except Exception as e:
            log(f"transcription failed: {e}")
            self.title = "Listen"
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
        self.title = "Listen"
        log(f"done — total after release: {total:.0f}ms")

    # ── Menu Actions ───────────────────────────────────────

    def do_record(self, sender):
        if not self.stt:
            notify("Listen", "Set API keys in Preferences")
            return
        self.on_press()
        time.sleep(3)
        self.on_release()

    def cycle_mode(self, sender):
        modes = list(APP_MODES.keys())
        idx = modes.index(self.current_mode) if self.current_mode in modes else 0
        self.current_mode = modes[(idx + 1) % len(modes)]
        self.sync_titles()
        notify("Listen", f"Mode: {self.current_mode}")

    def choose_stt(self, sender):
        choices = ", ".join(registry.list_stt())
        choice = self._ask_text(f"Available: {choices}", "STT Provider", self.settings.get("stt_provider", "elevenlabs"))
        if choice and choice.strip() in registry.list_stt():
            self.settings["stt_provider"] = choice.strip()
            save(self.settings)
            self.init_providers()
            self.sync_titles()

    def choose_interp(self, sender):
        choices = ", ".join(registry.list_interpreters())
        choice = self._ask_text(f"Available: {choices}", "Interpreter", self.settings.get("interpreter_provider", "openrouter"))
        if choice and choice.strip() in registry.list_interpreters():
            self.settings["interpreter_provider"] = choice.strip()
            save(self.settings)
            self.init_providers()
            self.sync_titles()

    def toggle_cleanup(self, sender):
        self.settings["cleanup_enabled"] = not self.settings.get("cleanup_enabled", True)
        save(self.settings)
        self.init_providers()
        notify("Listen", f"Cleanup {'on' if self.settings['cleanup_enabled'] else 'off'}")

    def quit_app(self, sender):
        if self.hotkey:
            self.hotkey.stop()
        rumps.quit_application()

    def _ask_text(self, message: str, title: str, default_text: str = "") -> Optional[str]:
        alert = NSAlert.alloc().init()
        alert.setMessageText_(title)
        alert.setInformativeText_(message)
        alert.addButtonWithTitle_("Save")
        alert.addButtonWithTitle_("Cancel")
        field = NSTextField.alloc().initWithFrame_(((0, 0), (360, 22)))
        field.setStringValue_(default_text)
        alert.setAccessoryView_(field)
        if alert.runModal() == NSAlertFirstButtonReturn:
            return field.stringValue()
        return None

    # ── Preferences ────────────────────────────────────────

    def show_prefs(self, sender):
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 420, 520), 15, 2, False,
        )
        win.setTitle_("Listen Preferences")
        win.center()

        bg = NSVisualEffectView.alloc().initWithFrame_(NSMakeRect(0, 0, 420, 520))
        bg.setMaterial_(8)
        bg.setBlendingMode_(1)
        bg.setState_(0)
        win.setContentView_(bg)

        y = 480
        fields = {}

        def sec(title, yv, h=100):
            s = _SectionView.alloc().initWithFrame_title_(NSMakeRect(20, yv, 380, h), title)
            bg.addSubview_(s)
            return s

        def lbl(text, parent, x, yv, w=130):
            l = NSTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 16))
            l.setStringValue_(text)
            l.setEditable_(False)
            l.setBordered_(False)
            l.setBackgroundColor_(NSColor.clearColor())
            l.setTextColor_(NSColor.colorWithCalibratedWhite_alpha_(0.7, 1.0))
            l.setFont_(NSFont.systemFontOfSize_(11))
            parent.addSubview_(l)

        def secure(val, parent, x, yv, w=220):
            f = NSSecureTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 22))
            f.setStringValue_(val)
            f.setFont_(NSFont.systemFontOfSize_(11))
            parent.addSubview_(f)
            return f

        def plain(val, parent, x, yv, w=220):
            f = NSTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 22))
            f.setStringValue_(val)
            f.setFont_(NSFont.systemFontOfSize_(11))
            parent.addSubview_(f)
            return f

        # API Keys
        s1 = sec("API Keys", y, h=210)
        lbl("OpenRouter", s1, 16, 140)
        fields["or"] = secure(self.settings.get("openrouter_api_key", ""), s1, 110, 138)
        lbl("ElevenLabs", s1, 16, 105)
        fields["el"] = secure(self.settings.get("elevenlabs_api_key", ""), s1, 110, 103)
        lbl("OpenAI", s1, 16, 70)
        fields["oa"] = secure(self.settings.get("openai_api_key", ""), s1, 110, 68)
        lbl("Groq", s1, 16, 35)
        fields["gq"] = secure(self.settings.get("groq_api_key", ""), s1, 110, 33)
        y -= 230

        # Providers
        s2 = sec("Providers", y, h=130)
        lbl("STT", s2, 16, 90)
        fields["stt"] = plain(self.settings.get("stt_provider", "elevenlabs"), s2, 110, 88, w=120)
        lbl("Interpreter", s2, 16, 55)
        fields["interp"] = plain(self.settings.get("interpreter_provider", "openrouter"), s2, 110, 53, w=120)
        lbl("Model", s2, 16, 20)
        fields["model"] = plain(self.settings.get("openrouter_model", "google/gemini-flash-1.5"), s2, 110, 18, w=240)
        y -= 150

        # Hotkey
        s3 = sec("Hotkey", y, h=70)
        lbl("Current", s3, 16, 30)
        fields["hk"] = plain(self.settings.get("hotkey", "alt_r"), s3, 110, 28, w=120)

        rec_btn = NSButton.alloc().initWithFrame_(NSMakeRect(240, 28, 120, 24))
        rec_btn.setTitle_("Record Key")
        rec_btn.setBezelStyle_(1)
        rec_btn.setTarget_(self)
        rec_btn.setAction_("startRecordKey:")
        s3.addSubview_(rec_btn)
        y -= 90

        # Options
        s4 = sec("Options", y, h=70)

        def tgl(text, parent, x, yv, checked, key):
            b = NSButton.alloc().initWithFrame_(NSMakeRect(x, yv, 130, 20))
            b.setButtonType_(NSSwitchButton)
            b.setTitle_(text)
            b.setState_(1 if checked else 0)
            b.setFont_(NSFont.systemFontOfSize_(11))
            parent.addSubview_(b)
            fields[key] = b
            return b

        tgl("Cleanup", s4, 16, 25, self.settings.get("cleanup_enabled", True), "clean")
        tgl("Paste", s4, 150, 25, self.settings.get("use_paste", True), "paste")
        y -= 90

        save_btn = NSButton.alloc().initWithFrame_(NSMakeRect(160, 20, 100, 28))
        save_btn.setTitle_("Save")
        save_btn.setBezelStyle_(1)
        save_btn.setTarget_(self)
        save_btn.setAction_("savePrefs:")
        bg.addSubview_(save_btn)

        self._pref_win = win
        self._pref_fields = fields
        win.makeKeyAndOrderFront_(None)

    def startRecordKey_(self, sender):
        alert = NSAlert.alloc().init()
        alert.setMessageText_("Record Hotkey")
        alert.setInformativeText_("Press the key you want to use as your hotkey...")
        alert.addButtonWithTitle_("Cancel")

        self._record_key_window = alert.window()
        self._recorded_key = None
        self._key_listener = None

        def on_press(key):
            try:
                self._recorded_key = key.name if hasattr(key, 'name') and key.name else str(key.char)
            except Exception:
                self._recorded_key = str(key)
            if self._key_listener:
                self._key_listener.stop()
            try:
                self._record_key_window.orderOut_(None)
            except Exception:
                pass
            if self._recorded_key and hasattr(self, '_pref_fields') and self._pref_fields:
                self._pref_fields["hk"].setStringValue_(self._recorded_key)
                notify("Listen", f"Hotkey set to: {self._recorded_key}")

        from pynput import keyboard
        self._key_listener = keyboard.Listener(on_press=on_press)
        self._key_listener.start()

        result = alert.runModal()
        if self._key_listener:
            self._key_listener.stop()
            self._key_listener = None

    def savePrefs_(self, sender):
        f = self._pref_fields
        self.settings["openrouter_api_key"] = f["or"].stringValue().strip()
        self.settings["elevenlabs_api_key"] = f["el"].stringValue().strip()
        self.settings["openai_api_key"] = f["oa"].stringValue().strip()
        self.settings["groq_api_key"] = f["gq"].stringValue().strip()
        self.settings["stt_provider"] = f["stt"].stringValue().strip()
        self.settings["interpreter_provider"] = f["interp"].stringValue().strip()
        self.settings["hotkey"] = f["hk"].stringValue().strip()
        self.settings["openrouter_model"] = f["model"].stringValue().strip()
        self.settings["cleanup_enabled"] = f["clean"].state() == 1
        self.settings["use_paste"] = f["paste"].state() == 1
        save(self.settings)
        self.init_providers()
        self.sync_titles()
        self.start_hotkey()
        if self._pref_win:
            self._pref_win.close()
        notify("Listen", "Preferences saved")


def main():
    ListenApp().run()


if __name__ == "__main__":
    main()
