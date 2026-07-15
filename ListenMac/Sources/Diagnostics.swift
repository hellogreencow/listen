import Foundation

/// Small, private, bounded runtime log for state-transition diagnosis. Unified
/// logging often redacts the useful error body and LaunchServices discards
/// stderr, so this file is the stable source of truth during field failures.
final class ListenLogger: @unchecked Sendable {
    static let shared = ListenLogger()
    let url: URL
    private let lock = NSLock()

    private init() {
        let configured = ProcessInfo.processInfo.environment["LISTEN_LOG_PATH"]
        url = URL(fileURLWithPath: configured ?? "/tmp/listen.err.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch { try? handle.close() }
    }
}

func listenLog(_ message: String) {
    ListenLogger.shared.write(message)
    NSLog("[Listen] \(message)")
}
