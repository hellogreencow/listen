import AVFoundation
import CoreAudio
import Foundation

/// Fixed-capacity circular storage for the microphone pre-roll. Appending is
/// O(new samples) even after the buffer is full; no tap callback ever shifts
/// the previous 30 seconds of audio in memory.
struct CircularSampleBuffer: Sendable {
    private var storage: [Float]
    private var start = 0
    private(set) var count = 0

    init(capacity: Int = 0) {
        storage = Array(repeating: 0, count: max(0, capacity))
    }

    var capacity: Int { storage.count }

    mutating func reset(capacity: Int) {
        storage = Array(repeating: 0, count: max(0, capacity))
        start = 0
        count = 0
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        if !keepingCapacity { storage.removeAll(keepingCapacity: false) }
        start = 0
        count = 0
    }

    mutating func append(_ samples: [Float]) {
        let bufferCapacity = storage.count
        guard !samples.isEmpty, bufferCapacity > 0 else { return }
        let incomingCount = samples.count
        if incomingCount >= bufferCapacity {
            samples.withUnsafeBufferPointer { source in
                storage.withUnsafeMutableBufferPointer { destination in
                    guard let sourceBase = source.baseAddress,
                          let destinationBase = destination.baseAddress else { return }
                    destinationBase.update(
                        from: sourceBase + (incomingCount - bufferCapacity), count: bufferCapacity
                    )
                }
            }
            start = 0
            count = bufferCapacity
            return
        }

        // Compute the old logical end before advancing start for overwritten
        // samples; that is exactly where the new samples belong.
        let writeIndex = (start + count) % bufferCapacity
        let overwritten = max(0, count + incomingCount - bufferCapacity)
        if overwritten > 0 {
            start = (start + overwritten) % bufferCapacity
            count -= overwritten
        }

        samples.withUnsafeBufferPointer { source in
            storage.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                let firstCount = min(incomingCount, bufferCapacity - writeIndex)
                (destinationBase + writeIndex).update(from: sourceBase, count: firstCount)
                let secondCount = incomingCount - firstCount
                if secondCount > 0 {
                    destinationBase.update(from: sourceBase + firstCount, count: secondCount)
                }
            }
        }
        count += incomingCount
    }

    func suffix(_ requestedCount: Int) -> [Float] {
        let resultCount = min(max(0, requestedCount), count)
        guard resultCount > 0, capacity > 0 else { return [] }
        let firstIndex = (start + count - resultCount) % capacity
        let firstCount = min(resultCount, capacity - firstIndex)
        var result: [Float] = []
        result.reserveCapacity(resultCount)
        result.append(contentsOf: storage[firstIndex..<(firstIndex + firstCount)])
        let secondCount = resultCount - firstCount
        if secondCount > 0 { result.append(contentsOf: storage[0..<secondCount]) }
        return result
    }

    func rms(last requestedCount: Int) -> Float {
        let sampleCount = min(max(0, requestedCount), count)
        guard sampleCount > 0, capacity > 0 else { return 0 }
        let firstIndex = (start + count - sampleCount) % capacity
        var sum: Float = 0
        for offset in 0..<sampleCount {
            let value = storage[(firstIndex + offset) % capacity]
            sum += value * value
        }
        return sqrt(sum / Float(sampleCount))
    }
}

struct AudioEngineState: Sendable {
    let isRunning: Bool
    let nativeRate: Double
}

