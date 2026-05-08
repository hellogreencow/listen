"""Listen — Fast voice-to-text for macOS.

Floating pill UI (no menubar) for reliability.
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
    NSColor,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSMakeRect,
    NSMenu,
    NSMenuItem,
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
from Foundation import NSObject, NSTimer

from . import sounds
from .hotkey import HotkeyListener
from .providers import registry
from .recorder import AudioRecorder
from .settings import load, save
from .typer import paste_text, type_text


# ── Logging ──────────────────────────────────────────────

LOG_PATH = Path.home() / ".listen" / "debug.log"
_DEBUG = os.environ.get("LISTEN_DEBUG", "0") == "1"


def log(msg: str) -> None:
    if _DEBUG:
        ts = time.strftime("%H:%M:%S")
        line = f"[{ts}] {msg}\n"
        try:
            with open(LOG_PATH, "a") as f:
                f.write(line)
        except Exception:
            pass


# ── Config ───────────────────────────────────────────────

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

NSFloatingWindowLevel = 3
NSWindowCollectionBehaviorCanJoinAllSpaces = 1 << 0
NSWindowCollectionBehaviorStationary = 1 << 4


def notify(title: str, subtitle: str) -> None:
    log(f"NOTIFY: {title} — {subtitle}")
    try:
        n = NSUserNotification.alloc().init()
        n.setTitle_(title)
        n.setInformativeText_(subtitle)
        NSUserNotificationCenter.defaultUserNotificationCenter().deliverNotification_(n)
    except Exception as e:
        log(f"notify error: {e}")


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


def detect_mode() -> str:
    app = get_front_app()
    for key, mode in APP_DETECTION.items():
        if key in app:
            return mode
    return "default"


# ── Pill View ────────────────────────────────────────────

class _PillView(NSView):
    """Custom view that draws a rounded pill + status text."""

    def initWithFrame_(self, frame):
        self = objc.super(_PillView, self).initWithFrame_(frame)
        if self is None:
            return None
        self.label_text = "Listen"
        self.recording = False
        self.setWantsLayer_(True)
        return self

    def drawRect_(self, rect):
        bounds = self.bounds()
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            bounds, 16.0, 16.0
        )

        if self.recording:
            NSColor.colorWithCalibratedWhite_alpha_(0.25, 0.95).setFill()
        else:
            NSColor.colorWithCalibratedWhite_alpha_(0.15, 0.92).setFill()
        path.fill()

        if self.recording:
            text_color = NSColor.colorWithCalibratedRed_green_blue_alpha_(
                1.0, 0.85, 0.3, 1.0
            )  # warm yellow
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

        log("=== Listen started ===")
        self.recorder = AudioRecorder()
        self.hotkey: Optional[HotkeyListener] = None
        self.recording = False
        self.record_start_time: float = 0.0
        self.settings = load()
        # No artificial minimum duration — stop immediately on key release
        self.stt = None
        self.interpreter = None
        self.current_mode = "default"

        self._window: Optional[NSWindow] = None
        self._pill_view: Optional[_PillView] = None

        try:
            self.init_providers()
            log(f"providers: stt={self.stt is not None}, interp={self.interpreter is not None}")
        except Exception as e:
            log(f"init_providers error: {e}")

        sounds.set_enabled(self.settings.get("sound_enabled", False))

        try:
            self.start_hotkey()
            log("hotkey started")
        except Exception as e:
            log(f"start_hotkey error: {e}")

        return self

    def applicationDidFinishLaunching_(self, notification):
        log("applicationDidFinishLaunching")
        try:
            self._build_pill()
            self._build_context_menu()
            log("pill built")
        except Exception as e:
            log(f"build_pill error: {e}")
            traceback.print_exc()

    # ── Floating Pill ──────────────────────────────────────

    def _build_pill(self):
        screens = NSScreen.screens()
        screen = NSScreen.mainScreen() or (screens[0] if screens else None)
        if screen is None:
            log("no screen found")
            return

        frame = screen.visibleFrame()
        w, h = 120, 32
        x = frame.origin.x + frame.size.width - w - 16
        y = frame.origin.y + frame.size.height - h - 8

        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(x, y, w, h),
            0,  # borderless
            2,  # buffered
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
        self._window.setAcceptsMouseMovedEvents_(False)

        self._pill_view = _PillView.alloc().initWithFrame_(NSMakeRect(0, 0, w, h))
        self._pill_view.delegate = self
        self._window.setContentView_(self._pill_view)
        self._window.orderFront_(None)
        log(f"pill at ({x:.0f}, {y:.0f}) size ({w}, {h})")

    def setPillLabel_(self, label):
        try:
            if self._pill_view:
                self._pill_view.label_text = str(label)
                self._pill_view.setNeedsDisplay_(True)
        except Exception as e:
            log(f"setPillLabel error: {e}")

    def setPillRecording_(self, recording):
        try:
            if self._pill_view:
                self._pill_view.recording = bool(recording)
                self._pill_view.setNeedsDisplay_(True)
        except Exception as e:
            log(f"setPillRecording error: {e}")

    def set_pill_label(self, label: str) -> None:
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "setPillLabel:", label, False,
        )

    def set_pill_recording(self, recording: bool) -> None:
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "setPillRecording:", recording, False,
        )

    # ── Context Menu ───────────────────────────────────────

    def _build_context_menu(self):
        self._menu = NSMenu.alloc().init()
        self.add_menu_item(self._menu, "⚡ Record", "doRecord:")
        self._menu.addItem_(NSMenuItem.separatorItem())
        self.mode_item = self.add_menu_item(self._menu, "Mode: auto", "cycleMode:")
        self.stt_item = self.add_menu_item(self._menu, "STT: elevenlabs", "chooseStt:")
        self.interp_item = self.add_menu_item(self._menu, "Interpreter: openrouter", "chooseInterpreter:")
        self._menu.addItem_(NSMenuItem.separatorItem())
        self.add_menu_item(self._menu, "Toggle Cleanup", "toggleCleanup:")
        self._menu.addItem_(NSMenuItem.separatorItem())
        self.add_menu_item(self._menu, "Preferences...", "showPreferences:")
        self.add_menu_item(self._menu, "Quit", "terminate:")
        self.sync_titles()

    def add_menu_item(self, menu, title, action):
        m = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, "")
        m.setTarget_(self)
        menu.addItem_(m)
        return m

    def showContextMenu_(self, event):
        if self._menu:
            NSMenu.popUpContextMenu_withEvent_forView_(
                self._menu, event, self._pill_view
            )

    def sync_titles(self):
        s = self.settings
        self.stt_item.setTitle_(f"STT: {s.get('stt_provider', 'elevenlabs')}")
        self.interp_item.setTitle_(f"Interpreter: {s.get('interpreter_provider', 'openrouter')}")

    # ── Providers ──────────────────────────────────────────

    def init_providers(self):
        s = self.settings
        try:
            self.stt = registry.get_stt(s["stt_provider"], s)
        except Exception as e:
            self.stt = None
            log(f"stt init failed: {e}")
        try:
            if s.get("cleanup_enabled", False):
                self.interpreter = registry.get_interpreter(s["interpreter_provider"], s)
            else:
                self.interpreter = None
        except Exception as e:
            self.interpreter = None
            log(f"interpreter init failed: {e}")
        # Pre-warm STT connection in background so TCP/TLS is already established
        if self.stt and hasattr(self.stt, "session"):
            threading.Thread(target=self._warm_stt, daemon=True).start()

    def _warm_stt(self):
        try:
            if hasattr(self.stt, "session"):
                self.stt.session.head("https://api.elevenlabs.io/v1", timeout=5)
                log("stt connection warmed")
        except Exception:
            pass  # HEAD may 404, that's fine — TCP/TLS is still warmed

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
        log("on_press called")
        if self.recording:
            log("already recording, ignoring")
            return
        if not self.stt:
            log("no stt, playing error sound")
            sounds.error()
            return
        self.recording = True
        self.record_start_time = time.time()
        log("recording started")
        self.set_pill_label("Recording")
        self.set_pill_recording(True)
        try:
            self.recorder.start()
            log("recorder.start() OK")
        except Exception as e:
            log(f"recorder.start() FAILED: {e}")
            traceback.print_exc()
            self.recording = False
            self.set_pill_label("Listen ⚠️")
            self.set_pill_recording(False)
            sounds.error()
            notify("Listen", f"Recording failed: {e}")

    def on_release(self):
        log("on_release called")
        if not self.recording:
            return
        self.recording = False
        threading.Thread(target=self._process_thread, daemon=True).start()

    def _process_thread(self):
        log("process_thread started")
        try:
            self._do_process()
        except Exception as e:
            log(f"process_thread error: {e}")
            traceback.print_exc()
            sounds.error()
            self.set_pill_label("Listen ⚠️")
            self.set_pill_recording(False)

    def _do_process(self):
        t0 = time.perf_counter()

        log("stopping recorder...")
        try:
            path = self.recorder.stop()
            log(f"recorder stopped in {(time.perf_counter() - t0)*1000:.0f}ms, path={path}")
        except Exception as e:
            log(f"recorder.stop() failed: {e}")
            self.set_pill_label("Listen ⚠️")
            self.set_pill_recording(False)
            return

        sounds.stop()
        self.set_pill_label("... processing")
        self.set_pill_recording(False)

        # Detect front-app mode after recording (not during press)
        self.current_mode = detect_mode()
        log(f"mode={self.current_mode}")

        t1 = time.perf_counter()
        log("transcribing...")
        try:
            text = self.stt.transcribe(path)
            t2 = time.perf_counter()
            log(f"transcribed in {(t2-t1)*1000:.0f}ms: {text[:60]}...")
        except Exception as e:
            log(f"transcription failed: {e}")
            self.set_pill_label("Listen ⚠️")
            return

        if self.interpreter and text:
            t3 = time.perf_counter()
            log("interpreting...")
            try:
                mode_prompt = APP_MODES.get(self.current_mode, APP_MODES["default"])
                text = self.interpreter.interpret(text, instruction=mode_prompt)
                t4 = time.perf_counter()
                log(f"interpreted in {(t4-t3)*1000:.0f}ms: {text[:60]}...")
            except Exception as e:
                log(f"interpretation failed: {e}")

        # Delete temp file immediately (non-blocking)
        try:
            path.unlink()
        except Exception:
            pass

        t5 = time.perf_counter()
        log("pasting...")
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
            except Exception as e2:
                log(f"pbcopy also failed: {e2}")

        total = (time.perf_counter() - t0) * 1000
        self.set_pill_label("Listen")
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
        self.settings["cleanup_enabled"] = not self.settings.get("cleanup_enabled", False)
        save(self.settings)
        self.init_providers()
        notify("Listen", f"Cleanup {'on' if self.settings['cleanup_enabled'] else 'off'}")



    def showPreferences_(self, sender):
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 480, 360), 15, 2, False,
        )
        win.setTitle_("Listen Preferences")
        win.center()

        fx = NSVisualEffectView.alloc().initWithFrame_(NSMakeRect(0, 0, 480, 360))
        fx.setMaterial_(8)
        fx.setBlendingMode_(1)
        fx.setState_(0)
        win.setContentView_(fx)

        v = fx
        y = 310
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
        log("terminating")
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
