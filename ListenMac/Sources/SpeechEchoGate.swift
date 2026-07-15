import Foundation

/// Rejects recognition fragments that are overwhelmingly composed of the
/// assistant's current (or just-finished) spoken response. Acoustic echo
/// cancellation reduces speaker bleed, but cannot guarantee that macOS Speech
/// will not decode it; this second layer keeps that bleed out of the command
/// path while preserving unrelated barge-in speech.
final class SpeechEchoGate: @unchecked Sendable {
    private let lock = NSLock()
    private var responseWords: Set<String> = []
    private var speaking = false
    private var activeUntil = Date.distantPast

    func begin(_ response: String) {
        lock.lock()
        responseWords = Set(Self.words(in: response).map(\.normalized))
        speaking = true
        activeUntil = .distantFuture
        lock.unlock()
    }

    func end(settleTime: TimeInterval = 1.5) {
        lock.lock()
        speaking = false
        activeUntil = Date().addingTimeInterval(max(0, settleTime))
        lock.unlock()
    }

    /// Returns the usable portion of a candidate, or nil when the complete
    /// candidate is assistant echo. Leading echo can be removed while keeping
    /// a user's trailing interruption (for example, "… wait stop").
    func filtered(_ candidate: String) -> String? {
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !clean.isEmpty else { return nil }

        lock.lock()
        let active = speaking || Date() < activeUntil
        let reference = responseWords
        lock.unlock()
        guard active, !reference.isEmpty else { return clean }

        let tokens = Self.words(in: clean)
        guard !tokens.isEmpty else { return nil }
        let protectedCommands: Set<String> = [
            "stop", "cancel", "goodbye", "bye", "wait", "quiet", "nevermind",
        ]
        if let first = tokens.first?.normalized, protectedCommands.contains(first) {
            return clean
        }

        let matches = tokens.filter { reference.contains($0.normalized) }.count
        var leadingEcho = 0
        for token in tokens {
            guard reference.contains(token.normalized),
                  !protectedCommands.contains(token.normalized) else { break }
            leadingEcho += 1
        }

        let mostlyEcho = matches >= 2 && Double(matches) / Double(tokens.count) >= 0.55
        let singleDistinctEcho = tokens.count == 1
            && matches == 1
            && (tokens.first?.normalized.count ?? 0) >= 5
        guard mostlyEcho || singleDistinctEcho || leadingEcho >= 3 else { return clean }

        guard leadingEcho < tokens.count else { return nil }
        let remainder = tokens.dropFirst(leadingEcho).map(\.original).joined(separator: " ")
        return remainder.isEmpty ? nil : remainder
    }

    private struct Word {
        let original: String
        let normalized: String
    }

    private static func words(in text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let original = String(raw).trimmingCharacters(in: .punctuationCharacters)
            let normalized = original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == "'" }
            guard !normalized.isEmpty else { return nil }
            return Word(original: original, normalized: normalized)
        }
    }
}
