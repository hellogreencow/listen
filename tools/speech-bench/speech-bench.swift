// speech-bench.swift — benchmark local Apple STT vs cloud
// Usage: speech-bench <audio-file> [audio-file ...]
import Foundation
import Speech
import AVFoundation

// ─── helpers ────────────────────────────────────────────────────────────────

func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

func printRow(_ engine: String, _ ms: Int, _ text: String) {
    let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    let engPad = engine.padding(toLength: 28, withPad: " ", startingAt: 0)
    let msStr = String(ms).padding(toLength: 6, withPad: " ", startingAt: 0)
    print("  \(engPad) \(msStr)ms  → \(t)")
}

// ─── SFSpeechRecognizer (on-device) ─────────────────────────────────────────

func runSF(url: URL) async -> (Int, String) {
    let start = Date()
    return await withCheckedContinuation { (cont: CheckedContinuation<(Int, String), Never>) in
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            cont.resume(returning: (-1, "SFSpeechRecognizer init failed"))
            return
        }
        guard rec.supportsOnDeviceRecognition else {
            cont.resume(returning: (-1, "on-device not supported"))
            return
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        rec.recognitionTask(with: req) { result, error in
            if let error {
                cont.resume(returning: (ms(start), "ERROR: \(error.localizedDescription)"))
                return
            }
            if let result, result.isFinal {
                cont.resume(returning: (ms(start), result.bestTranscription.formattedString))
            }
        }
    }
}

// ─── SpeechAnalyzer (macOS 26+, Apple Intelligence) ─────────────────────────

@available(macOS 26.0, *)
func runSpeechTranscriber(url: URL) async -> (Int, String) {
    let start = Date()
    do {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        if let installReq = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installReq.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var pieces: [String] = []
        for try await result in transcriber.results {
            pieces.append(String(result.text.characters))
        }
        return (ms(start), pieces.joined(separator: " "))
    } catch {
        return (ms(start), "ERROR: \(error.localizedDescription)")
    }
}

@available(macOS 26.0, *)
func runDictationTranscriber(url: URL) async -> (Int, String) {
    let start = Date()
    do {
        let locale = Locale(identifier: "en-US")
        let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)

        if let installReq = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installReq.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var pieces: [String] = []
        for try await result in transcriber.results {
            pieces.append(String(result.text.characters))
        }
        return (ms(start), pieces.joined(separator: " "))
    } catch {
        return (ms(start), "ERROR: \(error.localizedDescription)")
    }
}

// ─── ElevenLabs cloud (baseline) ────────────────────────────────────────────

func runElevenLabs(url: URL, apiKey: String, model: String) async -> (Int, String) {
    let start = Date()
    do {
        let audio = try Data(contentsOf: url)
        let boundary = "----bench\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/aiff\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (json?["text"] as? String) ?? "(no text)"
        return (ms(start), text.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        return (ms(start), "ERROR: \(error.localizedDescription)")
    }
}

// ─── main ───────────────────────────────────────────────────────────────────

let files = Array(CommandLine.arguments.dropFirst())
guard !files.isEmpty else {
    print("usage: speech-bench <audio-file> [audio-file ...]")
    exit(1)
}

// Request Speech permission once
let authSem = DispatchSemaphore(value: 0)
SFSpeechRecognizer.requestAuthorization { status in
    print("SFSpeechRecognizer auth status: \(status.rawValue)")
    authSem.signal()
}
authSem.wait()

// Read ElevenLabs key from config (optional)
let cfgPath = ("~/.listen/config.json" as NSString).expandingTildeInPath
var elevenKey: String? = nil
var elevenModel = "scribe_v1"
if let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    elevenKey = (json["elevenlabs_api_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    if let m = json["elevenlabs_model"] as? String { elevenModel = m }
}

Task {
    for f in files {
        let url = URL(fileURLWithPath: f)
        let dur: Double = {
            (try? AVAudioFile(forReading: url).length).map { Double($0) }
                .flatMap { len in
                    (try? AVAudioFile(forReading: url).processingFormat.sampleRate).map { sr in len / sr }
                } ?? 0
        }()
        print("\n=== \(url.lastPathComponent) (\(String(format: "%.2f", dur))s) ===")

        let (m1, t1) = await runSF(url: url)
        printRow("SFSpeechRecognizer/device", m1, t1)

        if #available(macOS 26.0, *) {
            let (m2, t2) = await runSpeechTranscriber(url: url)
            printRow("SpeechTranscriber/device", m2, t2)
            let (m4, t4) = await runDictationTranscriber(url: url)
            printRow("DictationTranscriber/device", m4, t4)
        } else {
            printRow("SpeechAnalyzer/device", 0, "macOS < 26")
        }

        if let key = elevenKey {
            let (m3, t3) = await runElevenLabs(url: url, apiKey: key, model: elevenModel)
            printRow("ElevenLabs/cloud", m3, t3)
        } else {
            printRow("ElevenLabs/cloud", 0, "no api key in config")
        }
    }
    exit(0)
}
RunLoop.main.run()
