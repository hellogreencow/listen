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
@MainActor
final class Hotkey {
    nonisolated static let leftCommandDeviceMask: UInt = 0x0000_0008 // NX_DEVICELCMDKEYMASK

    nonisolated static func isLeftCommandDown(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.rawValue & leftCommandDeviceMask != 0
    }

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}
    var onQuickThoughtPress: () -> Void = {}
    var onQuickThoughtRelease: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pressed = false
    private var quickPressed = false
    private var leftCommandDown = false
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
        if Hotkey.modifierMap[keyName] == nil && Hotkey.keyCodeMap[keyName] == nil {
            NSLog("[Listen] unknown hotkey '\(keyName)' — defaulting to alt_r")
            self.keyName = "alt_r"
        }

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event)
            return event
        }
        NSLog("[Listen] hotkey active: \(keyName)")
    }

    func stop() {
        let shouldCancelCapture = pressed || quickPressed
        if shouldCancelCapture { onCancel() }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor  { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        pressed = false
        quickPressed = false
        leftCommandDown = false
    }

    // MARK: - Event routing

    private func handle(_ event: NSEvent) {
        let code = Int(event.keyCode)
        if event.type == .flagsChanged, code == kVK_Command {
            // `.command` combines both sides, so it remains set when Left
            // Command is released while Right Command is still down. The
            // device-dependent left bit tracks the physical chord edge.
            leftCommandDown = Self.isLeftCommandDown(in: event.modifierFlags)
        }

        // Quick Thought is a fixed muscle-memory chord independent of the
        // configurable dictation key: hold Left Command + either Option.
        let chordDown = leftCommandDown && event.modifierFlags.contains(.option)
        if chordDown && !quickPressed {
            quickPressed = true
            if pressed {
                pressed = false
                onCancel()
            }
            onQuickThoughtPress()
        } else if !chordDown && quickPressed {
            quickPressed = false
            onQuickThoughtRelease()
        }
        // Never reinterpret either edge of the Quick Thought chord as a
        // dictation edge when the configurable key is one of its modifiers.
        if chordDown || quickPressed { return }

        if let (flag, keyCode) = Hotkey.modifierMap[keyName],
           event.type == .flagsChanged, code == keyCode {
            fire(down: event.modifierFlags.contains(flag))
        } else if let keyCode = Hotkey.keyCodeMap[keyName], code == keyCode,
                  event.type == .keyDown || event.type == .keyUp {
            fire(down: event.type == .keyDown)
        }
    }

    // MARK: -

    private func fire(down: Bool) {
        if down && !pressed {
            pressed = true
            onPress()
        } else if !down && pressed {
            pressed = false
            onRelease()
        }
    }
}
