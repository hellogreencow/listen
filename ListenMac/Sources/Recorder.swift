import AVFoundation
import Foundation

/// Records mic to AAC/M4A (small, accepted by ElevenLabs/OpenAI/Groq).
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var lastURL: URL?

    func start() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: tmp, settings: settings)
        r.delegate = self
        guard r.record() else {
            throw NSError(domain: "Listen", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AVAudioRecorder.record() returned false (Microphone permission?)"
            ])
        }
        self.recorder = r
        self.lastURL = tmp
    }

    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        return lastURL
    }

    var isRecording: Bool { recorder?.isRecording ?? false }
}
