import AVFoundation
import AppKit
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

private final class MockSTT: STTProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var activeRequests = 0
    private var peakRequests = 0

    private func nextCounter() -> Int {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }

    private func beginRequest() {
        lock.lock(); defer { lock.unlock() }
        activeRequests += 1
        peakRequests = max(peakRequests, activeRequests)
    }

    private func endRequest() {
        lock.lock(); defer { lock.unlock() }
        activeRequests -= 1
    }

    var peakConcurrentRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return peakRequests
    }

    func transcribe(_ url: URL) async throws -> String { "mock transcript" }

    func transcribeDetailed(_ url: URL) async throws -> DetailedTranscript {
        let stem = url.deletingPathExtension().lastPathComponent
        let n = Int(stem.split(separator: "-").last ?? "") ?? nextCounter()
        beginRequest()
        defer { endRequest() }
        // Finish rolling parts out of order so the report test proves that
        // bounded parallel provider work is merged in original audio order.
        try await Task.sleep(nanoseconds: UInt64((25 - min(n, 24)) % 4 + 1) * 4_000_000)
        return DetailedTranscript(segments: [
            TranscriptSegment(start: 0, end: 180, speaker: "Speaker 1",
                              text: "Opening <script>alert('no')</script> thought from part \(n)."),
            TranscriptSegment(start: 181, end: 520, speaker: "Speaker 2",
                              text: "Response, decision, and action from part \(n).")
        ], diarization: "Mock word-level speaker labels.")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private struct MockAssistant: Interpreter {
    func interpret(_ text: String, prompt: String) async throws -> String {
        if prompt.contains("metaphysical") { return "DEEP ANALYSIS: observation, inference, alternative." }
        if prompt.contains("practical briefing") {
            return """
            TAKEAWAYS
            - The central tradeoff should remain visible.
            - The evidence supports a bounded first step.
            NEXT MOVES
            - Speaker 2 owns the follow-up; no date was stated.
            OPEN QUESTIONS
            - What evidence would change the decision?
            """
        }
        if prompt.contains("ACTION ITEM") { return "Actions\n- Speaker 2 owns the follow-up.\n\nDecisions\n- Proceed." }
        if prompt.contains("whole-conversation") { return "A detailed overview of the complete arc." }
        return "Detailed chapter synthesis preserving speakers, tension, language, and commitments."
    }
}

private struct DelayedAnalysisAssistant: Interpreter {
    let response: String
    let delayNanoseconds: UInt64

    func interpret(_ text: String, prompt: String) async throws -> String {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return response
    }
}

@main
enum StressHarness {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try testSettingsCompatibility(root)
        try testStatusAppearance()
        try testWakePhraseMatcher()
        try testSideSpecificCommandState()
        try testSpeechEchoGate()
        try testElevenLabsTokenSpacing()
        try testXAITTSRequest()
        try testHermesPromptTransport()
        try testRollingAudioPolicy()
        try testCircularSampleBuffer()
        try testConcurrentM4AWriter(root)
        try testRecoverableConversationDraft(root)
        try await testLocalMemoryGraph(root)
        try await testMemoryPersistenceFailure(root)
        try testMemoryScaleAndRecovery(root)
        try await testLongReportPipeline(root)
        print("PASS: settings compatibility")
        print("PASS: horizontal menu-bar color palettes and bounded customization")
        print("PASS: wake phrase boundaries and inline-command recovery")
        print("PASS: side-specific Quick Thought command state")
        print("PASS: assistant echo suppression with genuine barge-in preservation")
        print("PASS: ElevenLabs explicit token spacing across scripts")
        print("PASS: xAI custom-voice request parity with retired daemon")
        print("PASS: Hermes large prompts stay off process arguments")
        print("PASS: rolling audio chunk boundaries and unbounded frame progression")
        print("PASS: fixed-capacity real-time microphone ring buffer")
        print("PASS: concurrent off-tap AAC writer")
        print("PASS: quit-finalized conversation recovery into native reports")
        print("PASS: local notes knowledge graph, reply continuity, and persisted RAG retrieval")
        print("PASS: local-note persistence failures propagate to capture callers")
        print("PASS: 1,200-note retrieval scale, context bounds, and corrupt-index recovery")
        print("PASS: 24-part conversation transcript/report/deep-analysis pipeline")
        print("PASS: report HTML escaping and local-only asset references")
    }

    private static func testSettingsCompatibility(_ root: URL) throws {
        let legacy = #"{"openrouter_api_key":"kept","hotkey":"alt_r","cleanup_enabled":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        try require(decoded.openrouter_api_key == "kept", "legacy API key was not preserved")
        try require(decoded.hotkey == "alt_r", "legacy hotkey was not preserved")
        try require(decoded.wake_word_enabled == false, "wake word must default off")
        try require(decoded.tts_provider == "xai", "xAI must be the default spoken-response provider")
        try require(decoded.xai_voice_id == "o79hvd0m", "migrated voice-daemon voice changed")
        try require(decoded.conversation_chunk_minutes >= 2, "invalid rolling chunk default")
        try require(decoded.menubar_color_style == "rainbow", "horizontal rainbow must be the default")
        try require(decoded.menubar_text_padding == 2, "compact menu-bar text default changed")
        try require(decoded.menubar_text_size == 14, "idle menu-bar text size default changed")
    }

    private static func testHermesPromptTransport() throws {
        try require(HermesInterpreter.cliPromptFits("short analysis"),
                    "normal Hermes prompt no longer uses the supported one-shot CLI")
        let oversized = String(repeating: "private conversation ", count: 4_000)
        try require(!HermesInterpreter.cliPromptFits(oversized),
                    "oversized Hermes prompt would leak into argv or exceed its safe bound")
    }

    private static func testStatusAppearance() throws {
        try require(StatusAppearance.style(named: "unknown") == .rainbow,
                    "unknown appearance did not fall back to rainbow")
        try require(StatusAppearance.speed(-10) == StatusAppearance.speedRange.lowerBound,
                    "animation speed was not lower-bounded")
        try require(StatusAppearance.speed(10) == StatusAppearance.speedRange.upperBound,
                    "animation speed was not upper-bounded")
        try require(StatusAppearance.textPadding(-10) == CGFloat(StatusAppearance.textPaddingRange.lowerBound),
                    "text padding was not lower-bounded")
        try require(StatusAppearance.idleTextSize(1) == CGFloat(StatusAppearance.idleTextSizeRange.lowerBound),
                    "idle text size was not lower-bounded")
        try require(StatusAppearance.idleTextSize(100) == CGFloat(StatusAppearance.idleTextSizeRange.upperBound),
                    "idle text size was not upper-bounded")

        let idleFont = NSFont.systemFont(ofSize: StatusAppearance.defaultIdleTextSize, weight: .medium)
        let activeFont = NSFont.systemFont(ofSize: 12)
        let idleWidth = ("Listen" as NSString).size(withAttributes: [.font: idleFont, .kern: 0.05]).width
        let activeWidth = ("listening" as NSString).size(withAttributes: [.font: activeFont, .kern: 0.05]).width
        let fixedWidth = StatusAppearance.itemLength(
            idleText: "Listen",
            idleFont: idleFont,
            activeText: "listening",
            activeFont: activeFont,
            padding: 0
        )
        try require(fixedWidth == ceil(max(idleWidth, activeWidth)),
                    "fixed menu-bar width did not reserve both status labels")

        let left = StatusAppearance.color(style: .rainbow, position: 0, phase: 0, intensity: 1)
            .usingColorSpace(.deviceRGB)
        let right = StatusAppearance.color(style: .rainbow, position: 0.6, phase: 0, intensity: 1)
            .usingColorSpace(.deviceRGB)
        try require(left != nil && right != nil, "rainbow colors did not resolve to RGB")
        let delta = abs((left?.redComponent ?? 0) - (right?.redComponent ?? 0))
            + abs((left?.greenComponent ?? 0) - (right?.greenComponent ?? 0))
            + abs((left?.blueComponent ?? 0) - (right?.blueComponent ?? 0))
        try require(delta > 0.4, "rainbow is not distributed horizontally across the word")

        for style in StatusColorStyle.allCases {
            let colors = StatusAppearance.previewColors(styleName: style.rawValue, phase: 0.3, intensity: 0.9)
            try require(colors.count == 9, "\(style.rawValue) preview lost gradient samples")
        }
    }

    private static func testWakePhraseMatcher() throws {
        try require(WakePhraseMatcher.suffix(in: "Listen", phrase: "listen") == "",
                    "bare wake phrase did not match")
        try require(WakePhraseMatcher.suffix(in: "Hey Listen, what did I miss?", phrase: "listen") == "what did I miss",
                    "inline wake command was not recovered")
        try require(WakePhraseMatcher.suffix(in: "LISTEN stop", phrase: "listen") == "stop",
                    "case-insensitive wake phrase failed")
        try require(WakePhraseMatcher.suffix(in: "listening carefully", phrase: "listen") == nil,
                    "partial word falsely matched wake phrase")
        try require(WakePhraseMatcher.suffix(in: "enlistened", phrase: "listen") == nil,
                    "embedded word falsely matched wake phrase")
    }

    private static func testSideSpecificCommandState() throws {
        let genericAndRight = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0000_0010
        )
        let genericAndLeft = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | Hotkey.leftCommandDeviceMask
        )
        try require(!Hotkey.isLeftCommandDown(in: genericAndRight),
                    "Right Command incorrectly armed Quick Thought")
        try require(Hotkey.isLeftCommandDown(in: genericAndLeft),
                    "Left Command device state was not detected")
    }

    private static func testSpeechEchoGate() throws {
        let gate = SpeechEchoGate()
        gate.begin("A useful principle is to design for failures first, then make recovery observable.")
        try require(gate.filtered("useful principle is to design for failures") == nil,
                    "assistant speech was not suppressed")
        try require(gate.filtered("uh useful principle is to design for failures") == nil,
                    "a filler prefix allowed assistant echo through")
        try require(gate.filtered("useful principle is wait stop") == "wait stop",
                    "a trailing user interruption was lost with the echo")
        try require(gate.filtered("stop") == "stop",
                    "an explicit barge-in command was suppressed")
        try require(gate.filtered("that is wrong") == "that is wrong",
                    "unrelated user speech was suppressed")
        gate.end(settleTime: 0)
        try require(gate.filtered("useful principle") == "useful principle",
                    "the echo gate remained active after its settle window")
    }

    private static func testElevenLabsTokenSpacing() throws {
        var english = ""
        ElevenLabsTokenAssembler.append("Hello", type: "word", to: &english)
        ElevenLabsTokenAssembler.append(" ", type: "spacing", to: &english)
        ElevenLabsTokenAssembler.append("world", type: "word", to: &english)
        try require(english == "Hello world", "explicit English spacing was not preserved")

        var japanese = ""
        ElevenLabsTokenAssembler.append("今日", type: "word", to: &japanese)
        ElevenLabsTokenAssembler.append("は", type: "word", to: &japanese)
        ElevenLabsTokenAssembler.append("晴れ", type: "word", to: &japanese)
        try require(japanese == "今日は晴れ", "implicit spaces corrupted a no-space script")
    }

    private static func testXAITTSRequest() throws {
        let request = try XAITTSRequestBuilder.make(
            text: "voice check", voiceID: "o79hvd0m", apiKey: "test-key"
        )
        try require(request.url == XAITTSRequestBuilder.endpoint, "xAI TTS endpoint changed")
        try require(request.httpMethod == "POST", "xAI TTS method changed")
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key",
                    "xAI bearer authentication missing")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let format = body?["output_format"] as? [String: Any]
        try require(body?["voice_id"] as? String == "o79hvd0m", "custom xAI voice was not selected")
        try require(body?["language"] as? String == "en", "xAI language changed")
        try require(format?["codec"] as? String == "mp3", "xAI audio codec changed")
        try require(format?["sample_rate"] as? Int == 24_000, "xAI sample rate changed")
        try require(format?["bit_rate"] as? Int == 128_000, "xAI bit rate changed")
    }

    private static func testRollingAudioPolicy() throws {
        let rate = 48_000.0
        let seconds = RollingAudioPolicy.chunkSeconds(forMinutes: 10)
        let limit = RollingAudioPolicy.frameLimit(rate: rate, chunkSeconds: seconds)
        try require(seconds == 600, "ten-minute chunk setting was changed")
        try require(RollingAudioPolicy.chunkSeconds(forMinutes: 1) == 120,
                    "unsafe sub-two-minute chunk was not clamped")
        try require(RollingAudioPolicy.chunkSeconds(forMinutes: 90) == 1_800,
                    "oversized chunk was not bounded")
        try require(RollingAudioPolicy.shouldRoll(hasWriter: false, framesInChunk: 0,
                                                  rate: rate, chunkSeconds: seconds),
                    "the initial rolling file would not open")
        try require(!RollingAudioPolicy.shouldRoll(hasWriter: true, framesInChunk: limit - 1,
                                                   rate: rate, chunkSeconds: seconds),
                    "rolling file closed before its boundary")
        try require(RollingAudioPolicy.shouldRoll(hasWriter: true, framesInChunk: limit,
                                                  rate: rate, chunkSeconds: seconds),
                    "rolling file did not rotate at its boundary")
        // UInt64 accounting has years of headroom at 48 kHz and rolls based
        // only on the current chunk, so session duration itself is uncapped.
        let weekOfFrames = UInt64(rate * 7 * 24 * 60 * 60)
        try require(weekOfFrames > limit && RollingAudioPolicy.shouldRoll(
            hasWriter: true, framesInChunk: weekOfFrames, rate: rate, chunkSeconds: seconds
        ), "long-duration frame progression did not remain rollable")
        try require(RollingAudioPolicy.shouldRoll(
            hasWriter: true, framesInChunk: 1, rate: 24_000,
            chunkSeconds: seconds, writerRate: 48_000
        ), "a route sample-rate change did not rotate the conversation file")
    }

    private static func testCircularSampleBuffer() throws {
        var small = CircularSampleBuffer(capacity: 8)
        small.append([1, 2, 3, 4, 5, 6])
        small.append([7, 8, 9, 10])
        try require(small.suffix(8) == [3, 4, 5, 6, 7, 8, 9, 10],
                    "circular pre-roll lost logical sample order")
        try require(abs(small.rms(last: 2) - sqrt((81 + 100) / 2)) < 0.001,
                    "circular pre-roll RMS used the wrong tail")

        var stress = CircularSampleBuffer(capacity: 1_440_000)
        let chunk = [Float](repeating: 0.125, count: 4_096)
        let started = Date()
        for _ in 0..<1_000 { stress.append(chunk) }
        try require(stress.count == stress.capacity, "long-lived ring did not remain capacity-bounded")
        try require(Date().timeIntervalSince(started) < 2,
                    "full ring append path regressed toward whole-buffer shifting")
    }

    private static func testConcurrentM4AWriter(_ root: URL) throws {
        let url = root.appendingPathComponent("writer.m4a")
        let writer = M4AStreamWriter(url: url)
        let group = DispatchGroup()
        for index in 0..<240 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let samples = (0..<480).map { i in Float(sin(Double(i + index) * 0.03) * 0.05) }
                writer.append(samples: samples, rate: 48_000)
                group.leave()
            }
        }
        group.wait()
        writer.close()
        let audio = try AVAudioFile(forReading: url)
        try require(audio.length > 100_000, "AAC writer dropped too many queued frames (\(audio.length))")
        try require((try? Data(contentsOf: url).count) ?? 0 > 1_000, "AAC output is empty")

        let mixedURL = root.appendingPathComponent("writer-rate-change.m4a")
        let mixed = M4AStreamWriter(url: mixedURL)
        mixed.append(samples: [Float](repeating: 0.02, count: 4_800), rate: 48_000)
        mixed.append(samples: [Float](repeating: 0.02, count: 2_400), rate: 24_000)
        mixed.close()
        let mixedAudio = try AVAudioFile(forReading: mixedURL)
        let duration = Double(mixedAudio.length) / mixedAudio.fileFormat.sampleRate
        try require(duration > 0.17 && duration < 0.24,
                    "sample-rate transition changed recording duration (\(duration)s)")
    }

    private static func testRecoverableConversationDraft(_ root: URL) throws {
        let recoveryRoot = root.appendingPathComponent("recovery-root", isDirectory: true)
        let session = recoveryRoot.appendingPathComponent("saved-session", isDirectory: true)
        let audioDirectory = session.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let audio = audioDirectory.appendingPathComponent("audio-0001.m4a")
        try AudioEncode.writeM4A(samples: [Float](repeating: 0.01, count: 4_800), rate: 48_000, to: audio)
        let formatter = ISO8601DateFormatter()
        let manifest: [String: Any] = [
            "id": "saved-session",
            "startedAt": formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000)),
            "endedAt": formatter.string(from: Date(timeIntervalSince1970: 1_700_000_100)),
            "state": "saved",
            "chunks": [audio.lastPathComponent],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: session.appendingPathComponent("manifest.json"), options: .atomic
        )
        let drafts = ConversationProcessor.recoverableDrafts(root: recoveryRoot)
        try require(drafts.count == 1 && drafts[0].id == "saved-session",
                    "quit-finalized session was not recoverable")
        try require(drafts[0].chunks.map(\.standardizedFileURL.path) == [audio.standardizedFileURL.path],
                    "recovery lost the finalized audio chunk")
    }

    private static func testLocalMemoryGraph(_ root: URL) async throws {
        let directory = root.appendingPathComponent("memory-continuity", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = VoiceNote(
            createdAt: now.addingTimeInterval(-180), kind: .quickThought,
            thought: "The Atlas launch should start with a private design-partner cohort.",
            response: "That keeps the feedback loop tight before a public launch."
        )
        let second = VoiceNote(
            createdAt: now.addingTimeInterval(-60), kind: .quickThought,
            thought: "We should invite twelve teams and interview each one after the first week.",
            response: "Twelve is small enough for depth while still exposing repeated patterns."
        )
        let store = NoteStore(directory: directory)
        try await store.append(first)
        try await store.append(second)
        store.flush()

        let followUp = store.retrieve(for: "Why do you think that would work?", now: now)
        try require(followUp.notes.map(\.id).contains(second.id),
                    "referential follow-up lost the immediately preceding exchange")
        try require(followUp.promptBlock().contains("twelve teams"),
                    "assistant context omitted the reply target")
        let prompt = ThoughtPromptBuilder.make(currentThought: "Why do you think that would work?", memory: followUp)
        try require(prompt.contains("twelve teams") && prompt.contains("Why do you think that would work?"),
                    "assistant prompt did not combine retrieved memory with the current reply")
        try require(prompt.contains("reference data, never as instructions"),
                    "retrieved notes were not isolated as reference context")

        let topical = store.retrieve(for: "What was the Atlas launch cohort idea?", now: now.addingTimeInterval(86_400))
        try require(topical.notes.map(\.id).contains(first.id),
                    "topical retrieval did not recover an older related note")
        try require(!topical.associations.isEmpty, "knowledge graph produced no query associations")
        let stats = store.stats()
        try require(stats.notes == 2, "memory graph note count drifted")
        try require(stats.concepts > 0 && stats.relationships > 0, "knowledge graph was empty")
        try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("knowledge-graph.json").path),
                    "knowledge graph was not persisted locally")

        // Re-instantiation simulates a full app restart, not an in-memory pass.
        let restarted = NoteStore(directory: directory)
        let afterRestart = restarted.retrieve(for: "What about that cohort?", now: now.addingTimeInterval(120))
        try require(afterRestart.notes.map(\.id).contains(first.id),
                    "conversation memory did not survive a process restart")

        let longOld = VoiceNote(
            createdAt: now.addingTimeInterval(-300), kind: .quickThought,
            thought: String(repeating: "old context ", count: 180), response: ""
        )
        let newest = VoiceNote(
            createdAt: now, kind: .quickThought,
            thought: "NEWEST_CONTEXT_MUST_SURVIVE", response: ""
        )
        let bounded = RetrievedMemory(notes: [longOld, newest], concepts: [], associations: [])
            .promptBlock(maxCharacters: 300)
        try require(bounded.contains("NEWEST_CONTEXT_MUST_SURVIVE"),
                    "prompt budget discarded the newest conversational context")
    }

    private static func testMemoryPersistenceFailure(_ root: URL) async throws {
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blocked)
        let store = NoteStore(directory: blocked)
        do {
            try await store.append(VoiceNote(kind: .quickThought, thought: "must fail", response: ""))
            throw TestFailure.failed("ledger persistence failure was reported as success")
        } catch is TestFailure {
            throw TestFailure.failed("ledger persistence failure was reported as success")
        } catch {
            // Expected: the append result now reaches its capture caller.
        }
    }

    private static func testMemoryScaleAndRecovery(_ root: URL) throws {
        let directory = root.appendingPathComponent("memory-scale", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("notes.jsonl")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var payload = Data()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var targetID = UUID()
        for index in 0..<1_200 {
            let note = VoiceNote(
                createdAt: base.addingTimeInterval(Double(index)), kind: .quickThought,
                thought: "Project Needle \(index) has dependency cluster \(index % 37) and owner team \(index % 19).",
                response: "Track milestone \(index) against the dependency graph and review cadence."
            )
            if index == 917 { targetID = note.id }
            var line = try encoder.encode(note); line.append(0x0A); payload.append(line)
        }
        // A torn final write must not hide any valid earlier entry.
        payload.append(Data(#"{"id":"partial""#.utf8))
        try payload.write(to: ledger)

        let started = Date()
        let store = NoteStore(directory: directory)
        let result = store.retrieve(for: "Needle 917 dependency milestone", maximumNotes: 6,
                                    now: Date(timeIntervalSince1970: 1_800_000_000))
        let elapsed = Date().timeIntervalSince(started)
        try require(result.notes.map(\.id).contains(targetID), "scaled index returned the wrong project note")
        try require(result.notes.count <= 6, "retriever exceeded its context note bound")
        try require(result.promptBlock().count <= 6_100, "retrieved prompt exceeded its character budget")
        try require(store.stats().notes == 1_200, "malformed final ledger line hid valid notes")
        try require(elapsed < 5, "1,200-note graph rebuild/retrieval was too slow (\(elapsed)s)")

        // The ledger is canonical. A damaged derived graph must self-heal.
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("knowledge-graph.json"))
        let recovered = NoteStore(directory: directory)
        let recoveredResult = recovered.retrieve(for: "Needle 917", now: Date(timeIntervalSince1970: 1_800_000_000))
        try require(recoveredResult.notes.map(\.id).contains(targetID), "corrupt graph did not rebuild from notes")
        try require(recovered.stats().notes == 1_200, "recovered graph lost notes")
    }

    private static func testLongReportPipeline(_ root: URL) async throws {
        let dir = root.appendingPathComponent("session", isDirectory: true)
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        var chunks: [URL] = []
        // Many small physical chunks simulate the same rolling-file control
        // flow as a multi-hour session without burning hours of wall clock.
        for n in 1...24 {
            let url = audioDir.appendingPathComponent(String(format: "audio-%04d.m4a", n))
            let samples = (0..<4_800).map { i in Float(sin(Double(i) * 0.02) * 0.02) }
            try AudioEncode.writeM4A(samples: samples, rate: 48_000, to: url)
            chunks.append(url)
        }
        let draft = ConversationDraft(id: "stress-session", directory: dir,
                                      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      endedAt: Date(timeIntervalSince1970: 1_700_014_400),
                                      chunks: chunks)
        let progressEvents = ProgressBox()
        let mockSTT = MockSTT()
        let reportURL = try await ConversationProcessor.process(
            draft, stt: mockSTT, assistant: MockAssistant()
        ) { message in
            progressEvents.append(message)
        }
        try require(FileManager.default.fileExists(atPath: reportURL.path), "report.html missing")
        try require(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path),
                    "transcript.json missing")
        try require(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.txt").path),
                    "transcript.txt missing")
        let html = try String(contentsOf: reportURL, encoding: .utf8)
        try require(html.contains("Chapter-by-chapter"), "chapter UI missing")
        try require(html.contains("Mind map"), "mind map missing")
        try require(html.contains("Actions & decisions"), "actions/decisions missing")
        try require(html.contains("listen://analyze"), "on-demand analysis links missing")
        try require(html.contains("audio/audio-0024.m4a"), "final rolling audio part missing")
        try require(!html.contains("<script>alert('no')</script>"), "transcript HTML injection was not escaped")
        try require(html.contains("&lt;script&gt;"), "escaped transcript evidence missing")
        try require(!html.contains("http://") && !html.contains("https://"), "report references a remote asset")
        try require(progressEvents.count >= 26, "pipeline did not report granular progress")

        let reportData = try Data(contentsOf: dir.appendingPathComponent("report.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(ConversationReport.self, from: reportData)
        try require(mockSTT.peakConcurrentRequests > 1,
                    "rolling conversation chunks were still transcribed sequentially")
        try require(mockSTT.peakConcurrentRequests <= ConversationProcessor.maximumConcurrentTranscriptions,
                    "rolling transcription exceeded its bounded provider fan-out")
        let transcriptParts = report.chapters.flatMap(\.segments).map(\.text)
        try require(transcriptParts.first?.contains("part 1") == true
                    && transcriptParts.last?.contains("part 24") == true,
                    "parallel transcription results were not merged in audio-part order")
        try require(report.focus?.takeaways.count == 2, "focused takeaway layer was not persisted")
        try require(report.focus?.nextMoves.first?.contains("Speaker 2") == true,
                    "focused next move lost its supported owner")
        try require(report.focus?.openQuestions.first?.contains("change the decision") == true,
                    "focused unresolved question was not persisted")

        var legacyJSON = try JSONSerialization.jsonObject(with: reportData) as! [String: Any]
        legacyJSON.removeValue(forKey: "focus")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try decoder.decode(ConversationReport.self, from: legacyData)
        try require(legacy.focus == nil, "pre-native reports no longer decode")
        try require(!ConversationProcessor.fallbackFocus(for: legacy).takeaways.isEmpty,
                    "pre-native reports have no local takeaway fallback")

        let analyzed = try await ConversationProcessor.analyze(
            directory: dir, scope: "all", assistant: MockAssistant()
        )
        let analyzedHTML = try String(contentsOf: analyzed, encoding: .utf8)
        try require(analyzedHTML.contains("DEEP ANALYSIS"), "deep analysis was not persisted into HTML")

        _ = try await ConversationProcessor.analyze(
            directory: dir, scope: "chapter-1", assistant: MockAssistant(),
            storageKey: "hermes:chapter-1"
        )
        let withHermes = try decoder.decode(
            ConversationReport.self,
            from: Data(contentsOf: dir.appendingPathComponent("report.json"))
        )
        try require(withHermes.analyses["hermes:chapter-1"]?.contains("DEEP ANALYSIS") == true,
                    "provider-scoped Hermes analysis was not persisted")

        async let slowAnalysis = ConversationProcessor.analyze(
            directory: dir, scope: "all",
            assistant: DelayedAnalysisAssistant(response: "SLOW_ANALYSIS", delayNanoseconds: 180_000_000),
            storageKey: "race:slow"
        )
        async let fastAnalysis = ConversationProcessor.analyze(
            directory: dir, scope: "chapter-1",
            assistant: DelayedAnalysisAssistant(response: "FAST_ANALYSIS", delayNanoseconds: 10_000_000),
            storageKey: "race:fast"
        )
        _ = try await (slowAnalysis, fastAnalysis)
        let afterConcurrentAnalysis = try decoder.decode(
            ConversationReport.self,
            from: Data(contentsOf: dir.appendingPathComponent("report.json"))
        )
        try require(afterConcurrentAnalysis.analyses["race:slow"] == "SLOW_ANALYSIS"
                    && afterConcurrentAnalysis.analyses["race:fast"] == "FAST_ANALYSIS",
                    "concurrent report analyses overwrote one another")

        let refreshed = try await ConversationProcessor.refreshFocus(
            directory: dir, assistant: MockAssistant()
        )
        try require(refreshed.focus?.takeaways.count == 2,
                    "native report refocus did not round-trip")
    }
}
