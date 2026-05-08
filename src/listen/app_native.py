"""Listen — Fast voice-to-text for macOS.

Floating pill (primary visible UI) + menubar (menu access).
Menubar is invisible on some Macs, so the pill guarantees visibility.
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
    NSBezierPath,
    NSBox,
    NSColor,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSMakeRect,
    NSMenu,
    NSMenuItem,
    NSScreen,
    NSSecureTextField,
    NSStatusBar,
    NSString,
    NSTextField,
    NSUserNotification,
    NSUserNotificationCenter,
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
        n = NSUserNotification.alloc().init()
        n.setTitle_(title)
        n.setInformativeText_(subtitle)
        NSUserNotificationCenter.defaultUserNotificationCenter().deliverNotification_(n)
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


NSFloatingWindowLevel = 3
NSWindowCollectionBehaviorCanJoinAllSpaces = 1 << 0
NSWindowCollectionBehaviorStationary = 1 << 4


class _PillView(NSView):
    """Minimal pill: plain text, no dots, no emoji."""

    def initWithFrame_(self, frame):
        self = objc.super(_PillView, self).initWithFrame_(frame)
        if self is None:
            return None
        self.label_text = "voice"
        self.recording = False
        self.setWantsLayer_(True)
        return self

    def drawRect_(self, rect):
        bounds = self.bounds()
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            bounds, 14.0, 14.0
        )

        if self.recording:
            NSColor.colorWithCalibratedWhite_alpha_(0.22, 0.95).setFill()
        else:
            NSColor.colorWithCalibratedWhite_alpha_(0.15, 0.92).setFill()
        path.fill()

        if self.recording:
            text_color = NSColor.colorWithCalibratedRed_green_blue_alpha_(
                1.0, 0.75, 0.35, 1.0
            )
        else:
            text_color = NSColor.whiteColor()

        attrs = {
            NSFontAttributeName: NSFont.systemFontOfSize_(13),
            NSForegroundColorAttributeName: text_color,
        }
        text = NSString.stringWithString_(self.label_text)
        text.drawAtPoint_withAttributes_((14, bounds.size.height / 2 - 8), attrs)

    def rightMouseDown_(self, event):
        if hasattr(self, "delegate") and self.delegate:
            self.delegate.showContextMenu_(event)


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

        self._window: Optional[NSWindow] = None
        self._pill_view: Optional[_PillView] = None

        self.init_providers()
        sounds.set_enabled(self.settings.get("sound_enabled", False))
        self.start_hotkey()
        return self

    def applicationDidFinishLaunching_(self, notification):
        self.build_menu()
        self.build_pill()

    # ── Pill ───────────────────────────────────────────────

    def build_pill(self):
        screens = NSScreen.screens()
        screen = NSScreen.mainScreen() or (screens[0] if screens else None)
        if screen is None:
            return

        frame = screen.visibleFrame()
        w, h = 100, 28
        x = frame.origin.x + frame.size.width - w - 16
        y = frame.origin.y + frame.size.height - h - 8

        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(x, y, w, h),
            0,
            2,
            False,
        )
        self._window.setLevel_(NSFloatingWindowLevel)
        self._window.setBackgroundColor_(NSColor.clearColor())
        self._window.setOpaque_(False)
        self._window.setHasShadow_(True)
        self._window.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
        )
        self._window.setIgnoresMouseEvents_(False)

        self._pill_view = _PillView.alloc().initWithFrame_(NSMakeRect(0, 0, w, h))
        self._pill_view.delegate = self
        self._window.setContentView_(self._pill_view)
        self._window.orderFront_(None)

    def setPillLabel_(self, label):
        try:
            if self._pill_view:
                self._pill_view.label_text = str(label)
                self._pill_view.setNeedsDisplay_(True)
        except Exception:
            pass

    def setPillRecording_(self, recording):
        try:
            if self._pill_view:
                self._pill_view.recording = bool(recording)
                self._pill_view.setNeedsDisplay_(True)
        except Exception:
            pass

    def set_pill_label(self, label: str) -> None:
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "setPillLabel_:", label, False,
        )

    def set_pill_recording(self, recording: bool) -> None:
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "setPillRecording_:", recording, False,
        )

    # ── Menu ───────────────────────────────────────────────

    def build_menu(self):
        bar = NSStatusBar.systemStatusBar()
        self.status_item = bar.statusItemWithLength_(80)
        btn = self.status_item.button()
        btn.setTitle_("voice")
        btn.setFont_(NSFont.systemFontOfSize_(12))

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

    def showContextMenu_(self, event):
        if self.status_item and self.status_item.menu():
            NSMenu.popUpContextMenu_withEvent_forView_(
                self.status_item.menu(), event, self._pill_view
            )

    def sync_titles(self):
        s = self.settings
        self.stt_item.setTitle_(f"STT: {s.get('stt_provider', 'elevenlabs')}")
        self.interp_item.setTitle_(f"Interpreter: {s.get('interpreter_provider', 'openrouter')}")
        self.status_item.button().setTitle_("voice")

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
        self.status_item.button().setTitle_("recording")
        self.set_pill_label("recording")
        self.set_pill_recording(True)
        try:
            self.recorder.start()
        except Exception as e:
            log(f"recorder.start() failed: {e}")
            self.recording = False
            self.status_item.button().setTitle_("voice")
            self.set_pill_label("voice")
            self.set_pill_recording(False)
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
            self.status_item.button().setTitle_("voice")
            self.set_pill_label("voice")
            self.set_pill_recording(False)

    def _do_process(self):
        t0 = time.perf_counter()

        try:
            path = self.recorder.stop()
        except Exception as e:
            log(f"recorder.stop() failed: {e}")
            self.status_item.button().setTitle_("voice")
            self.set_pill_label("voice")
            self.set_pill_recording(False)
            return

        sounds.stop()
        self.status_item.button().setTitle_("thinking...")
        self.set_pill_label("thinking...")
        self.set_pill_recording(False)

        self.current_mode = detect_mode()

        t1 = time.perf_counter()
        try:
            text = self.stt.transcribe(path)
            t2 = time.perf_counter()
            log(f"transcribed in {(t2-t1)*1000:.0f}ms: {text[:60]}...")
        except Exception as e:
            log(f"transcription failed: {e}")
            self.status_item.button().setTitle_("voice")
            self.set_pill_label("voice")
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
        self.status_item.button().setTitle_("voice")
        self.set_pill_label("voice")
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
        choice = self._ask_text(f"Available: {choices}", "STT Provider", self.settings.get("stt_provider", "elevenlabs"))
        if choice and choice.strip() in registry.list_stt():
            self.settings["stt_provider"] = choice.strip()
            save(self.settings)
            self.init_providers()
            self.sync_titles()

    def chooseInterpreter_(self, sender):
        choices = ", ".join(registry.list_interpreters())
        choice = self._ask_text(f"Available: {choices}", "Interpreter", self.settings.get("interpreter_provider", "openrouter"))
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

    def showPreferences_(self, sender):
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
        gap = 36
        fields = {}

        def sec(title, yv, h=100):
            s = _PillView.alloc().initWithFrame_title_(NSMakeRect(20, yv, 380, h), title)
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

        # ── API Keys ──────────────────────────────────────
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

        # ── Providers ─────────────────────────────────────
        s2 = sec("Providers", y, h=130)
        lbl("STT", s2, 16, 90)
        fields["stt"] = plain(self.settings.get("stt_provider", "elevenlabs"), s2, 110, 88, w=120)
        lbl("Interpreter", s2, 16, 55)
        fields["interp"] = plain(self.settings.get("interpreter_provider", "openrouter"), s2, 110, 53, w=120)
        lbl("Model", s2, 16, 20)
        fields["model"] = plain(self.settings.get("openrouter_model", "google/gemini-flash-1.5"), s2, 110, 18, w=240)
        y -= 150

        # ── Hotkey ────────────────────────────────────────
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

        # ── Options ───────────────────────────────────────
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
