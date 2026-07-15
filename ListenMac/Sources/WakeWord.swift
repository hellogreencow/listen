import AVFoundation
import Foundation
@preconcurrency import Speech

enum WakePhraseMatcher {
    static func suffix(in text: String, phrase: String) -> String? {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPhrase.isEmpty else { return nil }
        let pattern = "(?i)(?:\\bhey\\s+)?\\b\(NSRegularExpression.escapedPattern(for: cleanPhrase))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

/// Opt-in streaming wake-word and conversational turn detector. It consumes
/// buffers from AudioEngine's one tap; it never creates another audio engine.
final class WakeWordController: @unchecked Sendable {
    enum Phase { case stopped, wake, capture, conversation, processing }

    var onCommand: ((_ text: String, _ bargeIn: Bool) -> Void)?
    var onSpeechBegan: ((_ bargeIn: Bool) -> Void)?
    var onStatus: ((_ message: String) -> Void)?
    var onError: ((_ message: String) -> Void)?
    var echoGate: SpeechEchoGate?

    private let audio: AudioEngine
    private let queue = DispatchQueue(label: "com.listen.wake-word", qos: .userInitiated)
    private let requestLock = NSLock()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var phase: Phase = .stopped
    private var phrase = "listen"
    private var timeout: TimeInterval = 30
    private var lifecycleGeneration = 0
    private var generation = 0
    private var latestCandidate = ""
    private var heardSpeech = false
    private var endpointWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var resetWork: DispatchWorkItem?

    init(audio: AudioEngine = .shared) { self.audio = audio }

    func start(phrase: String, conversationTimeout: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lifecycleGeneration &+= 1
            let lifecycle = self.lifecycleGeneration
            self.phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if self.phrase.isEmpty { self.phrase = "listen" }
            self.timeout = max(8, conversationTimeout)
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                self.startAuthorized()
            case .notDetermined:
                // This is intentionally the only call site that can create a
                // Speech Recognition prompt, reached only from opt-in enable.
                SFSpeechRecognizer.requestAuthorization { [weak self] status in
                    guard let target = self else { return }
                    target.queue.async { [target] in
                        guard target.lifecycleGeneration == lifecycle else { return }
                        if status == .authorized { target.startAuthorized() }
                        else { target.fail("Speech Recognition permission was not granted; wake word remains off.") }
                    }
                }
            default:
                self.fail("Speech Recognition permission is denied; wake word remains off.")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked(releaseMic: true) }
    }

    func update(phrase: String, conversationTimeout: TimeInterval) {
        queue.async { [weak self] in
            guard let self, self.phase != .stopped else { return }
            let next = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.phrase = next.isEmpty ? "listen" : next
            self.timeout = max(8, conversationTimeout)
            self.phase = .wake
            self.beginRecognition()
        }
    }

    /// Called after the assistant has accepted a command. Recognition resumes
    /// before TTS starts, which is what makes spoken barge-in interruptible.
    func continueConversation() {
        queue.async { [weak self] in
            guard let self, self.phase != .stopped else { return }
            self.phase = .conversation
            self.beginRecognition()
            self.scheduleConversationIdle()
            self.emitStatus("conversation")
        }
    }

    /// Starts a fresh streaming task after TTS finishes so any cumulative
    /// transcription containing the just-spoken response cannot survive into
    /// the next user turn. The echo gate remains active through its short
    /// acoustic settle window.
    func resetConversationRecognitionAfterSpeech() {
        queue.async { [weak self] in
            guard let self, self.phase == .conversation else { return }
            self.beginRecognition()
            self.scheduleConversationIdle()
        }
    }

    func returnToWake() {
        queue.async { [weak self] in self?.returnToWakeLocked() }
    }

    private func startAuthorized() {
        guard recognizer?.isAvailable == true else {
            fail("Apple Speech Recognition is temporarily unavailable.")
            return
        }
        do {
            try audio.acquire("wake-word")
        } catch {
            fail("Wake word microphone error: \(error.localizedDescription)")
            return
        }
        audio.speechConsumer = { [weak self] buffer in self?.append(buffer) }
        audio.onEngineRestart = { [weak self] in
            guard let target = self else { return }
            target.queue.async { [target] in target.beginRecognition() }
        }
        phase = .wake
        beginRecognition()
        emitStatus("wake word on")
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        request?.append(buffer)
        requestLock.unlock()
    }

    private func beginRecognition() {
        endpointWork?.cancel()
        idleWork?.cancel()
        resetWork?.cancel()
        latestCandidate = ""
        heardSpeech = false
        generation &+= 1
        let currentGeneration = generation

        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil

        guard phase != .stopped, let recognizer, recognizer.isAvailable else { return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.addsPunctuation = true
        next.taskHint = .dictation
        next.contextualStrings = [phrase, "hey \(phrase)"]
        next.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        requestLock.lock()
        request = next
        requestLock.unlock()

        recognitionTask = recognizer.recognitionTask(with: next) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let hadError = error != nil
            guard let target = self else { return }
            target.queue.async { [target] in
                guard target.generation == currentGeneration, target.phase != .stopped else { return }
                if let text { target.consume(text, isFinal: isFinal) }
                if isFinal || hadError {
                    if target.phase == .wake || target.phase == .conversation || target.phase == .capture {
                        target.beginRecognition()
                    }
                }
            }
        }

        // Apple's streaming tasks are finite. Rotate proactively while still
        // healthy instead of waiting for a terminal error with a listening gap.
        scheduleRecognitionRotation(for: currentGeneration, after: 15)
    }

    private func scheduleRecognitionRotation(for recognitionGeneration: Int, after delay: TimeInterval) {
        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.generation == recognitionGeneration,
                  self.phase == .wake || self.phase == .conversation else { return }
            if self.phase == .conversation, self.heardSpeech {
                // Preserve an utterance that crosses Apple's proactive task
                // boundary. Its endpoint/final result will rotate naturally.
                self.scheduleRecognitionRotation(for: recognitionGeneration, after: 1)
                return
            }
            self.beginRecognition()
        }
        resetWork = reset
        queue.asyncAfter(deadline: .now() + delay, execute: reset)
    }

