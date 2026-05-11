import Foundation

/// Persistent config stored in ~/.listen/config.json. Schema mirrors the
/// existing Python app so users keep their keys.
struct AppSettings: Codable {
    var openai_api_key: String = ""
    var elevenlabs_api_key: String = ""
    var openrouter_api_key: String = ""
    var groq_api_key: String = ""

    var stt_provider: String = "elevenlabs"      // elevenlabs | openai | groq
    var interpreter_provider: String = "openrouter" // openrouter | openai | groq | none
    var hotkey: String = "ctrl_r"                 // see Hotkey.swift

    var cleanup_enabled: Bool = true
    var use_paste: Bool = true
    var sound_enabled: Bool = false

    var elevenlabs_model: String = "scribe_v1"
    var openai_whisper_model: String = "whisper-1"
    var openai_cleanup_model: String = "gpt-4o-mini"
    var openrouter_model: String = "google/gemini-flash-1.5"
    var groq_stt_model: String = "whisper-large-v3"
    var groq_model: String = "llama-3.1-8b-instant"

    var cleanup_prompt: String = """
        Clean up the following voice transcription. \
        Fix grammar, punctuation, and capitalization. \
        Preserve the original meaning and tone. \
        Do not add any introductory text or explanations. \
        Only return the cleaned text:\n\n{text}
        """
}

enum SettingsStore {
    static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        // Tolerate unknown / missing keys.
        let decoder = JSONDecoder()
        if let s = try? decoder.decode(AppSettings.self, from: data) { return s }
        // Merge over defaults manually for partial JSON.
        var s = AppSettings()
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let encoded = try? JSONSerialization.data(withJSONObject: dict)
            if let encoded, let parsed = try? decoder.decode(AppSettings.self, from: encoded) {
                s = parsed
            }
        }
        return s
    }

    static func save(_ settings: AppSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