/// The single owner of the microphone. Every mode (dictation, quick thought,
/// wake word, conversation recording) is a consumer of the same input tap.
///
/// Lifecycle is refcounted: `acquire(_:)` starts the engine when the first
/// consumer arrives, `release(_:)` stops it (after a short grace period) when
/// the last one leaves. When wake word and conversation mode are off and no
/// dictation is in flight, the mic is closed — no orange dot.
///
/// Core patterns are lifted from voice-daemon.swift, which ran this engine
/// 24/7 for months: pin the built-in mic so virtual drivers (Teams, etc.)
/// can't hijack input; on route change debounce, then rebuild with a FRESH
/// AVAudioEngine instance (reusing one after a route change throws -10868);
/// touch mainMixerNode before start on macOS 26 so the graph initializes.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    // ── Consumers / lifecycle ────────────────────────────────────
    private var consumers = Set<String>()
    private var stopWork: DispatchWorkItem?
    private let stateLock = NSLock()

    // ── Engine ───────────────────────────────────────────────────
    private var engine = AVAudioEngine()
    private var engineRunning = false
    private var nativeRate: Double = 48_000
    private var isRestarting = false

    // ── Ring buffer (mono float32 @ nativeRate) ──────────────────
    private var ring = CircularSampleBuffer()
    private let ringLock = NSLock()
    /// Monotonic count of all samples ever appended; lets consumers mark a
    /// position and later slice exactly the audio spoken since the mark.
    private var totalSamples: UInt64 = 0
    private static let ringSeconds: Double = 30

    // ── Sinks: mono tap audio fan-out (file writers, etc.) ──────
    private var sinks: [UUID: (_ samples: [Float], _ rate: Double) -> Void] = [:]
    private let sinkLock = NSLock()

    /// Raw-buffer consumer for streaming speech recognition (wake word).
    /// Called on the tap thread with the engine's own buffer format.
    var speechConsumer: ((AVAudioPCMBuffer) -> Void)?
    /// When true, tap audio is not forwarded to speechConsumer (used to keep
    /// TTS output out of the recognizer when AEC is unavailable). The ring
    /// still accumulates so barge-in detection keeps working.
    var muteSpeechConsumer: (() -> Bool)?
    /// Fired (on an arbitrary queue) after the engine restarts due to a route
    /// change so long-lived consumers can re-arm.
    var onEngineRestart: (() -> Void)?

    // ── Tap health ───────────────────────────────────────────────
    private var lastTapAppendAt = Date.distantPast
    private var engineStartTime: Date?
    private let tapHealthLock = NSLock()

    // ── Route recovery ───────────────────────────────────────────
    private var routeObserver: NSObjectProtocol?
    private var routeChangeWork: DispatchWorkItem?
    private var routeRecoveryWork: DispatchWorkItem?
    private var routeRecoveryAttempts = 0
    private var aecRetryCount = 0
    private static let maxAecRetries = 3
    private var cachedBuiltInMicId: AudioDeviceID = 0

    private init() {}

    // MARK: - Lifecycle

    /// Start (or keep) the engine on behalf of `token`. Throws if the engine
    /// cannot start (mic permission, transient CoreAudio state).
    func acquire(_ token: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        consumers.insert(token)
        stopWork?.cancel()
        stopWork = nil
        if !engineRunning {
            do {
                try startEngine()
            } catch {
                // A failed first consumer must not leave a phantom reference
                // that keeps later calls from retrying the engine start.
                consumers.remove(token)
                throw error
            }
        }
    }

    /// Release `token`. When no consumers remain the engine stops after a
    /// 2 s grace so press-release-press dictation doesn't churn the mic.
    func release(_ token: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        consumers.remove(token)
        guard consumers.isEmpty, engineRunning else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            if self.consumers.isEmpty { self.stopEngineLocked() }
        }
        stopWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    var hasConsumers: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !consumers.isEmpty
    }

    func stateSnapshot() -> AudioEngineState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return AudioEngineState(isRunning: engineRunning, nativeRate: nativeRate)
    }

    func isTapHealthy(within seconds: TimeInterval = 3.0) -> Bool {
        tapHealthLock.lock()
        let lastAppend = lastTapAppendAt
        let startTime = engineStartTime
        tapHealthLock.unlock()
        let engineAge = Date().timeIntervalSince(startTime ?? .distantPast)
        return Date().timeIntervalSince(lastAppend) < seconds || engineAge < 5.0
    }

    // MARK: - Sinks

    func addSink(_ handler: @escaping (_ samples: [Float], _ rate: Double) -> Void) -> UUID {
        let id = UUID()
        sinkLock.lock()
        sinks[id] = handler
        sinkLock.unlock()
        return id
    }

    func removeSink(_ id: UUID) {
        sinkLock.lock()
        sinks.removeValue(forKey: id)
        sinkLock.unlock()
    }

    // MARK: - Ring buffer access

    /// Current absolute sample position — pass to `samples(from:)` later.
    func markPosition() -> UInt64 {
        ringLock.lock()
        defer { ringLock.unlock() }
        return totalSamples
    }

    /// All audio appended since `marker` (bounded by ring capacity).
    func samples(from marker: UInt64) -> [Float] {
        ringLock.lock()
        defer { ringLock.unlock() }
        guard totalSamples > marker else { return [] }
        let wanted = Int(min(totalSamples - marker, UInt64(ring.count)))
        return ring.suffix(wanted)
    }

    /// The most recent `seconds` of audio.
    func recentSamples(seconds: Double) -> [Float] {
        let rate = stateSnapshot().nativeRate
        ringLock.lock()
        defer { ringLock.unlock() }
        let n = min(ring.count, Int(rate * seconds))
        guard n > 0 else { return [] }
        return ring.suffix(n)
    }

    /// RMS energy of the most recent `ms` milliseconds.
    func recentRMS(ms: Double) -> Float {
        let n = max(1, Int(stateSnapshot().nativeRate * ms / 1000))
        ringLock.lock()
        guard ring.count >= n else { ringLock.unlock(); return 0 }
        let value = ring.rms(last: n)
        ringLock.unlock()
        return value
    }

    // MARK: - Engine internals (stateLock held)

    private func startEngine() throws {
        selectBuiltInMic()
        let inputNode = engine.inputNode
        guard let fmt = resolveInputTapFormat(for: inputNode) else {
            throw NSError(domain: "Listen", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "Input audio format is temporarily invalid (route change?)"])
        }
        nativeRate = fmt.sampleRate
        ringLock.lock()
        ring.reset(capacity: max(1, Int(nativeRate * Self.ringSeconds)))
        ringLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            self?.consumeTap(buf)
        }

        // macOS 26: touching mainMixerNode connects it to outputNode, which
        // AVAudioEngineGraph::Initialize() requires. Must SET a property so
        // -O doesn't discard the access. Muted — no passthrough.
        engine.mainMixerNode.outputVolume = 0

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // A retained tap makes the next acquire fail when it attempts to
            // install another tap on bus zero. Restore a retryable engine.
            engine.stop()
            inputNode.removeTap(onBus: 0)
            throw error
        }
        engineRunning = true
        tapHealthLock.lock()
        engineStartTime = Date()
        lastTapAppendAt = Date()
        tapHealthLock.unlock()

        // OS-level AEC+AGC keeps TTS speaker output out of the mic signal.
        // Needs a running engine; -10849 means format-incompatible — back off.
        if #available(macOS 14.0, *), aecRetryCount < Self.maxAecRetries {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                aecRetryCount = 0
            } catch {
                aecRetryCount += 1
                NSLog("[Listen] AEC unavailable (\(aecRetryCount)/\(Self.maxAecRetries)): \(error.localizedDescription)")
            }
        }

        registerRouteChangeObserver()
        listenLog("audio engine running rate=\(Int(nativeRate)) consumers=\(consumers.count)")
        NSLog("[Listen] audio engine running (\(Int(nativeRate)) Hz)")
    }

    private func stopEngineLocked() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        routeChangeWork?.cancel()
        routeRecoveryWork?.cancel()
        if #available(macOS 14.0, *) {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engineRunning = false
        ringLock.lock()
        ring.removeAll(keepingCapacity: true)
        ringLock.unlock()
        listenLog("audio engine stopped; mic closed")
        NSLog("[Listen] audio engine stopped — mic closed")
    }

    private func consumeTap(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        let chans = Int(buf.format.channelCount)
        guard frames > 0, chans > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        for ch in 0..<chans {
            let p = data[ch]
            for i in 0..<frames { mono[i] += p[i] }
        }
        if chans > 1 {
            let d = Float(chans)
            for i in 0..<frames { mono[i] /= d }
        }

        // The tap's own immutable format is the authoritative rate for this
        // buffer and avoids taking stateLock on the real-time audio thread.
        let rate = buf.format.sampleRate
        ringLock.lock()
        totalSamples &+= UInt64(frames)
        ring.append(mono)
        ringLock.unlock()

        tapHealthLock.lock()
        lastTapAppendAt = Date()
        tapHealthLock.unlock()

        sinkLock.lock()
        let currentSinks = Array(sinks.values)
        sinkLock.unlock()
        for sink in currentSinks { sink(mono, rate) }

        if !(muteSpeechConsumer?() ?? false) {
            speechConsumer?(buf)
        }
    }

    // MARK: - Built-in mic pinning

    /// Force the built-in mic as default input so virtual drivers (MS Teams
    /// audio, loopback tools) can't hijack capture. Device id cached.
    private func selectBuiltInMic() {
        if cachedBuiltInMicId != 0 {
            if setDefaultInput(cachedBuiltInMicId) { return }
            cachedBuiltInMicId = 0 // stale — re-enumerate
        }
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size, &devices) == noErr else { return }

        for dev in devices {
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &inputAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(dev, &transportAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            cachedBuiltInMicId = dev
            _ = setDefaultInput(dev)
            return
        }
    }

    private func setDefaultInput(_ dev: AudioDeviceID) -> Bool {
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var devId = dev
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &devId) == noErr
    }

    private func resolveInputTapFormat(for inputNode: AVAudioInputNode) -> AVAudioFormat? {
        for candidate in [inputNode.inputFormat(forBus: 0), inputNode.outputFormat(forBus: 0)] {
            if candidate.sampleRate.isFinite, candidate.sampleRate > 0, candidate.channelCount > 0 {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Route recovery

    /// On route change: debounce, and only rebuild if the engine actually
    /// died. Eager rebuilds hit invalid transient CoreAudio formats.
    private func registerRouteChangeObserver() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.routeChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.selectBuiltInMic()
                self.stateLock.lock()
                let healthy = self.engineRunning && self.engine.isRunning
                let restarting = self.isRestarting
                if !healthy && !restarting { self.isRestarting = true }
                self.stateLock.unlock()
                if healthy || restarting { return }
                NSLog("[Listen] audio route changed, engine inactive — scheduling recovery")
                self.scheduleRouteRecovery(after: 2.5)
            }
            self.routeChangeWork = work
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func scheduleRouteRecovery(after delay: TimeInterval) {
        routeRecoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            if self.engineRunning && self.engine.isRunning {
                self.routeRecoveryAttempts = 0
                self.isRestarting = false
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()
            self.recoverRoute()
        }
        routeRecoveryWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recoverRoute() {
        stateLock.lock()
        routeRecoveryAttempts += 1
        let attempt = routeRecoveryAttempts
        guard !consumers.isEmpty else {
            // Nobody needs the mic anymore — don't fight CoreAudio for it.
            stopEngineLocked()
            isRestarting = false
            routeRecoveryAttempts = 0
            stateLock.unlock()
            return
        }
        do {
            selectBuiltInMic()
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engineRunning = false
            ringLock.lock()
            ring.removeAll(keepingCapacity: true)
            ringLock.unlock()
            engine = AVAudioEngine() // fresh instance: reuse after route change → -10868
            try startEngine()
            routeRecoveryAttempts = 0
            isRestarting = false
            stateLock.unlock()
            NSLog("[Listen] audio engine recovered after route change")
            listenLog("audio engine recovered after route change")
            onEngineRestart?()
        } catch {
            isRestarting = true
            stateLock.unlock()
            let retryDelay = min(6.0, 1.2 + Double(attempt) * 0.9)
            NSLog("[Listen] route recovery failed (attempt \(attempt)): \(error.localizedDescription)")
            scheduleRouteRecovery(after: retryDelay)
        }
    }
}

// MARK: - Encoding helpers

enum AudioEncode {
    /// Write mono float32 samples to an AAC .m4a file. Used for ring-buffer
    /// slices (dictation, conversation turns).
    static func writeM4A(samples: [Float], rate: Double, to url: URL) throws {
        guard !samples.isEmpty else {
            throw NSError(domain: "Listen", code: 1002,
                          userInfo: [NSLocalizedDescriptionKey: "no audio samples to encode"])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: 1, interleaved: false) else {
            throw NSError(domain: "Listen", code: 1003,
                          userInfo: [NSLocalizedDescriptionKey: "bad PCM format"])
        }
        // Write in ~1 s chunks; a single huge AVAudioPCMBuffer allocation for
        // minutes of audio is wasteful.
        let chunk = Int(rate)
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            try file.write(from: buf)
            offset += n
        }
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

/// Streaming AAC writer fed from the engine tap — used by the conversation
/// recorder for unbounded recordings (audio goes straight to disk, not RAM).
final class M4AStreamWriter: @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "com.listen.m4a-writer", qos: .utility)
    private var queuedFrames: UInt64 = 0

    init(url: URL) {
        self.url = url
    }

    /// Append mono samples; the file is created lazily from the first
    /// buffer's sample rate.
    func append(samples: [Float], rate: Double) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 48_000,
                ]
                file = try? AVAudioFile(forWriting: url, settings: settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
                fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                           channels: 1, interleaved: false)
                if file == nil { NSLog("[Listen] M4AStreamWriter: failed to open \(url.lastPathComponent)") }
            }
            guard let file, let fileFormat,
                  let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate,
                    channels: 1, interleaved: false
                  ),
                  let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)
                  ) else { return }
            inputBuffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                inputBuffer.floatChannelData![0].update(from: base, count: samples.count)
            }

            let bufferToWrite: AVAudioPCMBuffer
            if abs(fileFormat.sampleRate - rate) < 0.5 {
                bufferToWrite = inputBuffer
            } else {
                // A route change can alter the tap rate mid-capture. Build the
                // incoming buffer with its true metadata, then resample into
                // the file's fixed processing format instead of replaying it
                // at the wrong speed/pitch.
                guard let converter = AVAudioConverter(from: inputFormat, to: fileFormat) else {
                    NSLog("[Listen] M4AStreamWriter: cannot convert \(Int(rate)) to \(Int(fileFormat.sampleRate)) Hz")
                    return
                }
                let ratio = fileFormat.sampleRate / rate
                let capacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio) + 32)
                guard let converted = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
                let converterInput = ConverterInputBox(inputBuffer)
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                    converterInput.next(inputStatus)
                }
                guard status != .error, conversionError == nil else {
                    NSLog("[Listen] M4AStreamWriter conversion failed: \(conversionError?.localizedDescription ?? "unknown error")")
                    return
                }
                bufferToWrite = converted
            }
            do {
                try file.write(from: bufferToWrite)
                queuedFrames &+= UInt64(bufferToWrite.frameLength)
            } catch {
                NSLog("[Listen] M4AStreamWriter write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Close the file. AVAudioFile finalizes on deinit; dropping our
    /// reference inside the lock guarantees ordering with pending appends.
    func close() {
        queue.sync {
            file = nil
            fileFormat = nil
        }
    }

    var frames: UInt64 { queue.sync { queuedFrames } }
}
