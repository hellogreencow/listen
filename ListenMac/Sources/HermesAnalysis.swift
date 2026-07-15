import Foundation

enum HermesAnalysisError: LocalizedError, Sendable {
    case unavailable
    case timedOut
    case failed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Hermes Agent is not installed in ~/.hermes."
        case .timedOut:
            return "Hermes analysis timed out."
        case .failed(let message):
            return "Hermes analysis failed: \(message)"
        case .emptyResponse:
            return "Hermes returned no analysis."
        }
    }
}

/// Optional bridge into the user's local Hermes installation. Listen passes
/// the request over stdin to Hermes's own Python runtime, so multi-hour report
/// prompts never hit the operating system's argv limit. The agent keeps its
/// configured identity and memory, but receives an explicitly empty toolset:
/// report analysis cannot run shell commands or mutate the Mac.
struct HermesInterpreter: Interpreter {
    private struct Runtime: Sendable {
        let python: URL
        let agentRoot: URL
    }

    static var isAvailable: Bool { runtime != nil }

    private static var runtime: Runtime? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".hermes/hermes-agent", isDirectory: true)
        let python = root.appendingPathComponent("venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("hermes_cli/oneshot.py").path)
        else { return nil }
        return Runtime(python: python, agentRoot: root)
    }

    func interpret(_ text: String, prompt: String) async throws -> String {
        guard let runtime = Self.runtime else { throw HermesAnalysisError.unavailable }
        let filled = prompt.replacingOccurrences(of: "{text}", with: text)
        return try await Task.detached(priority: .userInitiated) {
            try run(runtime: runtime, prompt: filled)
        }.value
    }

    private func run(runtime: Runtime, prompt: String) throws -> String {
        let wrapper = """
        import os, sys
        os.environ["HERMES_SESSION_SOURCE"] = "tool"
        from hermes_cli.oneshot import _run_agent
        response, result = _run_agent(sys.stdin.read(), toolsets=[], use_config_toolsets=False)
        if not (response or "").strip():
            detail = result.get("error") or result.get("final_response") or "no final response"
            print(str(detail), file=sys.stderr)
            raise SystemExit(2)
        sys.stdout.write(response)
        """
        let process = Process()
        process.executableURL = runtime.python
        process.arguments = ["-c", wrapper]
        process.currentDirectoryURL = SessionStore.root

        let input = Pipe()
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
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(240)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                throw HermesAnalysisError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
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
}
