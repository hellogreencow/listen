import Foundation

enum XAITTSRequestBuilder {
    static let endpoint = URL(string: "https://api.x.ai/v1/tts")!

    /// Matches the retired daemon's proven xAI TTS wire format exactly.
    static func make(text: String, voiceID: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice_id": voiceID,
            "language": "en",
            "output_format": [
                "codec": "mp3",
                "sample_rate": 24_000,
                "bit_rate": 128_000,
            ],
        ])
        return request
    }
}
