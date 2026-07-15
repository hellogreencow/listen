import Foundation

enum HermesAnalysisError: LocalizedError, Sendable {
    case unavailable
    case timedOut
    case failed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Hermes Agent's public CLI or Listen adapter is not installed."
        case .timedOut:
            return "Hermes analysis timed out."
        case .failed(let message):
            return "Hermes analysis failed: \(message)"
        case .emptyResponse:
            return "Hermes returned no analysis."
        }
    }
}

/// Writes adapter input away from the process-monitoring thread. A Hermes
/// adapter is an external executable and may stop draining stdin; keeping the
/// writer isolated lets cancellation or the deadline terminate the child,
/// close its read end, and unblock this write before teardown returns.
private final class HermesStdinWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let payload: Data
    private let completion = DispatchGroup()

    init(handle: FileHandle, payload: Data) {
        self.handle = handle
        self.payload = payload
    }

    func start() {
        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                completion.leave()
            }
            try? handle.write(contentsOf: payload)
        }
    }

    func wait() {
        completion.wait()
    }
}

/// Optional bridge into the user's local Hermes installation. Integration is
/// through Hermes's public one-shot CLI or a versioned stdin/stdout adapter;
/// Listen never imports Hermes's private Python modules or repository layout.
struct HermesInterpreter: Interpreter {
    private static let maximumCLIArgumentBytes = 64 * 1_024

    private enum Runtime: Sendable {
        case adapter(URL)
        case cli(URL)
    }

    static var isAvailable: Bool { adapterExecutable != nil || cliExecutable != nil }

    private static var adapterExecutable: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["LISTEN_HERMES_ADAPTER_V1"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        return executable(named: "listen-hermes-adapter-v1")
    }

    private static var cliExecutable: URL? {
        executable(named: "hermes")
    }

    /// Keep normal one-shot requests comfortably below macOS's aggregate argv
    /// limit. Larger conversation prompts must use the versioned stdin adapter
    /// so they neither fail process launch nor appear in process arguments.
    static func cliPromptFits(_ prompt: String) -> Bool {
        prompt.utf8.count <= maximumCLIArgumentBytes
    }

    private static func runtime(for prompt: String) throws -> Runtime {
        if let adapterExecutable { return .adapter(adapterExecutable) }
        guard cliPromptFits(prompt) else {
            throw HermesAnalysisError.failed(
                "This report is too large for hermes --oneshot. Install listen-hermes-adapter-v1 to pass it privately over stdin."
            )
        }
        guard let cliExecutable else { throw HermesAnalysisError.unavailable }
        return .cli(cliExecutable)
    }

    func interpret(_ text: String, prompt: String) async throws -> String {
        let filled = prompt.replacingOccurrences(of: "{text}", with: text)
        let runtime = try Self.runtime(for: filled)
        let operation = Task.detached(priority: .userInitiated) {
            try run(runtime: runtime, prompt: filled)
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            // Detached work is unstructured and otherwise survives the
            // parent's provider timeout. The polling loop below observes this
            // cancellation, terminates Hermes, and waits for its exit.
            operation.cancel()
        }
    }

    private func run(runtime: Runtime, prompt: String) throws -> String {
        let process = Process()
        switch runtime {
        case .adapter(let executable):
            process.executableURL = executable
            process.arguments = ["--protocol", "1"]
        case .cli(let executable):
            process.executableURL = executable
            // --oneshot is Hermes's documented script boundary. An explicit
            // empty toolset makes report analysis read-only while retaining
            // the user's configured model, identity, and memory.
            process.arguments = ["--oneshot", prompt, "--toolsets", ""]
        }
        process.currentDirectoryURL = SessionStore.root

        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_SESSION_SOURCE"] = "listen"
        environment["LISTEN_HERMES_ADAPTER_PROTOCOL"] = "1"
        process.environment = environment

        let input: Pipe? = {
            if case .adapter = runtime { return Pipe() }
            return nil
        }()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-hermes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout.txt")
        let errorURL = temporary.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        if let input { process.standardInput = input }
        process.standardOutput = output
        process.standardError = error

        var inputWriter: HermesStdinWriter?
        defer {
            if let inputWriter {
                inputWriter.wait()
            } else if let input {
                try? input.fileHandleForReading.close()
                try? input.fileHandleForWriting.close()
            }
        }

        try process.run()
        if let input {
            // Process.run() has duplicated the read descriptor into the child.
            // Closing the parent's copy ensures child termination produces
            // EPIPE and releases a writer stalled on a full pipe buffer.
            try? input.fileHandleForReading.close()
            let writer = HermesStdinWriter(
                handle: input.fileHandleForWriting,
                payload: Data(prompt.utf8)
            )
            inputWriter = writer
            writer.start()
        }

        let deadline = Date().addingTimeInterval(240)
        while process.isRunning {
            if Task.isCancelled {
                terminateAndWait(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                terminateAndWait(process)
                throw HermesAnalysisError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        inputWriter?.wait()
        try? output.synchronize(); try? error.synchronize()
        let response = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw HermesAnalysisError.failed(String(detail.suffix(600)))
        }
        guard !response.isEmpty else { throw HermesAnalysisError.emptyResponse }
        return response
    }

    private func terminateAndWait(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static func executable(named name: String) -> URL? {
        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardPaths = [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        ]
        for directory in environmentPaths + standardPaths {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
