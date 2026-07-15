import AppKit
import Combine
import SwiftUI

@MainActor
final class NotesModel: ObservableObject {
    @Published var search = ""
    @Published private(set) var notes: [VoiceNote] = []
    @Published private(set) var graphStats = MemoryGraphStats(notes: 0, concepts: 0, relationships: 0)
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NoteStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var filtered: [VoiceNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.thought.localizedCaseInsensitiveContains(query) ||
            $0.response.localizedCaseInsensitiveContains(query) ||
            $0.kind.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh() {
        notes = NoteStore.shared.load()
        graphStats = NoteStore.shared.stats()
    }
}

struct NotesView: View {
    @StateObject private var model = NotesModel()
    let onOpenConversation: (String) -> Void

    init(onOpenConversation: @escaping (String) -> Void = { _ in }) {
        self.onOpenConversation = onOpenConversation
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen Notes").font(.title2).bold()
                    Text("Local memory graph · \(model.graphStats.concepts) concepts · \(model.graphStats.relationships) links")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.filtered.count)").foregroundStyle(.secondary)
                Button("Reveal Store") {
                    NSWorkspace.shared.activateFileViewerSelecting([NoteStore.ledgerURL])
                }
            }.padding(18)
            Divider()
            if model.notes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("No spoken notes yet").font(.title3).bold()
                    Text("Hold Left Command + Option for a Quick Thought, use the wake word, or record a conversation.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.filtered) { note in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(note.kind.rawValue).font(.caption).bold()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(note.thought).font(.body).textSelection(.enabled)
                        if !note.response.isEmpty {
                            Text(note.response).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let sessionID = note.sessionID ?? note.reportPath.map({
                            URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
                        }) {
                            Button("Open in Conversations") {
                                onOpenConversation(sessionID)
                            }
                            .buttonStyle(.link)
                        }
                    }.padding(.vertical, 8)
                }
                .searchable(text: $model.search, prompt: "Search everything you said")
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}
