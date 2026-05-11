import AppKit
import Carbon.HIToolbox

/// Global hold-to-record hotkey using NSEvent global monitors. This is what
/// Wispr Flow / Superwhisper / Whisper Memos use:
///   • For modifier keys (ctrl, opt, cmd, shift, fn) we watch .flagsChanged.
///     Modifier observation is NOT gated by Input Monitoring on macOS 10.15+.
///   • For function keys (F13-F19) we watch .keyDown/.keyUp; Accessibility
///     is sufficient (no Input Monitoring required).
///
/// Either way, the user never sees the Input Monitoring prompt.
final class Hotkey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pressed = false
    private var keyName: String = "ctrl_r"

    /// Modifier hotkeys → (NSEvent.ModifierFlags element to test, virtual keycode of physical key).
    private static let modifierMap: [String: (NSEvent.ModifierFlags, Int)] = [
        "ctrl":     (.control,  kVK_Control),
        "ctrl_r":   (.control,  kVK_RightControl),
        "alt":      (.option,   kVK_Option),
        "alt_r":    (.option,   kVK_RightOption),
        "cmd":      (.command,  kVK_Command),
        "cmd_r":    (.command,  kVK_RightCommand),
        "shift":    (.shift,    kVK_Shift),
        "shift_r":  (.shift,    kVK_RightShift),
        "fn":       (.function, kVK_Function),
    ]

    private static let keyCodeMap: [String: Int] = [
        "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
        "escape": kVK_Escape,
    ]

    static let supportedKeys: [(label: String, key: String)] = [
        ("Fn (Globe)", "fn"),
        ("Right Control", "ctrl_r"),
        ("Left Control", "ctrl"),
        ("Right Option", "alt_r"),
        ("Left Option", "alt"),
        ("Right Command", "cmd_r"),
        ("Left Command", "cmd"),
        ("F13", "f13"),
        ("F14", "f14"),
        ("F15", "f15"),
        ("F16", "f16"),
        ("F17", "f17"),
        ("F18", "f18"),
        ("F19", "f19"),
    ]

    func start(keyName: String) {
        stop()
        self.keyName = keyName

        if let (flag, keyCode) = Hotkey.modifierMap[keyName] {
            installModifierMonitor(flag: flag, keyCode: keyCode)
        } else if let keyCode = Hotkey.keyCodeMap[keyName] {
            installFunctionKeyMonitor(keyCode: keyCode)
        } else {
            NSLog("[Listen] unknown hotkey '\(keyName)' — defaulting to ctrl_r")
            installModifierMonitor(flag: .control, keyCode: kVK_RightControl)
        }
        NSLog("[Listen] hotkey active: \(keyName)")
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        pressed = false
    }

    // MARK: - Modifier-key push-to-talk (no permissions needed)

    private func installModifierMonitor(flag: NSEvent.ModifierFlags, keyCode: Int) {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            guard Int(event.keyCode) == keyCode else { return }
            self.fire(down: event.modifierFlags.contains(flag))
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    // MARK: - Function-key push-to-talk

    private func installFunctionKeyMonitor(keyCode: Int) {
        let press: (NSEvent) -> Void = { [weak self] event in
            guard let self, Int(event.keyCode) == keyCode else { return }
            self.fire(down: event.type == .keyDown)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp], handler: press)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            press(event)
            return event
        }
    }

    // MARK: -

    private func fire(down: Bool) {
        if down && !pressed {
            pressed = true
            DispatchQueue.main.async { self.onPress() }
        } else if !down && pressed {
            pressed = false
            DispatchQueue.main.async { self.onRelease() }
        }
    }
}
