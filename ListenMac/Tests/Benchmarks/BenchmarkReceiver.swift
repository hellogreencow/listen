import AppKit

private let logURL = URL(fileURLWithPath: "/tmp/listen-benchmark-receiver.jsonl")

private func appendResult(_ text: String) {
    let payload: [String: Any] = [
        "uptime": ProcessInfo.processInfo.systemUptime,
        "text": text,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          var line = String(data: data, encoding: .utf8) else { return }
    line.append("\n")
    guard let bytes = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(bytes)
        try? handle.close()
    } else {
        try? bytes.write(to: logURL, options: .atomic)
    }
}

@MainActor
final class ReceiverDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private var clearing = false
    private var changeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
        scroll.hasVerticalScroller = true
        textView = NSTextView(frame: scroll.bounds)
        textView.font = .systemFont(ofSize: 20)
        textView.isRichText = false
        textView.string = ""
        scroll.documentView = textView

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Listen Dictation Benchmark"
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
        changeObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordChange() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        window?.makeKeyAndOrderFront(nil)
        if let textView { window?.makeFirstResponder(textView) }
    }

    private func recordChange() {
        guard !clearing else { return }
        let value = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        appendResult(value)
        clearing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.textView.string = ""
            self.window.makeFirstResponder(self.textView)
            self.clearing = false
        }
    }

}

let app = NSApplication.shared
let delegate = ReceiverDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
