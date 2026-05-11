import AppKit
import Carbon.HIToolbox

enum Paster {
    /// Copy to pasteboard and synthesize Cmd+V into the frontmost app.
    static func paste(_ text: String, restoreClipboard: Bool = true) {
        let pb = NSPasteboard.general
        let prior = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Post Cmd+V — keycode for 'v' is 9.
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if restoreClipboard, let prior {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents()
                pb.setString(prior, forType: .string)
            }
        }
    }
}
