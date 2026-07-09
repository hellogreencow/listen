import Foundation

/// Persistent config stored in ~/.listen/config.json. Schema mirrors the
/// existing Python app so users keep their keys.
struct AppSettings: Codable {
    var openai_api_key: String = ""
    var elevenlabs_api_key: String = ""
    var openrouter_api_key: String = ""
    var groq_api_key: String = ""

    var stt_provider: String = "apple"           // apple | elevenlabs | openai | groq
    var interpreter_provider: String = "openrouter" // openrouter | openai | groq | none
    var hotkey: String = "alt_r"                  // see Hotkey.swift; user's keyboard has no Right Control

    var cleanup_enabled: Bool = false
    var use_paste: Bool = true                    // legacy Python-app field; Swift app always pastes
    var sound_enabled: Bool = false

    var elevenlabs_model: String = "scribe_v1"
    var openai_whisper_model: String = "whisper-1"
    var openai_cleanup_model: String = "gpt-4o-mini"
    var openrouter_model: String = "openai/gpt-4o-mini"
    var groq_stt_model: String = "whisper-large-v3"
    var groq_model: String = "llama-3.1-8b-instant"

    var cleanup_prompt: String = """
        Clean up the following voice transcription. \
        Fix grammar, punctuation, and capitalization. \
        Preserve the original meaning and tone. \
        Do not add any introductory text or explanations. \
        Only return the cleaned text:\n\n{text}
        """

    init() {}

    enum CodingKeys: String, CodingKey {
        case openai_api_key, elevenlabs_api_key, openrouter_api_key, groq_api_key
        case stt_provider, interpreter_provider, hotkey
        case cleanup_enabled, use_paste, sound_enabled
        case elevenlabs_model, openai_whisper_model, openai_cleanup_model
        case openrouter_model, groq_stt_model, groq_model
        case cleanup_prompt
    }

    /// Per-field decoding with fallbacks. Synthesized Codable fails the whole
    /// decode on a single missing key, which silently reset the entire config
    /// (API keys, hotkey, provider) the first time a new field shipped. Here a
    /// missing or type-mismatched key keeps its default; everything else loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        openai_api_key       = c.value(.openai_api_key, d.openai_api_key)
        elevenlabs_api_key   = c.value(.elevenlabs_api_key, d.elevenlabs_api_key)
        openrouter_api_key   = c.value(.openrouter_api_key, d.openrouter_api_key)
        groq_api_key         = c.value(.groq_api_key, d.groq_api_key)
        stt_provider         = c.value(.stt_provider, d.stt_provider)
        interpreter_provider = c.value(.interpreter_provider, d.interpreter_provider)
        hotkey               = c.value(.hotkey, d.hotkey)
        cleanup_enabled      = c.value(.cleanup_enabled, d.cleanup_enabled)
        use_paste            = c.value(.use_paste, d.use_paste)
        sound_enabled        = c.value(.sound_enabled, d.sound_enabled)
        elevenlabs_model     = c.value(.elevenlabs_model, d.elevenlabs_model)
        openai_whisper_model = c.value(.openai_whisper_model, d.openai_whisper_model)
        openai_cleanup_model = c.value(.openai_cleanup_model, d.openai_cleanup_model)
        openrouter_model     = c.value(.openrouter_model, d.openrouter_model)
        groq_stt_model       = c.value(.groq_stt_model, d.groq_stt_model)
        groq_model           = c.value(.groq_model, d.groq_model)
        cleanup_prompt       = c.value(.cleanup_prompt, d.cleanup_prompt)
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        if let v = try? decodeIfPresent(T.self, forKey: key) { return v }
        return fallback
    }
}

enum SettingsStore {
    static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
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
