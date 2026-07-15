import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Interruptible xAI TTS using the same custom voice as the retired voice
/// daemon. System synthesis remains an offline fallback, not the normal path.
@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var requestTask: Task<Void, Never>?
    private var systemUtterance: AVSpeechUtterance?
    private var playbackID = UUID()
    private var provider = "xai"
    private var xaiAPIKey = ""
    private var xaiVoiceID = "o79hvd0m"
    private(set) var isSpeaking = false
    let echoGate = SpeechEchoGate()
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func configure(_ settings: AppSettings) {
        provider = settings.tts_provider
        xaiAPIKey = settings.xai_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = settings.xai_voice_id.trimmingCharacters(in: .whitespacesAndNewlines)
        xaiVoiceID = voice.isEmpty ? "o79hvd0m" : voice
    }

    func speak(_ text: String, enabled: Bool) {
        stop()
        let cleaned = Self.clean(text)
        guard enabled, !cleaned.isEmpty else {
            echoGate.end(settleTime: 0)
            onFinish?()
            return
        }
        echoGate.begin(cleaned)
        isSpeaking = true
        let id = UUID()
        playbackID = id

        if provider == "xai", !xaiAPIKey.isEmpty {
            startXAI(cleaned, id: id)
        } else {
            if provider == "xai" { listenLog("xAI TTS key missing; using system fallback") }
            startSystem(cleaned)
        }
    }

    private func startXAI(_ text: String, id: UUID) {
        let request: URLRequest
        do {
            request = try XAITTSRequestBuilder.make(text: text, voiceID: xaiVoiceID, apiKey: xaiAPIKey)
        } catch {
            listenLog("xAI TTS request error; using system fallback")
            startSystem(text)
            return
        }
        let voice = xaiVoiceID
        let startedAt = Date()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard self.playbackID == id else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    listenLog("xAI TTS status=\(status); using system fallback")
                    self.requestTask = nil
                    self.startSystem(text)
                    return
                }
                let audio = try AVAudioPlayer(data: data, fileTypeHint: "public.mp3")
                guard self.playbackID == id else { return }
                audio.delegate = self
                audio.prepareToPlay()
                guard audio.play() else {
                    throw NSError(domain: "Listen", code: 3001,
                                  userInfo: [NSLocalizedDescriptionKey: "xAI audio playback did not start"])
                }
                self.player = audio
                self.requestTask = nil
                let latency = Int(Date().timeIntervalSince(startedAt) * 1_000)
                listenLog("xAI TTS ready voice=\(voice) latency_ms=\(latency) bytes=\(data.count)")
            } catch is CancellationError {
                return
            } catch {
                guard self.playbackID == id, !Task.isCancelled else { return }
                self.requestTask = nil
                listenLog("xAI TTS failed error=\(error.localizedDescription); using system fallback")
                self.startSystem(text)
            }
        }
    }

    private func startSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.51
        utterance.pitchMultiplier = 0.98
        utterance.preUtteranceDelay = 0.04
        systemUtterance = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        guard isSpeaking || requestTask != nil || player?.isPlaying == true || synthesizer.isSpeaking else { return }
        playbackID = UUID()
        requestTask?.cancel()
        requestTask = nil
        player?.stop()
        player = nil
        systemUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        echoGate.end()
    }

    private func finishNaturally() {
        requestTask = nil
        player = nil
        systemUtterance = nil
        guard isSpeaking else { return }
        isSpeaking = false
        echoGate.end()
        onFinish?()
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\*+([^*]+)\*+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"#+\s"#, with: "", options: .regularExpression)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let current = self.systemUtterance,
                  ObjectIdentifier(current) == utteranceID else { return }
            self.finishNaturally()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let current = self.systemUtterance,
                  ObjectIdentifier(current) == utteranceID else { return }
            self.systemUtterance = nil
            self.isSpeaking = false
            self.echoGate.end()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player,
                  ObjectIdentifier(current) == playerID else { return }
            self.finishNaturally()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let playerID = ObjectIdentifier(player)
        let message = error?.localizedDescription ?? "unknown"
        Task { @MainActor [weak self] in
            guard let self, let current = self.player,
                  ObjectIdentifier(current) == playerID else { return }
            listenLog("xAI TTS playback decode error=\(message)")
            self.finishNaturally()
        }
    }
}

private struct VoiceResponseView: View {
    let heading: String
    let thought: String
    let answer: String
    let compact: Bool
    let onDismiss: () -> Void

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                Image(systemName: "waveform.circle.fill").foregroundStyle(.tint)
                Text(heading).font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer()
                if compact {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss Quick Thought")
                }
            }
            if !thought.isEmpty {
                Text(thought)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3)
            }
            Text(answer)
                .font(compact ? .callout : .body)
                .lineLimit(compact ? 6 : nil)
                .textSelection(.enabled)
        }
        .padding(compact ? 12 : 18)
        .frame(width: compact ? 320 : 440, alignment: .leading)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                    }
            }
        }
        .contentShape(Rectangle())
        .offset(dragOffset)
        .opacity(compact ? max(0.35, 1 - abs(dragOffset.width) / 220) : 1)
        .modifier(DragDismissModifier(enabled: compact, offset: $dragOffset, onDismiss: onDismiss))
        .accessibilityHint(compact ? "Swipe in any direction to dismiss" : "")
    }
}

