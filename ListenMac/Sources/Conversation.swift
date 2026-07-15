import AppKit
import AVFoundation
import Foundation

enum SessionStore {
    static var root: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".listen/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

struct ConversationDraft: Codable, Sendable {
    var id: String
    var directory: URL
    var startedAt: Date
    var endedAt: Date
    var chunks: [URL]
}

private struct SessionManifest: Codable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var state: String
    var chunks: [String]
}

enum RollingAudioPolicy {
    static func chunkSeconds(forMinutes minutes: Int) -> Double {
        Double(max(2, min(30, minutes)) * 60)
    }

    static func frameLimit(rate: Double, chunkSeconds: Double) -> UInt64 {
        UInt64(max(1, rate * chunkSeconds))
    }

    static func shouldRoll(hasWriter: Bool, framesInChunk: UInt64,
                           rate: Double, chunkSeconds: Double) -> Bool {
        !hasWriter || framesInChunk >= frameLimit(rate: rate, chunkSeconds: chunkSeconds)
    }
}

/// Unbounded conversation capture. Audio is rolled at a configurable interval
/// so one corrupt final container can never take hours of earlier audio with
/// it. The tap callback only enqueues work; encoding and disk I/O are off the
/// audio thread.
final class ConversationRecorder: @unchecked Sendable {
    private let audio: AudioEngine
    private let queue = DispatchQueue(label: "com.listen.conversation-recorder", qos: .utility)
    private var sinkID: UUID?
    private var directory: URL?
    private var sessionID = ""
    private var startedAt = Date()
    private var writer: M4AStreamWriter?
    private var chunkURLs: [URL] = []
    private var framesInChunk: UInt64 = 0
    private var chunkSeconds: Double = 600
    private var accepting = false

    init(audio: AudioEngine = .shared) { self.audio = audio }

    var isRecording: Bool { queue.sync { accepting } }

    func start(chunkMinutes: Int) throws -> URL {
        if isRecording {
            throw NSError(domain: "Listen", code: 2001,
                          userInfo: [NSLocalizedDescriptionKey: "A conversation is already recording"])
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let id = "\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = SessionStore.root.appendingPathComponent(id, isDirectory: true)
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try audio.acquire("conversation-recorder")

        queue.sync {
            sessionID = id
            directory = dir
            startedAt = Date()
            chunkSeconds = RollingAudioPolicy.chunkSeconds(forMinutes: chunkMinutes)
            chunkURLs = []
            framesInChunk = 0
            writer = nil
            accepting = true
        }
        let idForSink = audio.addSink { [weak self] samples, rate in
            guard let target = self else { return }
            target.queue.async { [target] in target.accept(samples: samples, rate: rate) }
        }
        sinkID = idForSink
        writeManifest(state: "recording", endedAt: nil)
        NSLog("[Listen] conversation recording started: \(id)")
        return dir
    }

    func stop() async -> ConversationDraft? {
        guard isRecording else { return nil }
        if let sinkID { audio.removeSink(sinkID) }
        self.sinkID = nil
        let result: ConversationDraft? = await Task.detached(priority: .utility) { [self] in
            queue.sync {
                accepting = false
                writer?.close()
                writer = nil
                guard let directory else { return nil }
                return ConversationDraft(id: sessionID, directory: directory,
                                         startedAt: startedAt, endedAt: Date(), chunks: chunkURLs)
            }
        }.value
        audio.release("conversation-recorder")
        if let result {
            writeManifest(state: "processing", endedAt: result.endedAt)
            NSLog("[Listen] conversation recording stopped: \(result.id), \(result.chunks.count) chunks")
        }
        return result
    }

    private func accept(samples: [Float], rate: Double) {
        guard accepting, !samples.isEmpty, let directory else { return }
        if RollingAudioPolicy.shouldRoll(hasWriter: writer != nil, framesInChunk: framesInChunk,
                                         rate: rate, chunkSeconds: chunkSeconds) {
            writer?.close()
            framesInChunk = 0
            let audioDir = directory.appendingPathComponent("audio", isDirectory: true)
            let url = audioDir.appendingPathComponent(String(format: "audio-%04d.m4a", chunkURLs.count + 1))
            writer = M4AStreamWriter(url: url)
            chunkURLs.append(url)
            writeManifest(state: "recording", endedAt: nil)
        }
        writer?.append(samples: samples, rate: rate)
        framesInChunk &+= UInt64(samples.count)
    }

    private func writeManifest(state: String, endedAt: Date?) {
        queue.async { [self] in
            guard let directory else { return }
            let manifest = SessionManifest(id: sessionID, startedAt: startedAt, endedAt: endedAt,
                                           state: state, chunks: chunkURLs.map(\.lastPathComponent))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(manifest) {
                try? data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            }
        }
    }
}

struct ReportChapter: Codable, Sendable {
    var id: String
    var title: String
    var start: Double
    var end: Double
    var summary: String
    var segments: [TranscriptSegment]
}

struct ConversationFocus: Codable, Sendable, Equatable {
    var takeaways: [String]
    var nextMoves: [String]
    var openQuestions: [String]

