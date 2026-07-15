import AppKit
import AVFoundation
import Combine
import SwiftUI

enum ConversationAnalysisSource: String, Sendable {
    case listen
    case hermes

    var title: String { self == .hermes ? "Hermes" : "Listen" }
}

@MainActor
final class ConversationLibraryModel: ObservableObject {
    @Published var search = ""
    @Published var selectedID: String?
    @Published private(set) var reports: [ConversationReport] = []
    @Published private(set) var busyLabel: String?
    @Published var errorMessage: String?

    private let onAnalyze: (String, String, ConversationAnalysisSource) -> Void
    private let onRefreshFocus: (String, ConversationAnalysisSource) -> Void

    init(
        selecting sessionID: String? = nil,
        onAnalyze: @escaping (String, String, ConversationAnalysisSource) -> Void,
        onRefreshFocus: @escaping (String, ConversationAnalysisSource) -> Void
    ) {
        self.onAnalyze = onAnalyze
        self.onRefreshFocus = onRefreshFocus
        refresh(selecting: sessionID)
    }

    var filteredReports: [ConversationReport] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return reports }
        return reports.filter { report in
            report.title.localizedCaseInsensitiveContains(query) ||
            report.overview.localizedCaseInsensitiveContains(query) ||
            report.actionsAndDecisions.localizedCaseInsensitiveContains(query) ||
            report.chapters.contains {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.summary.localizedCaseInsensitiveContains(query) ||
                $0.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
            }
        }
    }

    var selectedReport: ConversationReport? {
        guard let selectedID else { return reports.first }
        return reports.first(where: { $0.id == selectedID })
    }

    var isBusy: Bool { busyLabel != nil }

    func refresh(selecting requestedID: String? = nil) {
        reports = ConversationProcessor.loadReports()
        if let requestedID, reports.contains(where: { $0.id == requestedID }) {
            selectedID = requestedID
        } else if let selectedID, reports.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            selectedID = reports.first?.id
        }
    }

    func requestAnalysis(_ sessionID: String, scope: String, source: ConversationAnalysisSource) {
        guard !isBusy else { return }
        onAnalyze(sessionID, scope, source)
    }

    func requestFocus(_ sessionID: String, source: ConversationAnalysisSource) {
        guard !isBusy else { return }
        onRefreshFocus(sessionID, source)
    }

    func beginWork(_ label: String) {
        errorMessage = nil
        busyLabel = label
    }

    func finishWork(selecting sessionID: String, error: String? = nil) {
        busyLabel = nil
        refresh(selecting: sessionID)
        errorMessage = error
    }
}

