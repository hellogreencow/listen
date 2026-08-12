import AppKit
import Carbon.HIToolbox

@MainActor
enum Paster {
    enum Outcome: Equatable {
        case success
        case accessibilityDenied
        case automationDenied
        case failed(String)

        var message: String {
            switch self {
            case .success:
                return "Ready"
            case .accessibilityDenied:
                return "Accessibility is required to send the paste shortcut."
            case .automationDenied:
                return "Automation access to System Events is required to paste."
            case .failed(let message):
                return message
            }
        }
    }

    /// Compiled once — NSAppleScript(source:) re-compiles on every call
    /// otherwise, which costs tens of ms per paste. Main-thread only.
    private static let pasteScript: NSAppleScript? = {
        let s = NSAppleScript(source:
            "tell application \"System Events\" to keystroke \"v\" using command down")
        s?.compileAndReturnError(nil)
        return s
    }()

    /// Put the transcribed text on the clipboard, fire Cmd+V, and leave the
    /// text there. We intentionally DO NOT restore the prior clipboard — that
    /// restore raced the synth Cmd+V (300 ms was eating the paste), and
    /// leaving the transcript on the clipboard means even if synth delivery
    /// fails, the user can manually Cmd+V and get the text.
    static func paste(_ text: String, completion: ((Outcome) -> Void)? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Give the pasteboard write a tick to commit before synthesizing.
        // Use NSAppleScript to drive System Events. CGEvent.post is silently
        // dropped on modern macOS for menubar-style background apps even with
        // Accessibility granted; AppleEvents → System Events is the
        // documented "bulletproof" path (see AGENTS.md). First run prompts
        // for Automation permission against System Events; granted thereafter.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            var err: NSDictionary?
            let result = pasteScript?.executeAndReturnError(&err)
            let outcome = outcome(for: err)
            // Direct file log — bypasses os_log privacy redaction so we can
            // actually read the AppleScript outcome.
            let line = "\(Date()) result=\(String(describing: result)) err=\(String(describing: err))\n"
            if let data = line.data(using: .utf8) {
                let url = URL(fileURLWithPath: "/tmp/listen-paste.log")
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                } else {
                    try? data.write(to: url)
                }
            }
            completion?(outcome)
        }
    }

    /// A harmless System Events query used by setup to trigger and verify the
    /// Automation consent prompt before the user's first real dictation.
    static func probeAutomation() -> Outcome {
        let source = "tell application \"System Events\" to get name of first application process whose frontmost is true"
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        let outcome = outcome(for: err)
        listenLog("setup automation probe result=\(result == nil ? "nil" : "ok") outcome=\(outcome.message)")
        return outcome
    }

    private static func outcome(for error: NSDictionary?) -> Outcome {
        guard let error else { return .success }
        let number = error["NSAppleScriptErrorNumber"] as? Int ?? 0
        switch number {
        case 1002:
            return .accessibilityDenied
        case -1743:
            return .automationDenied
        default:
            let message = error["NSAppleScriptErrorMessage"] as? String
                ?? "System Events could not paste."
            return .failed(message)
        }
    }
}
