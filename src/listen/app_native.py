"""Listen — Fast voice-to-text for macOS.

Menubar-only via rumps. Zero pill. Zero emoji. Plain text only.
"""

import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

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
    NSWorkspace,
)
from Foundation import NSObject
from PyObjCTools.AppHelper import callAfter

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

        self._pref_win = None
        self._pref_fields = {}
        self._record_key_listener = None
        self._record_key_window = None

        self.init_providers()
        sounds.set_enabled(self.settings.get("sound_enabled", False))
        self.start_hotkey()
        self.build_menu()
        # Startup notification
        hotkey_display = self.settings.get("hotkey", "ctrl_r").replace("_", " ").title()
        notify("Listen", f"Hold {hotkey_display} to record")

    def build_menu(self):
        self._mi_record = rumps.MenuItem("Record", callback=self.do_record)
        self._mi_test = rumps.MenuItem("Test Recording", callback=self.test_record)
        self._mi_mode = rumps.MenuItem("Mode: auto", callback=self.cycle_mode)
        self._mi_stt = rumps.MenuItem("STT: elevenlabs", callback=self.choose_stt)
        self._mi_interp = rumps.MenuItem("Interpreter: openrouter", callback=self.choose_interp)
        self._mi_cleanup = rumps.MenuItem("Toggle Cleanup", callback=self.toggle_cleanup)
        self._mi_prefs = rumps.MenuItem("Preferences...", callback=self.show_prefs)
        self._mi_quit = rumps.MenuItem("Quit", callback=self.quit_app)
        self.menu = [
            self._mi_record,
            self._mi_test,
            None,
            self._mi_mode,
            self._mi_stt,
            self._mi_interp,
            None,
            self._mi_cleanup,
            None,
            self._mi_prefs,
            self._mi_quit,
        ]
        self.sync_titles()

    def sync_titles(self):
        s = self.settings
        self._mi_stt.title = f"STT: {s.get('stt_provider', 'elevenlabs')}"
        self._mi_interp.title = f"Interpreter: {s.get('interpreter_provider', 'openrouter')}"
        self._mi_mode.title = f"Mode: {self.current_mode}"

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
        self.title = "thinking..."

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

    def test_record(self, sender):
        """Simulate a press/release to test the pipeline without hotkey."""
        if not self.stt:
            notify("Listen", "No STT configured — check Preferences")
            return
        threading.Thread(target=self._test_thread, daemon=True).start()

    def _test_thread(self):
        try:
            self.on_press()
            time.sleep(3)
            self.on_release()
            time.sleep(8)
            if self.title == "Listen":
                notify("Listen", "Test complete — pipeline works!")
            else:
                notify("Listen", "Test timed out — check logs")
        except Exception as e:
            notify("Listen", f"Test failed: {e}")

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
        # Kill any old window
        if self._pref_win:
            try:
                self._pref_win.close()
            except Exception:
                pass
            self._pref_win = None

        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 400, 440), 15, 2, False,
        )
        win.setTitle_("Preferences")
        win.center()

        v = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 400, 440))
        v.setWantsLayer_(True)
        v.layer().setBackgroundColor_(NSColor.whiteColor().CGColor())
        win.setContentView_(v)

        fields = {}
        y = 400

        def lbl(text, x, yv, w=130, dark=True):
            l = NSTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 16))
            l.setStringValue_(text)
            l.setEditable_(False)
            l.setBordered_(False)
            l.setBackgroundColor_(NSColor.clearColor())
            l.setTextColor_(NSColor.blackColor() if dark else NSColor.darkGrayColor())
            l.setFont_(NSFont.systemFontOfSize_(12) if dark else NSFont.systemFontOfSize_(11))
            v.addSubview_(l)

        def secure(val, x, yv, w=250):
            f = NSSecureTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 22))
            f.setStringValue_(val)
            f.setFont_(NSFont.systemFontOfSize_(11))
            v.addSubview_(f)
            return f

        def plain(val, x, yv, w=250):
            f = NSTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 22))
            f.setStringValue_(val)
            f.setFont_(NSFont.systemFontOfSize_(11))
            v.addSubview_(f)
            return f

        lbl("API Keys", 20, y)
        y -= 26
        lbl("OpenRouter", 20, y, dark=False)
        fields["or"] = secure(self.settings.get("openrouter_api_key", ""), 120, y - 2)
        y -= 28
        lbl("ElevenLabs", 20, y, dark=False)
        fields["el"] = secure(self.settings.get("elevenlabs_api_key", ""), 120, y - 2)
        y -= 28
        lbl("OpenAI", 20, y, dark=False)
        fields["oa"] = secure(self.settings.get("openai_api_key", ""), 120, y - 2)
        y -= 28
        lbl("Groq", 20, y, dark=False)
        fields["gq"] = secure(self.settings.get("groq_api_key", ""), 120, y - 2)
        y -= 36

        lbl("Providers", 20, y)
        y -= 26
        lbl("STT", 20, y, dark=False)
        fields["stt"] = plain(self.settings.get("stt_provider", "elevenlabs"), 120, y - 2, w=120)
        y -= 28
        lbl("Interpreter", 20, y, dark=False)
        fields["interp"] = plain(self.settings.get("interpreter_provider", "openrouter"), 120, y - 2, w=120)
        y -= 28
        lbl("Model", 20, y, dark=False)
        fields["model"] = plain(self.settings.get("openrouter_model", "google/gemini-flash-1.5"), 120, y - 2, w=250)
        y -= 36

        lbl("Hotkey", 20, y)
        y -= 26
        lbl("Key name", 20, y, dark=False)
        fields["hk"] = plain(self.settings.get("hotkey", "ctrl_r"), 120, y - 2, w=120)

        rec_btn = NSButton.alloc().initWithFrame_(NSMakeRect(260, y - 2, 120, 24))
        rec_btn.setTitle_("Record Key")
        rec_btn.setBezelStyle_(1)
        rec_btn.setTarget_(self)
        rec_btn.setAction_("doRecordKey:")
        v.addSubview_(rec_btn)
        y -= 36

        lbl("Options", 20, y)
        y -= 26
        b1 = NSButton.alloc().initWithFrame_(NSMakeRect(20, y - 2, 100, 20))
        b1.setButtonType_(NSSwitchButton)
        b1.setTitle_("Cleanup")
        b1.setState_(1 if self.settings.get("cleanup_enabled", True) else 0)
        b1.setFont_(NSFont.systemFontOfSize_(11))
        v.addSubview_(b1)
        fields["clean"] = b1

        b2 = NSButton.alloc().initWithFrame_(NSMakeRect(140, y - 2, 100, 20))
        b2.setButtonType_(NSSwitchButton)
        b2.setTitle_("Paste")
        b2.setState_(1 if self.settings.get("use_paste", True) else 0)
        b2.setFont_(NSFont.systemFontOfSize_(11))
        v.addSubview_(b2)
        fields["paste"] = b2
        y -= 40

        save_btn = NSButton.alloc().initWithFrame_(NSMakeRect(150, y, 100, 28))
        save_btn.setTitle_("Save")
        save_btn.setBezelStyle_(1)
        save_btn.setTarget_(self)
        save_btn.setAction_("savePrefs:")
        v.addSubview_(save_btn)

        self._pref_win = win
        self._pref_fields = fields
        win.makeKeyAndOrderFront_(None)

    # ── Record Key (thread-safe) ───────────────────────────

    def doRecordKey_(self, sender):
        """Open a capture window. Key press is captured by pynput and dispatched to main thread."""
        # Close old capture window if any
        if self._record_key_window:
            try:
                self._record_key_window.orderOut_(None)
            except Exception:
                pass
            self._record_key_window = None
        if self._record_key_listener:
            try:
                self._record_key_listener.stop()
            except Exception:
                pass
            self._record_key_listener = None

        # Create simple capture window
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 300, 120), 1, 2, False,
        )
        win.setTitle_("Record Key")
        win.center()

        v = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 300, 120))
        v.setWantsLayer_(True)
        v.layer().setBackgroundColor_(NSColor.whiteColor().CGColor())
        win.setContentView_(v)

        lbl = NSTextField.alloc().initWithFrame_(NSMakeRect(20, 60, 260, 20))
        lbl.setStringValue_("Press any key...")
        lbl.setEditable_(False)
        lbl.setBordered_(False)
        lbl.setBackgroundColor_(NSColor.clearColor())
        lbl.setTextColor_(NSColor.blackColor())
        lbl.setFont_(NSFont.systemFontOfSize_(14))
        lbl.setAlignment_(1)  # center
        v.addSubview_(lbl)

        cancel = NSButton.alloc().initWithFrame_(NSMakeRect(100, 20, 100, 24))
        cancel.setTitle_("Cancel")
        cancel.setBezelStyle_(1)
        cancel.setTarget_(self)
        cancel.setAction_("cancelRecordKey:")
        v.addSubview_(cancel)

        self._record_key_window = win
        self._record_key_label = lbl
        win.makeKeyAndOrderFront_(None)

        # Start pynput listener
        from pynput import keyboard

        def on_press(key):
            try:
                name = key.name if hasattr(key, 'name') and key.name else str(key.char)
            except Exception:
                name = str(key)
            # Dispatch to main thread - NEVER touch UI from pynput thread
            callAfter(self.finishRecordKey_, name)

        self._record_key_listener = keyboard.Listener(on_press=on_press)
        self._record_key_listener.start()

    def cancelRecordKey_(self, sender):
        if self._record_key_listener:
            try:
                self._record_key_listener.stop()
            except Exception:
                pass
            self._record_key_listener = None
        if self._record_key_window:
            try:
                self._record_key_window.orderOut_(None)
            except Exception:
                pass
            self._record_key_window = None

    def finishRecordKey_(self, key_name):
        """Called on main thread after key is pressed."""
        # Stop listener
        if self._record_key_listener:
            try:
                self._record_key_listener.stop()
            except Exception:
                pass
            self._record_key_listener = None

        # Close capture window
        if self._record_key_window:
            try:
                self._record_key_window.orderOut_(None)
            except Exception:
                pass
            self._record_key_window = None

        # Update preferences field
        if key_name and self._pref_fields and "hk" in self._pref_fields:
            self._pref_fields["hk"].setStringValue_(key_name)

        # Save immediately
        self.settings["hotkey"] = key_name
        save(self.settings)
        self.start_hotkey()
        notify("Listen", f"Hotkey set to: {key_name}")

    # ── Save Preferences ───────────────────────────────────

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
            try:
                self._pref_win.close()
            except Exception:
                pass
            self._pref_win = None
        notify("Listen", "Preferences saved")


def main():
    ListenApp().run()


if __name__ == "__main__":
    main()