struct ConversationLibraryView: View {
    @ObservedObject var model: ConversationLibraryModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Conversations").font(.headline)
                        Text("\(model.reports.count) local")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh library")
                }
                .padding(14)
                Divider()
                if model.reports.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("No conversations yet").font(.headline)
                        Text("Start a conversation recording from the Listen menu bar.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedID) {
                        ForEach(model.filteredReports) { report in
                            ConversationRow(report: report)
                                .tag(report.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .searchable(text: $model.search, prompt: "Search transcripts")
                }
            }
            .navigationSplitViewColumnWidth(min: 225, ideal: 270, max: 340)
        } detail: {
            if let report = model.selectedReport {
                ConversationDetailView(report: report, model: model)
                    .id(report.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Select a conversation").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .alert(
            "Conversation analysis failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

private struct ConversationRow: View {
    let report: ConversationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label(conversationDuration(report.endedAt.timeIntervalSince(report.startedAt)), systemImage: "clock")
                Label("\(report.chapters.count)", systemImage: "list.bullet.rectangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            let storedFocus = report.focus ?? ConversationProcessor.fallbackFocus(for: report)
            let focus = storedFocus.isUseful
                ? storedFocus
                : ConversationProcessor.fallbackFocus(for: report)
            if let first = focus.takeaways.first {
                Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ConversationDetailView: View {
    let report: ConversationReport
    @ObservedObject var model: ConversationLibraryModel
    @StateObject private var audio = ConversationAudioPlayer()

    private var focus: ConversationFocus {
        let value = report.focus ?? ConversationProcessor.fallbackFocus(for: report)
        return value.isUseful ? value : ConversationProcessor.fallbackFocus(for: report)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                focusCard
                if !focus.nextMoves.isEmpty { nextMovesCard }
                if !focus.openQuestions.isEmpty { openQuestionsCard }
                overviewCard
                mindMapCard
                audioCard
                chapters
                deepAnalysisCard
                if !report.processingErrors.isEmpty { warningsCard }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { audio.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("CONVERSATION")
                        .font(.caption).fontWeight(.semibold).tracking(1.1)
                        .foregroundStyle(Color.accentColor)
                    Text(report.title).font(.system(size: 30, weight: .bold, design: .rounded))
                    HStack(spacing: 15) {
                        Label(report.startedAt.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                        Label(conversationDuration(report.endedAt.timeIntervalSince(report.startedAt)), systemImage: "clock")
                        Label("\(report.chapters.flatMap(\.segments).count) turns", systemImage: "person.2")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 18)
                Menu {
                    Button("Reveal local session") { revealSession() }
                    Button("Reveal HTML export") { revealHTML() }
                } label: {
                    Label("Files", systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
            }
            if let busyLabel = model.busyLabel {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(busyLabel).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var focusCard: some View {
        reportCard(tint: .accentColor) {
            HStack {
                Label("What matters", systemImage: "scope")
                    .font(.title3).bold()
                Spacer()
                Menu {
                    Button("Refocus with Listen") {
                        model.requestFocus(report.id, source: .listen)
                    }
                    if HermesInterpreter.isAvailable {
                        Button("Refocus with Hermes Agent") {
                            model.requestFocus(report.id, source: .hermes)
                        }
                    }
                } label: {
                    Label("Refocus", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isBusy)
            }
            bulletList(focus.takeaways, empty: "No supported takeaways were extracted.")
        }
    }

    private var nextMovesCard: some View {
        reportCard(tint: .green) {
            Label("Next moves", systemImage: "checkmark.circle.fill")
                .font(.title3).bold()
            bulletList(focus.nextMoves, empty: "No next moves were identified.")
            DisclosureGroup("Decisions and source evidence") {
                Text(verbatim: report.actionsAndDecisions)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var openQuestionsCard: some View {
        reportCard(tint: .orange) {
            Label("Still unresolved", systemImage: "questionmark.bubble.fill")
                .font(.title3).bold()
            bulletList(focus.openQuestions, empty: "No unresolved questions were identified.")
        }
    }

    private var overviewCard: some View {
        reportCard {
            DisclosureGroup {
                Text(verbatim: report.overview)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            } label: {
                Label("Full synthesis", systemImage: "doc.text")
                    .font(.title3).bold()
            }
        }
    }

    private var mindMapCard: some View {
        reportCard {
            Label("Conversation map", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title3).bold()
            HStack(alignment: .center, spacing: 18) {
                Text("Conversation")
                    .font(.headline)
                    .padding(.horizontal, 17).padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.55)))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.chapters, id: \.id) { chapter in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.title).font(.callout).bold()
                            Text(shortConversationText(chapter.summary, limit: 155))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
    }

    private var audioCard: some View {
        reportCard {
            Label("Original audio", systemImage: "waveform")
                .font(.title3).bold()
            if report.audioFiles.isEmpty {
                Text("No audio files were recorded.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(report.audioFiles.enumerated()), id: \.offset) { index, path in
                    if let url = safeSessionURL(path) {
                        AudioPartRow(index: index, url: url, player: audio)
                    }
                }
            }
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Chapters and evidence").font(.title2).bold()
            Text("Open a chapter to move from the summary into the exact underlying exchange.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(report.chapters, id: \.id) { chapter in
                ChapterDisclosure(report: report, chapter: chapter, model: model)
            }
        }
    }

    private var deepAnalysisCard: some View {
        reportCard(tint: .purple) {
            Label("Deeper reading", systemImage: "sparkles")
                .font(.title3).bold()
            Text("Examine framing, diction, assumptions, emotional subtext, contradictions, and alternative interpretations while keeping observation separate from inference.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Analyze with Listen") {
                    model.requestAnalysis(report.id, scope: "all", source: .listen)
                }
                .buttonStyle(.borderedProminent)
                if HermesInterpreter.isAvailable {
                    Button("Ask Hermes Agent") {
                        model.requestAnalysis(report.id, scope: "all", source: .hermes)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(model.isBusy)
            analysisBlock(title: "Listen analysis", value: report.analyses["all"])
            analysisBlock(title: "Hermes analysis", value: report.analyses["hermes:all"])
        }
    }

    private var warningsCard: some View {
        reportCard(tint: .orange) {
            Label("Processing warnings", systemImage: "exclamationmark.triangle")
                .font(.headline)
            bulletList(report.processingErrors, empty: "")
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 7)
                        Text(verbatim: item).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func analysisBlock(title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            DisclosureGroup(title) {
                Text(verbatim: value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 9)
            }
            .padding(12)
            .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func reportCard<Content: View>(
        tint: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(tint.opacity(0.24), lineWidth: 1)
            )
    }

    private func safeSessionURL(_ relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        let directory = SessionStore.root.appendingPathComponent(report.id, isDirectory: true).standardizedFileURL
        let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(directory.path + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func revealSession() {
        let directory = SessionStore.root.appendingPathComponent(report.id, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func revealHTML() {
        let url = SessionStore.root.appendingPathComponent(report.id, isDirectory: true)
            .appendingPathComponent("report.html")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct ChapterDisclosure: View {
    let report: ConversationReport
    let chapter: ReportChapter
    @ObservedObject var model: ConversationLibraryModel
    @State private var expanded = false
    @State private var transcriptExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 13) {
                Text(verbatim: chapter.summary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Analyze with Listen") {
                        model.requestAnalysis(report.id, scope: chapter.id, source: .listen)
                    }
                    if HermesInterpreter.isAvailable {
                        Button("Ask Hermes") {
                            model.requestAnalysis(report.id, scope: chapter.id, source: .hermes)
                        }
                    }
                }
                .disabled(model.isBusy)
                chapterAnalysis(title: "Listen analysis", value: report.analyses[chapter.id])
                chapterAnalysis(title: "Hermes analysis", value: report.analyses["hermes:\(chapter.id)"])
                DisclosureGroup("Full exchange · \(chapter.segments.count) turns", isExpanded: $transcriptExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(chapter.segments) { segment in
                            TranscriptTurn(segment: segment)
                            if segment.id != chapter.segments.last?.id { Divider() }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.top, 13)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title).font(.headline)
                    Text("\(conversationDuration(chapter.start)) – \(conversationDuration(chapter.end))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(chapter.segments.count) turns")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.secondary.opacity(0.16)))
    }

    @ViewBuilder
    private func chapterAnalysis(title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            DisclosureGroup(title) {
                Text(verbatim: value).textSelection(.enabled).padding(.top, 8)
            }
            .padding(11)
            .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct TranscriptTurn: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(conversationDuration(segment.start))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(segment.speaker).font(.caption).bold().frame(width: 100, alignment: .leading)
            Text(verbatim: segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }
}

@MainActor
private final class ConversationAudioPlayer: ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if currentURL == url, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            isPlaying = player.isPlaying
            updateTimer()
            return
        }
        stop()
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.prepareToPlay()
            next.play()
            player = next
            currentURL = url
            duration = next.duration
            currentTime = 0
            isPlaying = true
            updateTimer()
        } catch {
            NSSound.beep()
        }
    }

    func seek(_ time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        timer?.invalidate()
        timer = nil
    }

    private func updateTimer() {
        timer?.invalidate()
        guard isPlaying else { timer = nil; return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
                if !player.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

private struct AudioPartRow: View {
    let index: Int
    let url: URL
    @ObservedObject var player: ConversationAudioPlayer

    private var selected: Bool { player.currentURL == url }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                player.toggle(url)
            } label: {
                Image(systemName: selected && player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 15)
            }
            .buttonStyle(.bordered)
            Text("Part \(index + 1)").font(.callout).bold().frame(width: 48, alignment: .leading)
            if selected {
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek($0) }),
                    in: 0...max(0.01, player.duration)
                )
                Text("\(conversationDuration(player.currentTime)) / \(conversationDuration(player.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .trailing)
            } else {
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private func conversationDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total >= 3_600 {
        return String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}

private func shortConversationText(_ value: String, limit: Int) -> String {
    let flattened = value.replacingOccurrences(of: "\n", with: " ")
    return flattened.count <= limit ? flattened : String(flattened.prefix(limit)) + "…"
}
