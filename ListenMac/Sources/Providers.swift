import Foundation
import Speech
import AVFoundation

enum ProviderError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case decode(String)
    case timeout(Double)

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "Missing API key for \(p)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decode(let m): return "Decode failed: \(m)"
        case .timeout(let s): return "timed out after \(Int(s))s"
        }
    }
}

/// Runs `op` with a hard deadline. On expiry the operation's task is
/// cancelled (URLSession and Speech async APIs all honor cancellation) and
/// ProviderError.timeout is thrown. Without this, a hung provider left the
/// app in "thinking" forever with the hotkey dead.
func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ProviderError.timeout(seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

protocol STTProvider {
    func transcribe(_ url: URL) async throws -> String
}

protocol Interpreter {
    func interpret(_ text: String, prompt: String) async throws -> String
}

// MARK: - Multipart helper

private func multipart(boundary: String, fields: [String: String], file: (name: String, filename: String, mime: String, data: Data)) -> Data {
    var body = Data()
    for (k, v) in fields {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(v)\r\n".data(using: .utf8)!)
    }
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(file.mime)\r\n\r\n".data(using: .utf8)!)
    body.append(file.data)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    return body
}

// MARK: - ElevenLabs

struct ElevenLabsSTT: STTProvider {
    let apiKey: String
    let model: String

    func transcribe(_ url: URL) async throws -> String {
        let audio = try Data(contentsOf: url)
        let boundary = "----Listen\(UUID().uuidString)"
        let body = multipart(
            boundary: boundary,
            fields: ["model_id": model],
            file: ("file", url.lastPathComponent, "audio/m4a", audio)
        )
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw ProviderError.decode("no text field")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - OpenAI (Whisper)

struct OpenAISTT: STTProvider {
    let apiKey: String
    let model: String

    func transcribe(_ url: URL) async throws -> String {
        let audio = try Data(contentsOf: url)
        let boundary = "----Listen\(UUID().uuidString)"
        let body = multipart(
            boundary: boundary,
            fields: ["model": model, "response_format": "text"],
            file: ("file", url.lastPathComponent, "audio/m4a", audio)
        )
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Groq STT

struct GroqSTT: STTProvider {
    let apiKey: String
    let model: String

    func transcribe(_ url: URL) async throws -> String {
        let audio = try Data(contentsOf: url)
        let boundary = "----Listen\(UUID().uuidString)"
        let body = multipart(
            boundary: boundary,
            fields: ["model": model, "response_format": "text"],
            file: ("file", url.lastPathComponent, "audio/m4a", audio)
        )
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - OpenAI-compatible chat (used by OpenRouter / OpenAI / Groq)

struct ChatInterpreter: Interpreter {
    let endpoint: URL
    let apiKey: String
    let model: String
    let extraHeaders: [String: String]

    func interpret(_ text: String, prompt: String) async throws -> String {
        let filled = prompt.replacingOccurrences(of: "{text}", with: text)
        // Cleanup output is ≈ input length. chars/2 is ~2× the input's token
        // count — generous headroom without an arbitrary fixed cap that would
        // truncate long dictations.
        let maxTokens = min(16_384, max(1_024, filled.count / 2))
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a helpful text editor."],
                ["role": "user", "content": filled],
            ],
            "temperature": 0.1,
            "max_tokens": maxTokens,
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw ProviderError.decode("unexpected chat response")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Apple on-device (SpeechAnalyzer + SpeechTranscriber)

/// Local STT using Apple's SpeechAnalyzer (macOS 26+). No network, no API key,
/// no rate limits. Output already has proper punctuation/capitalization, so
/// the LLM cleanup pass is unnecessary downstream. Empirically ~900 ms for a
/// 3-second clip on Apple Silicon (see tools/speech-bench/).
@available(macOS 26.0, *)
struct AppleSTT: STTProvider {
    private static let locale = Locale(identifier: "en-US")

    /// One-time authorization + model-asset check, shared across utterances.
    /// The old code blocked a thread on a semaphore for authorization and ran
    /// the asset-installation check on every transcription — a mid-dictation
    /// network stall with no escape. A failed setup is retried on the next
    /// call rather than cached forever.
    @MainActor private static var setupTask: Task<Void, Error>?

    @MainActor
    private static func ensureReady() async throws {
        if let t = setupTask {
            if (try? await t.value) != nil { return }
        }
        let t = Task {
            let status = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            guard status == .authorized else {
                throw ProviderError.http(403, "Speech Recognition permission not granted")
            }
            let probe = SpeechTranscriber(locale: locale, preset: .transcription)
            if let installReq = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await installReq.downloadAndInstall()
            }
        }
        setupTask = t
        try await t.value
    }

    func transcribe(_ url: URL) async throws -> String {
        try await Self.ensureReady()
        let transcriber = SpeechTranscriber(locale: Self.locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var pieces: [String] = []
        for try await result in transcriber.results {
            pieces.append(String(result.text.characters))
        }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Factory

enum ProviderFactory {
    static func stt(_ s: AppSettings) throws -> STTProvider {
        switch s.stt_provider {
        case "apple":
            if #available(macOS 26.0, *) { return AppleSTT() }
            throw ProviderError.http(0, "Apple on-device STT requires macOS 26+")
        case "openai":
            guard !s.openai_api_key.isEmpty else { throw ProviderError.missingKey("openai") }
            return OpenAISTT(apiKey: s.openai_api_key, model: s.openai_whisper_model)
        case "groq":
            guard !s.groq_api_key.isEmpty else { throw ProviderError.missingKey("groq") }
            return GroqSTT(apiKey: s.groq_api_key, model: s.groq_stt_model)
        case "elevenlabs":
            fallthrough
        default:
            guard !s.elevenlabs_api_key.isEmpty else { throw ProviderError.missingKey("elevenlabs") }
            return ElevenLabsSTT(apiKey: s.elevenlabs_api_key, model: s.elevenlabs_model)
        }
    }

    static func interpreter(_ s: AppSettings) throws -> Interpreter? {
        guard s.cleanup_enabled else { return nil }
        switch s.interpreter_provider {
        case "openai":
            guard !s.openai_api_key.isEmpty else { throw ProviderError.missingKey("openai") }
            return ChatInterpreter(
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: s.openai_api_key,
                model: s.openai_cleanup_model,
                extraHeaders: [:]
            )
        case "groq":
            guard !s.groq_api_key.isEmpty else { throw ProviderError.missingKey("groq") }
            return ChatInterpreter(
                endpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                apiKey: s.groq_api_key,
                model: s.groq_model,
                extraHeaders: [:]
            )
        case "none":
            return nil
        case "openrouter":
            fallthrough
        default:
            guard !s.openrouter_api_key.isEmpty else { throw ProviderError.missingKey("openrouter") }
            return ChatInterpreter(
                endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                apiKey: s.openrouter_api_key,
                model: s.openrouter_model,
                extraHeaders: ["X-Title": "Listen"]
            )
        }
    }
}
