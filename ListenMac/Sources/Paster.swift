import AppKit
import Carbon.HIToolbox

enum Paster {
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
    static func paste(_ text: String) {
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
        }
    }
}
