import AVFoundation
import Foundation

/// Records mic to AAC/M4A (small, accepted by ElevenLabs/OpenAI/Groq).
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var lastURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func start() throws {
        finish() // resolve any straggler continuation from a prior recording
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

    /// Stops recording and waits for AVAudioRecorder to finalize the file
    /// before returning its URL. stop() alone returns before the m4a container
    /// is fully written; reading it immediately can upload a truncated file
    /// (occasional empty/failed transcriptions). audioRecorderDidFinishRecording
    /// marks finalization complete; a 1 s safety net avoids hanging if the
    /// delegate never fires (encoder error).
    func stop() async -> URL? {
        finish() // never let a straggler continuation alias the new one
        guard let r = recorder else { return lastURL }
        recorder = nil
        // Capture THIS recording's file before suspending: a rapid
        // cancel-and-redictate can call start() during the await, and
        // returning `lastURL` afterwards would hand back (and later delete)
        // the NEW recording's file.
        let url = r.url
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishContinuation = cont
            r.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.finish()
            }
        }
        return url
    }

    /// Stop and throw away the current recording without waiting for
    /// finalization — for accidental sub-minimum taps. Synchronous with
    /// respect to `recorder`, so an immediate re-press can't race it.
    func discard() {
        guard let r = recorder else { return }
        recorder = nil
        r.stop()
        let url = r.url
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    var isRecording: Bool { recorder?.isRecording ?? false }
}