    var isEmpty: Bool { takeaways.isEmpty && nextMoves.isEmpty && openQuestions.isEmpty }
    var isUseful: Bool {
        (takeaways + nextMoves + openQuestions).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12
        }
    }
}

struct ConversationReport: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date
    var audioFiles: [String]
    var diarization: String
    var overview: String
    var actionsAndDecisions: String
    /// Optional so reports created before the native conversation library
    /// remain decodable. The native UI supplies a deterministic local fallback
    /// and can regenerate this richer layer on demand.
    var focus: ConversationFocus?
    var chapters: [ReportChapter]
    var analyses: [String: String]
    var processingErrors: [String]
}

enum ConversationProcessor {
    static func process(
        _ draft: ConversationDraft,
        stt: STTProvider,
        assistant: Interpreter?,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        var allSegments: [TranscriptSegment] = []
        var offset: Double = 0
        var diarizationNotes: [String] = []
        var errors: [String] = []

        for (index, chunk) in draft.chunks.enumerated() {
            progress("transcribing \(index + 1)/\(draft.chunks.count)")
            let duration = audioDuration(chunk)
            do {
                var detailed = try await withTimeout(180) { try await stt.transcribeDetailed(chunk) }
                for i in detailed.segments.indices {
                    detailed.segments[i].chunk = index
                    detailed.segments[i].start += offset
                    detailed.segments[i].end += offset
                    // Cloud diarizers restart their anonymous speaker ids on
                    // every request. Keep labels honest across rolling files
                    // instead of falsely claiming Speaker 1 is the same voice
                    // hours later.
                    if draft.chunks.count > 1 && detailed.segments[i].speaker != "System" {
                        detailed.segments[i].speaker = "Part \(index + 1) · \(detailed.segments[i].speaker)"
                    }
                }
                allSegments.append(contentsOf: detailed.segments)
                if !diarizationNotes.contains(detailed.diarization) { diarizationNotes.append(detailed.diarization) }
            } catch {
                let message = "Chunk \(index + 1) transcription failed: \(error.localizedDescription)"
                errors.append(message)
                allSegments.append(TranscriptSegment(chunk: index, start: offset, end: offset + duration,
                                                     speaker: "System", text: "[\(message)]"))
            }
            offset += duration
        }

        let decoderEncoder = JSONEncoder()
        decoderEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var diarization = diarizationNotes.joined(separator: " ")
        if draft.chunks.count > 1 {
            diarization += " Speaker numbering is scoped to each rolling audio part; Listen does not infer cross-part voice identity."
        }
        let transcript = DetailedTranscript(segments: allSegments, diarization: diarization)
        try decoderEncoder.encode(transcript)
            .write(to: draft.directory.appendingPathComponent("transcript.json"), options: .atomic)
        let transcriptText = allSegments.map {
            "[\(formatTime($0.start))] \($0.speaker): \($0.text)"
        }.joined(separator: "\n\n")
        try transcriptText.write(to: draft.directory.appendingPathComponent("transcript.txt"),
                                 atomically: true, encoding: .utf8)

        let groups = chapterGroups(allSegments)
        var chapters: [ReportChapter] = []
        for (index, group) in groups.enumerated() {
            progress("summarizing chapter \(index + 1)/\(groups.count)")
            let exchange = group.map { "[\(formatTime($0.start))] \($0.speaker): \($0.text)" }
                .joined(separator: "\n")
            let title = localChapterTitle(index: index, segments: group)
            let summary: String
            if let assistant {
                let prompt = """
                Write a deep, detailed chapter summary of this conversation exchange. Preserve nuance, disagreements, examples, emotional turns, causal reasoning, and exact commitments. Distinguish what each labeled speaker contributed. Include: narrative summary, key ideas, language/tone observations, unresolved questions, and links to earlier ideas when evident. Do not invent facts. The output must stand alone and contain no preamble.\n\n{text}
                """
                do { summary = try await withTimeout(75) { try await assistant.interpret(exchange, prompt: prompt) } }
                catch {
                    errors.append("Chapter \(index + 1) summary failed: \(error.localizedDescription)")
                    summary = localSummary(group)
                }
            } else {
                summary = localSummary(group)
            }
            chapters.append(ReportChapter(id: "chapter-\(index + 1)", title: title,
                                          start: group.first?.start ?? 0, end: group.last?.end ?? 0,
                                          summary: summary, segments: group))
        }

        progress("synthesizing report")
        let chapterDigest = chapters.enumerated().map {
            "CHAPTER \($0.offset + 1): \($0.element.title)\n\($0.element.summary)"
        }.joined(separator: "\n\n")
        var overview = localOverview(chapters)
        var actions = "No actions or decisions were confidently extracted without an analysis provider."
        if let assistant, !chapterDigest.isEmpty {
            do {
                overview = try await withTimeout(75) {
                    try await assistant.interpret(chapterDigest, prompt: """
                    Produce a comprehensive whole-conversation synthesis from these chapter analyses. Cover the arc of the exchange, central themes, strongest insights, tensions, changes of mind, and unresolved questions. Be detailed but avoid repetition. Do not invent information.\n\n{text}
                    """)
                }
            } catch { errors.append("Overview failed: \(error.localizedDescription)") }
            do {
                actions = try await withTimeout(75) {
                    try await assistant.interpret(chapterDigest, prompt: """
                    Extract every explicit or strongly implied ACTION ITEM and DECISION from these chapter analyses. For actions include owner and due date only when actually stated; otherwise say unassigned/no date. Separate Actions and Decisions. Add a short Evidence clause identifying the relevant chapter. Never fabricate commitments.\n\n{text}
                    """)
                }
            } catch { errors.append("Actions/decisions failed: \(error.localizedDescription)") }
        }

        var focus = localFocus(chapters: chapters, actionsAndDecisions: actions)
        if let assistant, !chapterDigest.isEmpty {
            progress("distilling takeaways")
            do {
                focus = try await synthesizeFocus(
                    source: chapterDigest + "\n\nACTIONS AND DECISIONS\n" + actions,
                    assistant: assistant
                )
            } catch {
                errors.append("Focused takeaways failed: \(error.localizedDescription)")
            }
        }

        let report = ConversationReport(
            id: draft.id,
            title: "Conversation — \(draft.startedAt.formatted(date: .abbreviated, time: .shortened))",
            startedAt: draft.startedAt,
            endedAt: draft.endedAt,
            audioFiles: draft.chunks.map { "audio/\($0.lastPathComponent)" },
            diarization: transcript.diarization,
            overview: overview,
            actionsAndDecisions: actions,
            focus: focus,
            chapters: chapters,
            analyses: [:],
            processingErrors: errors
        )
        try save(report, in: draft.directory)
        let reportURL = try render(report, in: draft.directory)
        let manifest = SessionManifest(id: draft.id, startedAt: draft.startedAt, endedAt: draft.endedAt,
                                       state: errors.isEmpty ? "complete" : "complete_with_warnings",
                                       chunks: draft.chunks.map(\.lastPathComponent))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: draft.directory.appendingPathComponent("manifest.json"), options: .atomic)
        hardenFiles(in: draft.directory)
        return reportURL
    }

    static func analyze(
        sessionID: String,
        scope: String,
        assistant: Interpreter,
        storageKey: String? = nil
    ) async throws -> URL {
        let directory = SessionStore.root.appendingPathComponent(sessionID, isDirectory: true)
        return try await analyze(
            directory: directory, scope: scope, assistant: assistant, storageKey: storageKey
        )
    }

    /// Directory overload keeps the analysis transform testable without
    /// writing fixtures into the user's real ~/.listen library.
    static func analyze(
        directory: URL,
        scope: String,
        assistant: Interpreter,
        storageKey: String? = nil
    ) async throws -> URL {
        var report = try load(in: directory)
        let source: String
        if scope == "all" {
            source = report.chapters.flatMap(\.segments).map { "[\(formatTime($0.start))] \($0.speaker): \($0.text)" }
                .joined(separator: "\n")
        } else if let chapter = report.chapters.first(where: { $0.id == scope }) {
            source = chapter.segments.map { "[\(formatTime($0.start))] \($0.speaker): \($0.text)" }
                .joined(separator: "\n")
        } else {
            throw NSError(domain: "Listen", code: 2101,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown report section"])
        }
        let prompt = """
        Perform an exacting deep analysis of this spoken exchange. Work at both word level and metaphysical level: diction, syntax, metaphor, framing, presuppositions, omissions, speech acts, power/agency, emotional subtext, epistemic posture, values, identity claims, contradictions, and what the language reveals. Quote only short phrases from the supplied exchange as evidence. Separate observation from inference, assign confidence to inference, and do not diagnose people or invent context. End with alternative interpretations and questions worth revisiting.\n\n{text}
        """
        let analysis = try await withTimeout(120) { try await assistant.interpret(source, prompt: prompt) }
        report.analyses[storageKey ?? scope] = analysis
        try save(report, in: directory)
        let url = try render(report, in: directory)
        hardenFiles(in: directory)
        return url
    }

    static func refreshFocus(sessionID: String, assistant: Interpreter) async throws -> ConversationReport {
        let directory = SessionStore.root.appendingPathComponent(sessionID, isDirectory: true)
        return try await refreshFocus(directory: directory, assistant: assistant)
    }

    static func refreshFocus(directory: URL, assistant: Interpreter) async throws -> ConversationReport {
        var report = try load(in: directory)
        let digest = report.chapters.enumerated().map {
            "CHAPTER \($0.offset + 1): \($0.element.title)\n\($0.element.summary)"
        }.joined(separator: "\n\n")
        let source = digest + "\n\nACTIONS AND DECISIONS\n" + report.actionsAndDecisions
        report.focus = try await synthesizeFocus(source: source, assistant: assistant)
        try save(report, in: directory)
        _ = try render(report, in: directory)
        hardenFiles(in: directory)
        return report
    }

    static func loadReport(sessionID: String) throws -> ConversationReport {
        try load(in: SessionStore.root.appendingPathComponent(sessionID, isDirectory: true))
    }

    static func loadReports() -> [ConversationReport] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: SessionStore.root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return directories.compactMap { try? load(in: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func fallbackFocus(for report: ConversationReport) -> ConversationFocus {
        localFocus(chapters: report.chapters, actionsAndDecisions: report.actionsAndDecisions)
    }

    private static func save(_ report: ConversationReport, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }

    private static func load(in directory: URL) throws -> ConversationReport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConversationReport.self,
                                  from: Data(contentsOf: directory.appendingPathComponent("report.json")))
    }

    private static func synthesizeFocus(source: String, assistant: Interpreter) async throws -> ConversationFocus {
        let response = try await withTimeout(90) {
            try await assistant.interpret(source, prompt: """
            Turn this conversation into the user's practical briefing. Focus on what they need to remember or do after leaving the conversation, not a generic recap. Be faithful to the evidence and do not invent obligations, owners, dates, or certainty.

            Return exactly these three sections with concise bullet items:
            TAKEAWAYS
            - 3 to 7 durable insights, conclusions, tensions, or changes that matter
            NEXT MOVES
            - explicit or strongly supported next steps; include owner/timing only when stated
            OPEN QUESTIONS
            - unresolved questions, risks, missing information, or decisions still needed

            Use “None identified” when a section truly has no supported item. No preamble or closing text.\n\n{text}
            """)
        }
        return try parseFocus(response)
    }

    static func parseFocus(_ response: String) throws -> ConversationFocus {
        enum Section { case takeaways, nextMoves, openQuestions }
        var current: Section?
        var takeaways: [String] = []
        var nextMoves: [String] = []
        var openQuestions: [String] = []

        func append(_ value: String, to section: Section) {
            let item = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty, item.lowercased() != "none identified" else { return }
            switch section {
            case .takeaways: takeaways.append(item)
            case .nextMoves: nextMoves.append(item)
            case .openQuestions: openQuestions.append(item)
            }
        }

        for rawLine in response.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: ")).uppercased()
            if header == "TAKEAWAYS" { current = .takeaways; continue }
            if header == "NEXT MOVES" || header == "NEXT STEPS" { current = .nextMoves; continue }
            if header == "OPEN QUESTIONS" || header == "UNRESOLVED QUESTIONS" {
                current = .openQuestions; continue
            }
            guard let current, !line.isEmpty else { continue }
            if let match = line.range(of: #"^(?:[-*•]|\d+[.)])\s*"#, options: .regularExpression) {
                line.removeSubrange(match)
            }
            append(line, to: current)
        }
        let parsed = ConversationFocus(
            takeaways: Array(takeaways.prefix(8)),
            nextMoves: Array(nextMoves.prefix(8)),
            openQuestions: Array(openQuestions.prefix(8))
        )
        guard parsed.isUseful else {
            throw ProviderError.decode("assistant did not return structured takeaways")
        }
        return parsed
    }

    private static func localFocus(
        chapters: [ReportChapter], actionsAndDecisions: String
    ) -> ConversationFocus {
        let takeaways = chapters.prefix(6).map { chapter in
            let firstLine = chapter.summary.components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                ?? chapter.summary
            return "\(chapter.title): \(shorten(firstLine, limit: 220))"
        }
        var nextMoves: [String] = []
        var inActions = true
        for rawLine in actionsAndDecisions.components(separatedBy: .newlines) {
            let lowered = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered.hasPrefix("decisions") { inActions = false }
            guard inActions else { continue }
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("-") || line.hasPrefix("•") else { continue }
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { nextMoves.append(shorten(line, limit: 260)) }
        }
        var questions: [String] = []
        for chapter in chapters {
            for sentence in chapter.summary.components(separatedBy: .newlines) where sentence.contains("?") {
                questions.append(shorten(sentence.trimmingCharacters(in: .whitespacesAndNewlines), limit: 260))
            }
        }
        return ConversationFocus(
            takeaways: takeaways,
            nextMoves: Array(nextMoves.prefix(6)),
            openQuestions: Array(questions.prefix(5))
        )
    }

    private static func render(_ report: ConversationReport, in directory: URL) throws -> URL {
        let duration = max(0, report.endedAt.timeIntervalSince(report.startedAt))
        let chapterHTML = report.chapters.map { chapter in
            let rows = chapter.segments.map { segment in
                """
                <div class="exchange"><span class="time">\(escape(formatTime(segment.start)))</span><strong>\(escape(segment.speaker))</strong><p>\(escape(segment.text))</p></div>
                """
            }.joined(separator: "\n")
            let analysis = report.analyses[chapter.id].map {
                "<section class=\"analysis\"><h4>Deep analysis</h4><div class=\"prose\">\(escape($0))</div></section>"
            } ?? ""
            let analyzeURL = analysisURL(session: report.id, scope: chapter.id)
            return """
            <details class="chapter" id="\(escape(chapter.id))">
              <summary><span><small>\(escape(formatTime(chapter.start)))–\(escape(formatTime(chapter.end)))</small>\(escape(chapter.title))</span><span class="open">Open exchange ↓</span></summary>
              <div class="summary prose">\(escape(chapter.summary))</div>
              <a class="analyze" href="\(escape(analyzeURL))">Analyze this chapter word by word + metaphysically</a>
              \(analysis)
              <details class="transcript"><summary>Full underlying exchange (\(chapter.segments.count) turns)</summary>\(rows)</details>
            </details>
            """
        }.joined(separator: "\n")
        let audioHTML = report.audioFiles.enumerated().map {
            "<div class=\"audio\"><span>Part \($0.offset + 1)</span><audio controls preload=\"metadata\" src=\"\(escape($0.element))\"></audio></div>"
        }.joined(separator: "\n")
        let mindBranches = report.chapters.map {
            "<div class=\"branch\"><strong>\(escape($0.title))</strong><span>\(escape(shorten($0.summary, limit: 180)))</span></div>"
        }.joined(separator: "\n")
        let wholeAnalysis = report.analyses["all"].map {
            "<section class=\"card analysis\"><h2>Whole-conversation deep analysis</h2><div class=\"prose\">\(escape($0))</div></section>"
        } ?? ""
        let warningHTML = report.processingErrors.isEmpty ? "" : """
        <section class="warnings"><strong>Processing warnings</strong><div class="prose">\(escape(report.processingErrors.joined(separator: "\n")))</div></section>
        """
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(report.title))</title><style>
        :root{color-scheme:light dark;--bg:#0c0e13;--card:#151923;--soft:#202637;--ink:#f5f7fb;--muted:#9aa6bc;--accent:#6ee7d8;--line:#2a3244}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 80% -10%,#1e3650 0,transparent 35%),var(--bg);color:var(--ink);font:15px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}main{max-width:1040px;margin:auto;padding:56px 24px 100px}h1{font-size:42px;line-height:1.05;margin:.2em 0}.eyebrow,.time,small{color:var(--accent);text-transform:uppercase;letter-spacing:.08em;font-size:11px}.meta{color:var(--muted)}.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin:28px 0}.stat,.card,.chapter,.warnings{background:color-mix(in srgb,var(--card) 92%,transparent);border:1px solid var(--line);border-radius:16px;padding:20px}.stat strong{display:block;font-size:26px}.card{margin:18px 0}.prose{white-space:pre-wrap}.audio{display:flex;align-items:center;gap:16px;margin:10px 0}.audio span{width:60px;color:var(--muted)}audio{width:100%}.mind{display:grid;grid-template-columns:170px 1fr;align-items:stretch;gap:22px}.root{display:grid;place-items:center;border:1px solid var(--accent);border-radius:999px;font-weight:700}.branches{display:grid;gap:10px}.branch{position:relative;padding:12px 16px;background:var(--soft);border-radius:12px}.branch:before{content:"";position:absolute;left:-22px;top:50%;width:22px;border-top:1px solid var(--accent)}.branch span{display:block;color:var(--muted);font-size:13px}.chapter{margin:14px 0;padding:0;overflow:hidden}.chapter>summary{cursor:pointer;display:flex;justify-content:space-between;align-items:center;padding:20px;list-style:none}.chapter>summary span:first-child{display:grid;font-size:18px;font-weight:700}.open{color:var(--muted);font-size:12px}.summary{padding:4px 20px 20px}.analyze{display:inline-block;margin:0 20px 20px;color:var(--accent)}.analysis{border-left:3px solid var(--accent);margin:0 20px 20px;padding:14px 18px;background:var(--soft);border-radius:8px}.transcript{border-top:1px solid var(--line);padding:16px 20px}.transcript>summary{cursor:pointer;color:var(--muted)}.exchange{display:grid;grid-template-columns:70px 100px 1fr;gap:12px;padding:14px 0;border-bottom:1px solid var(--line)}.exchange p{margin:0}.warnings{border-color:#8a5d2b;color:#ffd7a1}@media(max-width:700px){.stats{grid-template-columns:1fr}.mind{grid-template-columns:1fr}.root{padding:20px}.exchange{grid-template-columns:60px 1fr}.exchange p{grid-column:1/-1}}
        </style></head><body><main>
        <div class="eyebrow">Listen · Local conversation record</div><h1>\(escape(report.title))</h1>
        <p class="meta">\(escape(report.startedAt.formatted(date: .complete, time: .shortened))) · \(escape(report.diarization))</p>
        <div class="stats"><div class="stat"><strong>\(escape(formatTime(duration)))</strong>duration</div><div class="stat"><strong>\(report.chapters.count)</strong>chapters</div><div class="stat"><strong>\(report.chapters.flatMap(\.segments).count)</strong>speaker turns</div></div>
        \(warningHTML)
        <section class="card"><h2>Overview</h2><div class="prose">\(escape(report.overview))</div></section>
        <section class="card"><h2>Actions & decisions</h2><div class="prose">\(escape(report.actionsAndDecisions))</div></section>
        <section class="card"><h2>Mind map</h2><div class="mind"><div class="root">Conversation</div><div class="branches">\(mindBranches)</div></div></section>
        <section class="card"><h2>Original audio</h2>\(audioHTML)</section>
        <section><h2>Chapter-by-chapter</h2><p class="meta">Open any chapter to drill into its complete underlying exchange.</p>\(chapterHTML)</section>
        <section class="card"><h2>Go deeper</h2><p>Ask Listen for a word-level and metaphysical reading of the entire exchange. Analysis is written back into this local report.</p><a class="analyze" href="\(escape(analysisURL(session: report.id, scope: "all")))">Analyze the whole conversation</a></section>
        \(wholeAnalysis)
        </main></body></html>
        """
        let url = directory.appendingPathComponent("report.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func chapterGroups(_ segments: [TranscriptSegment]) -> [[TranscriptSegment]] {
        guard !segments.isEmpty else { return [] }
        var result: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var chars = 0
        var start = segments[0].start
        for segment in segments {
            if !current.isEmpty && (segment.end - start >= 8 * 60 || chars + segment.text.count > 12_000) {
                result.append(current); current = []; chars = 0; start = segment.start
            }
            current.append(segment); chars += segment.text.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private static func localChapterTitle(index: Int, segments: [TranscriptSegment]) -> String {
        let words = segments.first(where: { $0.speaker != "System" })?.text
            .split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ") ?? ""
        return words.isEmpty ? "Chapter \(index + 1)" : "Chapter \(index + 1): \(words)"
    }

    private static func localSummary(_ segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "No speech was transcribed in this chapter." }
        let speakers = Set(segments.map(\.speaker)).sorted().joined(separator: ", ")
        let body = segments.prefix(8).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        return "Local fallback summary (configure an analysis provider for a deeper synthesis). Speakers: \(speakers).\n\n\(body)"
    }

    private static func localOverview(_ chapters: [ReportChapter]) -> String {
        guard !chapters.isEmpty else { return "No transcribed speech was available." }
        return chapters.map { "\($0.title)\n\(shorten($0.summary, limit: 500))" }.joined(separator: "\n\n")
    }

    private static func analysisURL(session: String, scope: String) -> String {
        var components = URLComponents()
        components.scheme = "listen"
        components.host = "analyze"
        components.queryItems = [URLQueryItem(name: "session", value: session), URLQueryItem(name: "scope", value: scope)]
        return components.url?.absoluteString ?? ""
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func shorten(_ value: String, limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "…"
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func hardenFiles(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try? FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        }
    }
}
