"""Listen — Fast voice-to-text for macOS.

Simple menubar app. No dock icon. Hold key → record → AI transcribe → paste.
"""

import os
import subprocess
import threading
import time
import traceback
from pathlib import Path
from typing import Optional

import objc
from AppKit import (
    NSAlert,
    NSAlertFirstButtonReturn,
    NSApplication,
    NSColor,
    NSFont,
    NSMakeRect,
    NSMenu,
    NSMenuItem,
    NSStatusBar,
    NSTextField,
    NSUserNotification,
    NSUserNotificationCenter,
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
        n = NSUserNotification.alloc().init()
        n.setTitle_(title)
        n.setInformativeText_(subtitle)
        NSUserNotificationCenter.defaultUserNotificationCenter().deliverNotification_(n)
    except Exception:
        pass


def ask_text(message: str, title: str, default_text: str = "") -> Optional[str]:
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


def get_front_app() -> str:
    try:
        ws = NSWorkspace.sharedWorkspace()
        app = ws.frontmostApplication()
        return app.localizedName() if app else ""
    except Exception:
        return ""


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
    app = get_front_app()
    for key, mode in APP_DETECTION.items():
        if key in app:
            return mode
    return "default"


# ── App Delegate ─────────────────────────────────────────

class AppDelegate(NSObject):

    def init(self):
        self = objc.super(AppDelegate, self).init()
        if self is None:
            return None

        self.recorder = AudioRecorder()
        self.hotkey: Optional[HotkeyListener] = None
        self.recording = False
        self.record_start_time: float = 0.0
        self.settings = load()
        self.stt = None
        self.interpreter = None
        self.current_mode = "default"
        self.status_item = None

        self.init_providers()
        sounds.set_enabled(self.settings.get("sound_enabled", False))
        self.start_hotkey()
        return self

    def applicationDidFinishLaunching_(self, notification):
        self.build_menu()

    # ── Menu ───────────────────────────────────────────────

    def build_menu(self):
        bar = NSStatusBar.systemStatusBar()
        self.status_item = bar.statusItemWithLength_(80)
        self.status_item.button().setTitle_("Listen")

        menu = NSMenu.alloc().init()
        self.add_item(menu, "Record", "doRecord:")
        menu.addItem_(NSMenuItem.separatorItem())
        self.mode_item = self.add_item(menu, "Mode: auto", "cycleMode:")
        self.stt_item = self.add_item(menu, "STT: elevenlabs", "chooseStt:")
        self.interp_item = self.add_item(menu, "Interpreter: openrouter", "chooseInterpreter:")
        menu.addItem_(NSMenuItem.separatorItem())
        self.add_item(menu, "Toggle Cleanup", "toggleCleanup:")
        menu.addItem_(NSMenuItem.separatorItem())
        self.add_item(menu, "Preferences...", "showPreferences:")
        self.add_item(menu, "Quit", "terminate:")
        self.status_item.setMenu_(menu)
        self.sync_titles()

    def add_item(self, menu, title, action):
        m = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, "")
        m.setTarget_(self)
        menu.addItem_(m)
        return m

    def sync_titles(self):
        s = self.settings
        self.stt_item.setTitle_(f"STT: {s.get('stt_provider', 'elevenlabs')}")
        self.interp_item.setTitle_(f"Interpreter: {s.get('interpreter_provider', 'openrouter')}")
        self.status_item.button().setTitle_(
            "Listen" if self.stt else "Listen !"
        )

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
        self.status_item.button().setTitle_("Recording")
        try:
            self.recorder.start()
        except Exception as e:
            log(f"recorder.start() failed: {e}")
            self.recording = False
            self.status_item.button().setTitle_("Listen !")
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
            self.status_item.button().setTitle_("Listen !")

    def _do_process(self):
        t0 = time.perf_counter()

        try:
            path = self.recorder.stop()
        except Exception as e:
            log(f"recorder.stop() failed: {e}")
            self.status_item.button().setTitle_("Listen !")
            return

        sounds.stop()
        self.status_item.button().setTitle_("Processing...")

        self.current_mode = detect_mode()

        t1 = time.perf_counter()
        try:
            text = self.stt.transcribe(path)
            t2 = time.perf_counter()
            log(f"transcribed in {(t2-t1)*1000:.0f}ms: {text[:60]}...")
        except Exception as e:
            log(f"transcription failed: {e}")
            self.status_item.button().setTitle_("Listen !")
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
        self.status_item.button().setTitle_("Listen" if self.stt else "Listen !")
        log(f"done — total after release: {total:.0f}ms")

    # ── Menu Actions ───────────────────────────────────────

    def doRecord_(self, sender):
        if not self.stt:
            notify("Listen", "Set API keys in Preferences")
            return
        self.on_press()
        time.sleep(3)
        self.on_release()

    def cycleMode_(self, sender):
        modes = list(APP_MODES.keys())
        idx = modes.index(self.current_mode) if self.current_mode in modes else 0
        self.current_mode = modes[(idx + 1) % len(modes)]
        self.mode_item.setTitle_(f"Mode: {self.current_mode}")
        notify("Listen", f"Mode: {self.current_mode}")

    def chooseStt_(self, sender):
        choices = ", ".join(registry.list_stt())
        choice = ask_text(f"Available: {choices}", "STT Provider", self.settings.get("stt_provider", "elevenlabs"))
        if choice and choice.strip() in registry.list_stt():
            self.settings["stt_provider"] = choice.strip()
            save(self.settings)
            self.init_providers()
            self.sync_titles()

    def chooseInterpreter_(self, sender):
        choices = ", ".join(registry.list_interpreters())
        choice = ask_text(f"Available: {choices}", "Interpreter", self.settings.get("interpreter_provider", "openrouter"))
        if choice and choice.strip() in registry.list_interpreters():
            self.settings["interpreter_provider"] = choice.strip()
            save(self.settings)
            self.init_providers()
            self.sync_titles()

    def toggleCleanup_(self, sender):
        self.settings["cleanup_enabled"] = not self.settings.get("cleanup_enabled", True)
        save(self.settings)
        self.init_providers()
        notify("Listen", f"Cleanup {'on' if self.settings['cleanup_enabled'] else 'off'}")

    def showPreferences_(self, sender):
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 480, 400), 15, 2, False,
        )
        win.setTitle_("Listen Preferences")
        win.center()

        fx = NSVisualEffectView.alloc().initWithFrame_(NSMakeRect(0, 0, 480, 400))
        fx.setMaterial_(8)
        fx.setBlendingMode_(1)
        fx.setState_(0)
        win.setContentView_(fx)

        v = fx
        y = 350
        gap = 30
        fields = {}

        def lbl(text, x, yv, w=180):
            l = NSTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 18))
            l.setStringValue_(text)
            l.setEditable_(False)
            l.setBordered_(False)
            l.setBackgroundColor_(NSColor.clearColor())
            l.setFont_(NSFont.systemFontOfSize_(12))
            v.addSubview_(l)

        def fld(val, x, yv, w=270):
            f = NSTextField.alloc().initWithFrame_(NSMakeRect(x, yv, w, 22))
            f.setStringValue_(val)
            f.setFont_(NSFont.systemFontOfSize_(11))
            v.addSubview_(f)
            return f

        lbl("OpenRouter Key", 20, y)
        fields["or"] = fld(self.settings.get("openrouter_api_key", ""), 150, y)
        y -= gap
        lbl("ElevenLabs Key", 20, y)
        fields["el"] = fld(self.settings.get("elevenlabs_api_key", ""), 150, y)
        y -= gap
        lbl("OpenAI Key", 20, y)
        fields["oa"] = fld(self.settings.get("openai_api_key", ""), 150, y)
        y -= gap
        lbl("Groq Key", 20, y)
        fields["gq"] = fld(self.settings.get("groq_api_key", ""), 150, y)
        y -= gap - 5
        lbl("STT", 20, y)
        fields["stt"] = fld(self.settings.get("stt_provider", "elevenlabs"), 150, y, 130)
        lbl("Interpreter", 290, y)
        fields["interp"] = fld(self.settings.get("interpreter_provider", "openrouter"), 380, y, 90)
        y -= gap
        lbl("Hotkey", 20, y)
        fields["hk"] = fld(self.settings.get("hotkey", "alt_r"), 150, y, 130)
        lbl("Model", 290, y)
        fields["model"] = fld(self.settings.get("openrouter_model", "google/gemini-flash-1.5"), 340, y, 130)
        y -= gap + 5

        def tgl(text, x, yv, checked, key):
            b = NSButton.alloc().initWithFrame_(NSMakeRect(x, yv, 130, 20))
            b.setButtonType_(NSSwitchButton)
            b.setTitle_(text)
            b.setState_(1 if checked else 0)
            b.setFont_(NSFont.systemFontOfSize_(11))
            v.addSubview_(b)
            fields[key] = b
            return b

        tgl("Cleanup", 20, y, self.settings.get("cleanup_enabled", True), "clean")
        tgl("Paste", 170, y, self.settings.get("use_paste", True), "paste")
        y -= gap

        save_btn = NSButton.alloc().initWithFrame_(NSMakeRect(190, y, 100, 28))
        save_btn.setTitle_("Save")
        save_btn.setBezelStyle_(1)
        save_btn.setTarget_(self)
        save_btn.setAction_("savePrefs:")
        v.addSubview_(save_btn)

        self._pref_win = win
        self._pref_fields = fields
        win.makeKeyAndOrderFront_(None)

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

    def terminate_(self, sender):
        if self.hotkey:
            self.hotkey.stop()
        NSApplication.sharedApplication().terminate_(None)


def main():
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(1)
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    app.run()


if __name__ == "__main__":
    main()
