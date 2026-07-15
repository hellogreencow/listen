import Foundation

/// A short-form capture consumer on the one shared microphone engine.
/// Audio is streamed to AAC off the real-time tap thread; when the engine was
/// already alive (wake/conversation), a small ring-buffer pre-roll prevents
/// the first phoneme from being clipped.
@MainActor
final class Recorder {
    private let engine: AudioEngine
    private let tokenPrefix: String
    private var activeToken: String?
    private var writer: M4AStreamWriter?
    private var sinkID: UUID?
    private(set) var lastURL: URL?
    private(set) var isRecording = false

    init(engine: AudioEngine = .shared, token: String = "short-capture") {
        self.engine = engine
        self.tokenPrefix = token
    }

    func start() throws {
        if isRecording { discard() }
        let initialState = engine.stateSnapshot()
        // Each capture owns a unique lease. A previous stop may still be
        // draining its AAC queue when a rapid re-press begins; reusing a Set
        // token would let that old stop release the new capture's microphone.
        let token = "\(tokenPrefix)-\(UUID().uuidString)"
        try engine.acquire(token)
        activeToken = token
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-\(UUID().uuidString).m4a")
        let stream = M4AStreamWriter(url: tmp)
        // Only seed pre-roll when another mode had already been listening.
        // A just-started engine's ring is intentionally empty.
        if initialState.isRunning {
            let preRoll = engine.recentSamples(seconds: 0.18)
            if !preRoll.isEmpty { stream.append(samples: preRoll, rate: initialState.nativeRate) }
        }
        let id = engine.addSink { [weak stream] samples, rate in
            stream?.append(samples: samples, rate: rate)
        }
        writer = stream
        sinkID = id
        lastURL = tmp
        isRecording = true
    }

    /// Stops recording and waits for AVAudioRecorder to finalize the file
    /// before returning its URL. stop() alone returns before the m4a container
    /// is fully written; reading it immediately can upload a truncated file
    /// (occasional empty/failed transcriptions). audioRecorderDidFinishRecording
    /// marks finalization complete; a 1 s safety net avoids hanging if the
    /// delegate never fires (encoder error).
    func stop() async -> URL? {
        guard isRecording else { return lastURL }
        isRecording = false
        if let sinkID { engine.removeSink(sinkID) }
        self.sinkID = nil
        let stream = writer
        writer = nil
        let url = lastURL
        if let activeToken { engine.release(activeToken) }
        self.activeToken = nil
        // close() drains the writer's serial queue and finalizes the m4a.
        await Task.detached(priority: .userInitiated) { stream?.close() }.value
        return url
    }

    /// Stop and throw away the current recording without waiting for
    /// finalization — for accidental sub-minimum taps. Synchronous with
    /// respect to `recorder`, so an immediate re-press can't race it.
    func discard() {
        guard isRecording else { return }
        isRecording = false
        if let sinkID { engine.removeSink(sinkID) }
        self.sinkID = nil
        let stream = writer
        writer = nil
        let url = lastURL
        if let activeToken { engine.release(activeToken) }
        self.activeToken = nil
        Task.detached(priority: .utility) {
            stream?.close()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }
}