/// Mouse/trackpad click-drag fallback. Native two-finger trackpad scrolling is
/// handled by SwipeDismissPanel below because it arrives as scroll-wheel
/// phases rather than as a SwiftUI DragGesture on macOS.
private struct DragDismissModifier: ViewModifier {
    let enabled: Bool
    @Binding var offset: CGSize
    let onDismiss: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.highPriorityGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { offset = $0.translation }
                    .onEnded { value in
                        let travel = max(abs(value.translation.width), abs(value.translation.height))
                        let predicted = max(
                            abs(value.predictedEndTranslation.width),
                            abs(value.predictedEndTranslation.height)
                        )
                        if max(travel, predicted) >= 64 {
                            onDismiss()
                        } else {
                            withAnimation(.snappy(duration: 0.18)) { offset = .zero }
                        }
                    }
            )
        } else {
            content
        }
    }
}

/// A non-activating panel that understands a real two-finger trackpad swipe.
/// There is no scrollable content in the compact card, so a deliberate precise
/// scroll gesture can be used as its dismissal gesture without stealing focus.
@MainActor
private final class SwipeDismissPanel: NSPanel {
    private var swipeDismissEnabled = false
    var onSwipeDismiss: (() -> Void)?
    private var accumulatedSwipe = CGSize.zero
    private var dismissalRequested = false
    private var pointerDragOrigin: NSPoint?

    func prepareForPresentation(swipeDismissEnabled: Bool) {
        self.swipeDismissEnabled = swipeDismissEnabled
        accumulatedSwipe = .zero
        pointerDragOrigin = nil
        dismissalRequested = false
    }

    override func sendEvent(_ event: NSEvent) {
        if swipeDismissEnabled {
            switch event.type {
            case .leftMouseDown:
                pointerDragOrigin = event.locationInWindow
            case .leftMouseDragged:
                if let origin = pointerDragOrigin {
                    let location = event.locationInWindow
                    if max(abs(location.x - origin.x), abs(location.y - origin.y)) >= 64 {
                        requestSwipeDismiss()
                        return
                    }
                }
            case .leftMouseUp:
                pointerDragOrigin = nil
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard swipeDismissEnabled, event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began {
            accumulatedSwipe = .zero
            dismissalRequested = false
        }
        accumulatedSwipe.width += event.scrollingDeltaX
        accumulatedSwipe.height += event.scrollingDeltaY
        if max(abs(accumulatedSwipe.width), abs(accumulatedSwipe.height)) >= 48 {
            requestSwipeDismiss()
            return
        }
        if event.phase == .ended || event.phase == .cancelled {
            accumulatedSwipe = .zero
        }
    }

    override func swipe(with event: NSEvent) {
        guard swipeDismissEnabled else {
            super.swipe(with: event)
            return
        }
        requestSwipeDismiss()
    }

    private func requestSwipeDismiss() {
        guard !dismissalRequested else { return }
        dismissalRequested = true
        onSwipeDismiss?()
    }
}

/// Small non-modal visible answer surface; it never steals the target app's
/// keyboard focus (critical for the dictation paste path).
@MainActor
final class VoiceResponsePresenter {
    private var panel: SwipeDismissPanel?
    private var dismissWork: DispatchWorkItem?

    func show(heading: String, thought: String, answer: String, compact: Bool = false) {
        dismissCurrent()
        let host = NSHostingController(rootView: VoiceResponseView(
            heading: heading,
            thought: thought,
            answer: answer,
            compact: compact,
            onDismiss: { [weak self] in self?.dismissCurrent() }
        ))
        let panel: SwipeDismissPanel
        if let reusable = self.panel {
            panel = reusable
            panel.contentViewController = host
        } else {
            panel = SwipeDismissPanel(contentViewController: host)
            self.panel = panel
        }
        panel.styleMask = compact
            ? [.borderless, .nonactivatingPanel]
            : [.titled, .nonactivatingPanel, .fullSizeContentView]
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.title = compact ? "Quick Thought" : "Listen response"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Compact-card drags belong to the dismissal gesture. Letting AppKit
        // interpret the same drag as window movement makes swipe recognition
        // intermittent depending on where the gesture begins.
        panel.isMovableByWindowBackground = !compact
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Keep one reusable panel alive. Releasing an NSPanel from inside its
        // own SwiftUI/trackpad event callback can over-release AppKit state on
        // macOS; orderOut is immediate, safe, and avoids per-response windows.
        panel.isReleasedWhenClosed = false
        panel.prepareForPresentation(swipeDismissEnabled: compact)
        panel.onSwipeDismiss = { [weak self] in self?.dismissCurrent() }
        panel.isOpaque = !compact
        panel.backgroundColor = compact ? .clear : .windowBackgroundColor
        panel.hasShadow = true
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = compact ? 14 : 0
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = compact
        panel.setContentSize(host.view.fittingSize)
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - frame.width - (compact ? 18 : 24),
                y: screen.visibleFrame.maxY - frame.height - (compact ? 18 : 24)
            ))
        }
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self, panel] in
            guard let self, self.panel === panel else { return }
            self.dismissCurrent()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func dismissCurrent() {
        dismissWork?.cancel()
        dismissWork = nil
        guard let closingPanel = panel else { return }
        closingPanel.onSwipeDismiss = nil
        closingPanel.orderOut(nil)
    }
}
