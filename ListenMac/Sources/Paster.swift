import AppKit
import Carbon.HIToolbox

enum Paster {
    /// Put the transcribed text on the clipboard, fire Cmd+V, and leave the
    /// text there. We intentionally DO NOT restore the prior clipboard — that
    /// restore raced the synth Cmd+V (300 ms was eating the paste), and
    /// leaving the transcript on the clipboard means even if synth delivery
    /// fails, the user can manually Cmd+V and get the text.
    static func paste(_ text: String, restoreClipboard: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Give the pasteboard write a tick to commit before synthesizing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Use combinedSessionState + cgAnnotatedSessionEventTap. This
            // combination is what works for background/menubar apps that need
            // to deliver synth Cmd+V to a different frontmost app. The
            // .hidSystemState + .cghidEventTap combo is the textbook docs
            // pairing but is often silently rejected for non-foreground
            // posters on modern macOS.
            let src = CGEventSource(stateID: .combinedSessionState)
            src?.localEventsSuppressionInterval = 0
            let v = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            usleep(8_000) // 8 ms — some apps drop the up if it arrives same tick
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