    private func consume(_ transcript: String, isFinal: Bool) {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .wake:
            guard let suffix = suffixAfterWake(in: clean) else { return }
            phase = .capture
            emitStatus("heard \(phrase)")
            if !suffix.isEmpty { acceptCandidate(suffix, isFinal: isFinal, bargeIn: false) }
            else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.phase == .capture, self.latestCandidate.isEmpty else { return }
                    self.returnToWakeLocked()
                }
                endpointWork = work
                queue.asyncAfter(deadline: .now() + 5, execute: work)
            }
        case .capture:
            let candidate = suffixAfterWake(in: clean) ?? clean
            acceptCandidate(candidate, isFinal: isFinal, bargeIn: false)
        case .conversation:
            acceptCandidate(clean, isFinal: isFinal, bargeIn: true)
        case .processing, .stopped:
            break
        }
    }

    private func acceptCandidate(_ value: String, isFinal: Bool, bargeIn: Bool) {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !clean.isEmpty else { return }
        if bargeIn, let echoGate {
            guard let filtered = echoGate.filtered(clean) else {
                listenLog("wake echo suppressed chars=\(clean.count)")
                return
            }
            clean = filtered
        }
        idleWork?.cancel()
        if !heardSpeech {
            heardSpeech = true
            DispatchQueue.main.async { [weak self] in self?.onSpeechBegan?(bargeIn) }
        }
        if clean != latestCandidate { latestCandidate = clean }
        endpointWork?.cancel()
        if isFinal {
            finishCommand(bargeIn: bargeIn)
            return
        }
        let words = clean.split(whereSeparator: \.isWhitespace).count
        let delay: TimeInterval = words <= 2 ? 0.68 : words <= 8 ? 0.82 : 1.0
        let work = DispatchWorkItem { [weak self] in self?.finishCommand(bargeIn: bargeIn) }
        endpointWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finishCommand(bargeIn: Bool) {
        endpointWork?.cancel()
        let command = latestCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { returnToWakeLocked(); return }
        phase = .processing
        generation &+= 1
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
        DispatchQueue.main.async { [weak self] in self?.onCommand?(command, bargeIn) }
    }

    private func scheduleConversationIdle() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .conversation else { return }
            self.returnToWakeLocked()
            self.emitStatus("wake word on")
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func returnToWakeLocked() {
        guard phase != .stopped else { return }
        phase = .wake
        beginRecognition()
        emitStatus("wake word on")
    }

    private func suffixAfterWake(in text: String) -> String? {
        WakePhraseMatcher.suffix(in: text, phrase: phrase)
    }

    private func stopLocked(releaseMic: Bool) {
        phase = .stopped
        lifecycleGeneration &+= 1
        generation &+= 1
        endpointWork?.cancel(); endpointWork = nil
        idleWork?.cancel(); idleWork = nil
        resetWork?.cancel(); resetWork = nil
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        recognitionTask?.cancel(); recognitionTask = nil
        audio.speechConsumer = nil
        audio.onEngineRestart = nil
        if releaseMic { audio.release("wake-word") }
        emitStatus("wake word off")
    }

    private func fail(_ message: String) {
        stopLocked(releaseMic: true)
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private func emitStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(message) }
    }
}
