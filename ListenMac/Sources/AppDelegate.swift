import AppKit
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, listening, thinking }
    private enum CaptureMode { case dictation, quickThought, microphoneTest }

    private var statusItem: NSStatusItem!
    private let hotkey = Hotkey()
    private let recorder = Recorder()
    private let conversationRecorder = ConversationRecorder()
    private let wakeWord = WakeWordController()
    private let speaker = SpeechSpeaker()
    private let responsePresenter = VoiceResponsePresenter()
    private var settings = SettingsStore.load()
    private var stt: STTProvider?
    private var interpreter: Interpreter?
    private var assistant: Interpreter?

    private var settingsWindow: NSWindow?
    private var notesWindow: NSWindow?
    private var conversationsWindow: NSWindow?
    private var conversationsModel: ConversationLibraryModel?
    private var state: State = .idle {
        didSet {
            if state != .idle { transientMessage = nil }
            renderStatus()
        }
    }
    private var captureMode: CaptureMode?
    private var transientMessage: String?
    private var backgroundStatus: String?
    private var wakeActive = false
    private var statusAnimation: Timer?
    private var animationPhase: Double = 0

    /// In-flight short capture; a new hotkey press supersedes it.
    private var processTask: Task<Void, Never>?
    /// Wake assistant work is independent so dictation can always cancel it.
    private var assistantTask: Task<Void, Never>?
    private var activeReportProcesses = 0
    private var session = 0
    private var voiceSession = 0
    private var autoStopWork: DispatchWorkItem?
    private var recordStart: Date?

    private static let maxRecordingSeconds: Double = 180
    private static let minRecordingSeconds: Double = 0.3
    /// A compact menu-bar font preserves the full word while reclaiming enough
    /// horizontal space for macOS's microphone privacy item on notched screens.
    /// The fixed slot remains the same width at idle, so recording never asks
    /// AppKit to expand the item at the exact moment the privacy item arrives.
    private static let statusFont: NSFont = {
        let base = NSFont.menuBarFont(ofSize: 12)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.condensed)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }()
    /// A stable autosave identity lets AppKit preserve the user's Cmd-dragged
    /// order. On first launch, ordinal position zero anchors Listen beside the
    /// Control Center end instead of leaving it as the first item evicted when
    /// macOS inserts its 48-point microphone privacy module.
    private static let statusAutosaveName = "Listen_Status_v1"
    private static var statusPreferredPositionKey: String {
        "NSStatusItem Preferred Position \(statusAutosaveName)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        listenLog("startup version=\(version)")
        listenLog("speech authorization=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        reloadProviders()
        speaker.configure(settings)
        configureWakeCallbacks()
        startHotkey()
        ensurePermissionsOnFirstRun()
        observeWake()
        prewarmConnections(includeAssistant: false)
        Task.detached(priority: .utility) {
            let stats = NoteStore.shared.stats()
            listenLog("memory ready notes=\(stats.notes) concepts=\(stats.concepts) relationships=\(stats.relationships)")
        }
        if settings.wake_word_enabled { enableWakeWord() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        wakeWord.stop()
        recorder.discard()
        speaker.stop()
        NoteStore.shared.flush()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "listen", url.host == "analyze" { handleAnalysisURL(url) }
            else if url.scheme == "listen", url.host == "show", url.path == "/preferences" { showPrefs() }
            else if url.scheme == "listen", url.host == "show", url.path == "/notes" { showNotes() }
            else if url.scheme == "listen", url.host == "show", url.path == "/conversations" {
                showConversations(selecting: nil)
            }
            // Background-safe automation/document handoff path. Listen is not
            // registered as an https handler; these arrive only when another
            // process explicitly hands the URL to this bundle.
            else if url.scheme == "https", url.host == "listen.local", url.path == "/preferences" { showPrefs() }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/notes" { showNotes() }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/conversations" {
                showConversations(selecting: nil)
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/analyze" {
                handleAnalysisURL(url)
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/test/microphone" {
                runTimedCapture(.microphoneTest, seconds: 3)
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/test/dictation" {
                runTimedCapture(.dictation, seconds: 4)
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/test/quick-thought" {
                runTimedCapture(.quickThought, seconds: 4)
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/test/voice" {
                speaker.speak("Listen is now using the xAI voice.", enabled: settings.tts_enabled)
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/test/quick-thought-popup" {
                responsePresenter.show(
                    heading: "Quick Thought",
                    thought: "A small surface should stay out of the way.",
                    answer: "Captured. Swipe this card away in any direction.",
                    compact: true
                )
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/conversation/start",
                    !conversationRecorder.isRecording {
                startConversationRecording()
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/conversation/stop",
                    conversationRecorder.isRecording {
                stopConversationRecording()
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/wake/test-if-authorized" {
                if SFSpeechRecognizer.authorizationStatus() == .authorized {
                    settings.wake_word_enabled = true
                    SettingsStore.save(settings)
                    enableWakeWord()
                } else {
                    listenLog("wake runtime test skipped; speech authorization is not granted")
                }
            }
            else if url.scheme == "https", url.host == "listen.local", url.path == "/wake/disable" {
                settings.wake_word_enabled = false
                SettingsStore.save(settings)
                disableWakeWord()
                rebuildMenu()
            }
        }
    }

    // MARK: - Status bar

    private func buildStatusItem() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.statusPreferredPositionKey) == nil {
            // AppKit recognizes 0 and 1 as right-edge ordinal seeds. This must
            // exist before the status item is created; assigning it afterward
            // is too late for the initial WindowServer layout.
            defaults.set(0.0, forKey: Self.statusPreferredPositionKey)
            defaults.synchronize()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemWidth)
        statusItem.autosaveName = Self.statusAutosaveName
        statusItem.isVisible = true
        listenLog("status item preferred_position=\(defaults.double(forKey: Self.statusPreferredPositionKey)) width=\(Int(statusItemWidth))")
        renderStatus()
        statusItem.menu = buildMenu()
    }

    private var isVisuallyActive: Bool {
        state != .idle || wakeActive || conversationRecorder.isRecording || backgroundStatus != nil
    }

    private var statusItemWidth: CGFloat {
        StatusAppearance.itemLength(font: Self.statusFont, padding: settings.menubar_text_padding)
    }

    private var isMicrophoneActiveForStatus: Bool {
        state == .listening || wakeActive || conversationRecorder.isRecording
    }

    /// Make microphone ownership explicit while keeping provider/transcription
    /// work distinct: once the mic closes, the label returns to Listen even if
    /// a response is still being processed.
    private func statusText() -> String {
        isMicrophoneActiveForStatus ? "listening" : "Listen"
    }

    /// Animates the actual menubar glyph color using attributedTitle. This is
    /// lightweight (10 fps, main run loop) and stops completely when idle.
    private func renderStatus() {
        guard statusItem != nil, let button = statusItem.button else { return }
        if isVisuallyActive {
            if statusAnimation == nil {
                let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.paintStatus() }
                }
                RunLoop.main.add(timer, forMode: .common)
                statusAnimation = timer
                listenLog("status animation started title=\(statusText())")
            }
        } else {
            if statusAnimation != nil { listenLog("status animation stopped title=\(statusText())") }
            statusAnimation?.invalidate()
            statusAnimation = nil
            animationPhase = 0
        }
        paintStatus(button: button)
    }

    private func paintStatus(button explicitButton: NSStatusBarButton? = nil) {
        guard let button = explicitButton ?? statusItem?.button else { return }
        // Listen is a text status item. Clear both image slots on every paint
        // so AppKit, state restoration, or a future refactor cannot substitute
        // a glyph while the microphone is active.
        button.image = nil
        button.alternateImage = nil
        button.imagePosition = .noImage
        button.alignment = .center
        statusItem.isVisible = true
        statusItem.length = statusItemWidth
        if isVisuallyActive {
            animationPhase = (animationPhase + 0.014 * StatusAppearance.speed(settings.menubar_animation_speed))
                .truncatingRemainder(dividingBy: 1)
            button.attributedTitle = StatusAppearance.attributedTitle(
                statusText(),
                font: Self.statusFont,
                styleName: settings.menubar_color_style,
                phase: animationPhase,
                intensity: settings.menubar_color_intensity
            )
        } else {
            button.attributedTitle = NSAttributedString(
                string: statusText(),
                attributes: [.foregroundColor: NSColor.labelColor, .font: Self.statusFont, .kern: 0.05]
            )
        }
        button.toolTip = accessibilityStatus
    }

    private var accessibilityStatus: String {
        var parts: [String] = []
        if let transientMessage { parts.append(transientMessage) }
        if wakeActive { parts.append("wake word enabled") }
        if conversationRecorder.isRecording { parts.append("recording conversation") }
        if state == .listening { parts.append(captureMode == .quickThought ? "capturing quick thought" : "dictating") }
        if state == .thinking { parts.append(captureMode == .quickThought ? "reflecting" : "transcribing") }
        if let backgroundStatus { parts.append(backgroundStatus) }
        return parts.isEmpty ? "Listen is idle" : "Listen: " + parts.joined(separator: ", ")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(showPrefs), keyEquivalent: ",")
        prefs.target = self; menu.addItem(prefs)
        let conversations = NSMenuItem(
            title: "Open Conversations", action: #selector(showConversationsFromMenu), keyEquivalent: "c"
        )
        conversations.target = self; menu.addItem(conversations)
        let notes = NSMenuItem(title: "Open Notes", action: #selector(showNotes), keyEquivalent: "n")
        notes.target = self; menu.addItem(notes)
        let sessions = NSMenuItem(title: "Reveal Conversation Sessions", action: #selector(revealSessions), keyEquivalent: "")
        sessions.target = self; menu.addItem(sessions)
        menu.addItem(.separator())

        let thought = NSMenuItem(title: "Quick Thought: hold Left ⌘ + ⌥", action: nil, keyEquivalent: "")
        thought.isEnabled = false; menu.addItem(thought)
        let wake = NSMenuItem(title: "Wake Word — “\(settings.wake_word_phrase)”", action: #selector(toggleWakeWord), keyEquivalent: "")
        wake.target = self; wake.state = settings.wake_word_enabled ? .on : .off; menu.addItem(wake)
        let conversation = NSMenuItem(
            title: conversationRecorder.isRecording ? "Stop & Process Conversation" : "Start Conversation Recording",
            action: #selector(toggleConversationRecording), keyEquivalent: ""
        )
        conversation.target = self
        conversation.state = conversationRecorder.isRecording ? .on : .off
        menu.addItem(conversation)
        menu.addItem(.separator())

        let test = NSMenuItem(title: "Test Dictation Recording (3s)", action: #selector(testRecord), keyEquivalent: "")
        test.target = self; menu.addItem(test)
        let reveal = NSMenuItem(title: "Reveal Config File", action: #selector(revealConfig), keyEquivalent: "")
        reveal.target = self; menu.addItem(reveal)
        let grant = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
        grant.target = self; menu.addItem(grant)
        let chime = NSMenuItem(title: "Chime on Record", action: #selector(toggleChime), keyEquivalent: "")
        chime.target = self; chime.state = settings.sound_enabled ? .on : .off; menu.addItem(chime)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Listen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func rebuildMenu() {
        statusItem.menu = buildMenu()
        renderStatus()
    }

    // MARK: - Providers / lifecycle

    private func reloadProviders() {
        do { stt = try ProviderFactory.stt(settings) }
        catch { stt = nil; NSLog("[Listen] stt init failed: \(error.localizedDescription)") }
        do { interpreter = try ProviderFactory.interpreter(settings) }
        catch { interpreter = nil; NSLog("[Listen] cleanup init failed: \(error.localizedDescription)") }
        do { assistant = try ProviderFactory.assistant(settings) }
        catch { assistant = nil; NSLog("[Listen] assistant init failed: \(error.localizedDescription)") }
    }

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.beginCapture(.dictation) }
        hotkey.onRelease = { [weak self] in self?.endCapture() }
        hotkey.onCancel = { [weak self] in self?.cancelCapture() }
        hotkey.onQuickThoughtPress = { [weak self] in self?.beginCapture(.quickThought) }
        hotkey.onQuickThoughtRelease = { [weak self] in self?.endCapture() }
        hotkey.start(keyName: settings.hotkey)
    }

    private func providerHosts(includeAssistant: Bool) -> [String] {
        var hosts: Set<String> = []
        switch settings.stt_provider {
        case "elevenlabs": hosts.insert("https://api.elevenlabs.io")
        case "openai": hosts.insert("https://api.openai.com")
        case "groq": hosts.insert("https://api.groq.com")
        default: break
        }
        if settings.cleanup_enabled || includeAssistant {
            switch settings.interpreter_provider {
            case "openai": hosts.insert("https://api.openai.com")
            case "groq": hosts.insert("https://api.groq.com")
            case "openrouter": hosts.insert("https://openrouter.ai")
            default: break
            }
        }
        if includeAssistant && settings.tts_enabled && settings.tts_provider == "xai" {
            hosts.insert("https://api.x.ai")
        }
        return Array(hosts)
    }

    private func prewarmConnections(includeAssistant: Bool) {
        for host in providerHosts(includeAssistant: includeAssistant) {
            guard let url = URL(string: host) else { continue }
            Task.detached {
                var req = URLRequest(url: url); req.httpMethod = "HEAD"; req.timeoutInterval = 5
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hotkey.start(keyName: self.settings.hotkey)
                if self.settings.wake_word_enabled {
                    self.wakeWord.update(phrase: self.settings.wake_word_phrase,
                                         conversationTimeout: self.settings.wake_conversation_timeout)
                }
            }
        }
    }

    private func ensurePermissionsOnFirstRun() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        NSLog("[Listen] startup: AXIsProcessTrusted = \(AXIsProcessTrusted())")
    }

    // MARK: - Settings and windows

    @objc private func showPrefs() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let model = SettingsModel(
            settings,
            conversationRecording: conversationRecorder.isRecording,
            onSave: { [weak self] new in self?.applySettings(new) },
            onMicrophoneTest: { [weak self] in self?.runTimedCapture(.microphoneTest, seconds: 3) },
            onQuickThoughtTest: { [weak self] in self?.runTimedCapture(.quickThought, seconds: 4) },
            onToggleConversation: { [weak self] in
                guard let self else { return false }
                self.toggleConversationRecording()
                return self.conversationRecorder.isRecording
            }
        )
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Listen — Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 760, height: 560)); window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func applySettings(_ new: AppSettings) {
        let old = settings
        settings = new
        SettingsStore.save(new)
        reloadProviders()
        speaker.configure(new)
        if old.hotkey != new.hotkey { hotkey.start(keyName: new.hotkey) }
        if old.wake_word_enabled != new.wake_word_enabled {
            new.wake_word_enabled ? enableWakeWord() : disableWakeWord()
        } else if new.wake_word_enabled &&
                    (old.wake_word_phrase != new.wake_word_phrase ||
                     old.wake_conversation_timeout != new.wake_conversation_timeout) {
            wakeWord.update(phrase: new.wake_word_phrase,
                            conversationTimeout: new.wake_conversation_timeout)
        }
        rebuildMenu()
    }

    @objc private func showNotes() {
        if let window = notesWindow {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let host = NSHostingController(rootView: NotesView { [weak self] sessionID in
            self?.showConversations(selecting: sessionID)
        })
        let window = NSWindow(contentViewController: host)
        window.title = "Listen Notes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 600)); window.center()
        window.isReleasedWhenClosed = false
        notesWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showConversationsFromMenu() {
        showConversations(selecting: nil)
    }

    private func showConversations(selecting sessionID: String?) {
        if let model = conversationsModel, let window = conversationsWindow {
            model.refresh(selecting: sessionID)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            enrichLegacyConversationIfNeeded(model.selectedReport)
            return
        }
        let model = ConversationLibraryModel(
            selecting: sessionID,
            onAnalyze: { [weak self] sessionID, scope, source in
                self?.runConversationAnalysis(sessionID: sessionID, scope: scope, source: source)
            },
            onRefreshFocus: { [weak self] sessionID, source in
                self?.runConversationFocus(sessionID: sessionID, source: source)
            }
        )
        let host = NSHostingController(rootView: ConversationLibraryView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Listen Conversations"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1_100, height: 760))
        window.center()
        window.isReleasedWhenClosed = false
        conversationsModel = model
        conversationsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        enrichLegacyConversationIfNeeded(model.selectedReport)
    }

    private func enrichLegacyConversationIfNeeded(_ report: ConversationReport?) {
        guard let report, report.focus?.isUseful != true, assistant != nil,
              conversationsModel?.isBusy == false else { return }
        runConversationFocus(sessionID: report.id, source: .listen)
    }

    @objc private func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.url]) }
    @objc private func revealSessions() { NSWorkspace.shared.open(SessionStore.root) }

    @objc private func toggleChime() {
        settings.sound_enabled.toggle(); SettingsStore.save(settings); rebuildMenu()
    }

    @objc private func grantAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Dictation and Quick Thought

    @objc private func testRecord() {
        runTimedCapture(.microphoneTest, seconds: 3)
    }

    private func runTimedCapture(_ mode: CaptureMode, seconds: TimeInterval) {
        beginCapture(mode)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.endCapture() }
    }

    private func beginCapture(_ mode: CaptureMode) {
        // Dictation always wins over an assistant response or older pipeline.
        if state == .thinking {
            processTask?.cancel(); processTask = nil; state = .idle
        }
        guard state == .idle else { return }
        guard stt != nil else { notify("No STT provider configured — open Preferences."); return }
        assistantTask?.cancel(); assistantTask = nil
        voiceSession &+= 1
        speaker.stop()
        backgroundStatus = nil
        if settings.wake_word_enabled { wakeWord.returnToWake() }

        session &+= 1
        listenLog("capture begin id=\(session) mode=\(mode)")
        captureMode = mode
        state = .listening
        recordStart = Date()
        prewarmConnections(includeAssistant: mode == .quickThought)
        playChime("Tink")
        do { try recorder.start() }
        catch {
            state = .idle; captureMode = nil
            notify("Mic error: \(error.localizedDescription)")
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .listening else { return }
            self.endCapture(); self.notify("Recording capped at \(Int(Self.maxRecordingSeconds))s")
        }
        autoStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingSeconds, execute: work)
    }

    private func cancelCapture() {
        guard state == .listening else { return }
        autoStopWork?.cancel(); autoStopWork = nil
        recorder.discard()
        session &+= 1
        captureMode = nil
        state = .idle
        listenLog("capture cancelled for chord transition")
        NSLog("[Listen] short capture cancelled for chord transition")
    }

    private func endCapture() {
        guard state == .listening, let mode = captureMode else { return }
        autoStopWork?.cancel(); autoStopWork = nil
        playChime("Pop")
        if let start = recordStart, Date().timeIntervalSince(start) < Self.minRecordingSeconds {
            recorder.discard(); captureMode = nil; state = .idle
            NSLog("[Listen] release: tap under \(Self.minRecordingSeconds)s, discarded")
            return
        }
        state = .thinking
        let id = session
        listenLog("capture end id=\(id) mode=\(mode); finalizing")
        processTask = Task {
            let url = await recorder.stop()
            await processCapture(url, mode: mode, session: id)
        }
    }

    private func processCapture(_ url: URL?, mode: CaptureMode, session id: Int) async {
        defer {
            if id == session, state == .thinking { state = .idle; captureMode = nil }
        }
        guard let url, let stt else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? -1
        listenLog("capture process id=\(id) bytes=\(size) mode=\(mode)")
        NSLog("[Listen] capture: audio=\(url.lastPathComponent) bytes=\(size) mode=\(mode)")
        let t0 = Date()
        do {
            let raw = try await transcribeWithRetry(stt, url)
            var text = raw
            if mode == .dictation, let interpreter, !raw.isEmpty {
                do {
                    let cleaned = try await withTimeout(5) {
                        try await interpreter.interpret(raw, prompt: self.settings.cleanup_prompt)
                    }
                    text = cleaned.isEmpty ? raw : cleaned
                } catch { NSLog("[Listen] cleanup failed: \(error.localizedDescription) — using raw") }
            }
            guard id == session, !Task.isCancelled else { return }
            guard !text.isEmpty else {
                listenLog("capture empty id=\(id) mode=\(mode)")
                notify("Empty transcription — check microphone permission")
                return
            }
            switch mode {
            case .dictation:
                NSLog("[Listen] dictation pasting \(text.count) chars in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                Paster.paste(text)
                listenLog("dictation complete id=\(id) chars=\(text.count) elapsed_ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            case .quickThought:
                let answer = await answerThought(text)
                guard id == session, !Task.isCancelled else { return }
                NoteStore.shared.append(VoiceNote(kind: .quickThought, thought: text, response: answer))
                responsePresenter.show(heading: "Quick Thought", thought: text, answer: answer, compact: true)
                speaker.speak(answer, enabled: settings.tts_enabled)
                listenLog("quick thought complete id=\(id) thought_chars=\(text.count) response_chars=\(answer.count)")
            case .microphoneTest:
                responsePresenter.show(heading: "Microphone test", thought: "Transcription received", answer: text)
                listenLog("microphone test complete id=\(id) chars=\(text.count)")
            }
        } catch is CancellationError {
            NSLog("[Listen] capture session \(id) cancelled")
        } catch {
            guard id == session else { return }
            notify("Transcription failed: \(error.localizedDescription)")
            NSLog("[Listen] capture error: \(error)")
        }
    }

    private func answerThought(_ text: String) async -> String {
        guard let assistant else {
            return "Captured locally. Configure an assistant provider in Preferences to receive a reflection."
        }
        // Retrieval happens off the main actor so a large lifetime notes
        // ledger can never stall dictation controls or the menubar animation.
        let memory = await Task.detached(priority: .userInitiated) {
            NoteStore.shared.retrieve(for: text)
        }.value
        let prompt = ThoughtPromptBuilder.make(currentThought: text, memory: memory)
        do { return try await withTimeout(20) { try await assistant.interpret("", prompt: prompt) } }
        catch {
            NSLog("[Listen] thought response failed: \(error.localizedDescription)")
            return "Captured locally. I couldn't generate a response: \(error.localizedDescription)"
        }
    }

    private func transcribeWithRetry(_ stt: STTProvider, _ url: URL) async throws -> String {
        do { return try await withTimeout(30) { try await stt.transcribe(url) } }
        catch let error as URLError where Self.transientCodes.contains(error.code) {
            NSLog("[Listen] STT transient error \(error.code.rawValue), retrying once")
            return try await withTimeout(30) { try await stt.transcribe(url) }
        }
    }

    private static let transientCodes: Set<URLError.Code> = [
        .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
        .cannotFindHost, .notConnectedToInternet, .secureConnectionFailed,
    ]

    // MARK: - Wake word conversation

    private func configureWakeCallbacks() {
        wakeWord.echoGate = speaker.echoGate
        speaker.onFinish = { [weak self] in
            self?.wakeWord.resetConversationRecognitionAfterSpeech()
        }
        wakeWord.onStatus = { [weak self] status in
            guard let self else { return }
            self.wakeActive = status != "wake word off"
            listenLog("wake status=\(status)")
            self.rebuildMenu()
        }
        wakeWord.onError = { [weak self] message in
            guard let self else { return }
            self.settings.wake_word_enabled = false
            SettingsStore.save(self.settings)
            self.wakeActive = false
            listenLog("wake error=\(message)")
            self.rebuildMenu(); self.notify(message)
        }
        wakeWord.onSpeechBegan = { [weak self] bargeIn in
            if bargeIn { self?.speaker.stop() }
        }
        wakeWord.onCommand = { [weak self] text, bargeIn in self?.handleWakeCommand(text, bargeIn: bargeIn) }
    }

    @objc private func toggleWakeWord() {
        settings.wake_word_enabled.toggle()
        SettingsStore.save(settings)
        settings.wake_word_enabled ? enableWakeWord() : disableWakeWord()
        rebuildMenu()
    }

    private func enableWakeWord() {
        notify("Enabling wake word…")
        wakeWord.start(phrase: settings.wake_word_phrase,
                       conversationTimeout: settings.wake_conversation_timeout)
    }

    private func disableWakeWord() {
        voiceSession &+= 1
        assistantTask?.cancel(); assistantTask = nil
        speaker.stop()
        wakeWord.stop()
        wakeActive = false
        backgroundStatus = nil
        renderStatus()
    }

    private func handleWakeCommand(_ text: String, bargeIn: Bool) {
        listenLog("wake command chars=\(text.count) barge_in=\(bargeIn)")
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if isStopDirective(normalized) {
            speaker.stop(); wakeWord.returnToWake()
            responsePresenter.show(heading: "Listen", thought: text, answer: "Conversation ended.")
            return
        }
        if bargeIn { speaker.stop() }
        voiceSession &+= 1
        let id = voiceSession
        assistantTask?.cancel()
        backgroundStatus = "reflecting"
        renderStatus()
        prewarmConnections(includeAssistant: true)
        assistantTask = Task {
            let answer = await answerThought(text)
            guard id == voiceSession, !Task.isCancelled else { return }
            NoteStore.shared.append(VoiceNote(kind: .wakeConversation, thought: text, response: answer))
            responsePresenter.show(heading: "Listen", thought: text, answer: answer)
            backgroundStatus = nil
            wakeWord.continueConversation()
            speaker.speak(answer, enabled: settings.tts_enabled)
            renderStatus()
        }
    }

    private func isStopDirective(_ text: String) -> Bool {
        let exact: Set<String> = ["stop", "cancel", "goodbye", "bye", "never mind", "nevermind",
                                  "stop listening", "end conversation", "that's all", "thats all"]
        return exact.contains(text) || text.hasPrefix("stop talking") || text.hasPrefix("please stop")
    }

    // MARK: - Long conversation recorder / report

    @objc private func toggleConversationRecording() {
        if conversationRecorder.isRecording { stopConversationRecording() }
        else { startConversationRecording() }
    }

    private func startConversationRecording() {
        do {
            let directory = try conversationRecorder.start(chunkMinutes: settings.conversation_chunk_minutes)
            playChime("Tink")
            NSLog("[Listen] local session directory: \(directory.path)")
            listenLog("conversation start directory=\(directory.lastPathComponent)")
            rebuildMenu()
        } catch { notify("Recorder error: \(error.localizedDescription)") }
    }

    private func stopConversationRecording() {
        playChime("Pop")
        backgroundStatus = "finalizing audio"
        rebuildMenu()
        Task {
            guard let draft = await conversationRecorder.stop() else {
                if activeReportProcesses == 0 { backgroundStatus = nil }
                rebuildMenu(); return
            }
            listenLog("conversation stopped id=\(draft.id) chunks=\(draft.chunks.count)")
            guard let stt else {
                if activeReportProcesses == 0 { backgroundStatus = nil }
                notify("Audio saved; configure STT to create its report.")
                rebuildMenu(); return
            }
            activeReportProcesses += 1
            defer {
                activeReportProcesses -= 1
                backgroundStatus = activeReportProcesses == 0 ? nil : "processing \(activeReportProcesses) reports"
                rebuildMenu()
            }
            do {
                let reportURL = try await ConversationProcessor.process(
                    draft, stt: stt, assistant: assistant
                ) { [weak self] message in
                    DispatchQueue.main.async {
                        self?.backgroundStatus = message
                        self?.renderStatus()
                    }
                }
                guard !Task.isCancelled else { return }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if let data = try? Data(contentsOf: draft.directory.appendingPathComponent("report.json")),
                   let report = try? decoder.decode(ConversationReport.self, from: data) {
                    NoteStore.shared.append(VoiceNote(
                        kind: .recordedConversation, thought: report.overview,
                        response: report.actionsAndDecisions, sessionID: report.id,
                        reportPath: reportURL.path
                    ))
                }
                responsePresenter.show(heading: "Conversation ready", thought: "", answer: "Report, transcript, audio, and analyses are saved locally.")
                listenLog("conversation report complete id=\(draft.id)")
                showConversations(selecting: draft.id)
            } catch is CancellationError {
                return
            } catch {
                listenLog("conversation report failed id=\(draft.id) error=\(error.localizedDescription)")
                notify("Report failed: \(error.localizedDescription)")
                NSLog("[Listen] conversation processing error: \(error)")
            }
        }
    }

    private func handleAnalysisURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sessionID = components.queryItems?.first(where: { $0.name == "session" })?.value,
              let scope = components.queryItems?.first(where: { $0.name == "scope" })?.value,
              sessionID.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
              scope == "all" || scope.range(of: #"^chapter-[0-9]+$"#, options: .regularExpression) != nil else {
            notify("Invalid analysis link"); return
        }
        showConversations(selecting: sessionID)
        runConversationAnalysis(sessionID: sessionID, scope: scope, source: .listen)
    }

    private func analysisEngine(for source: ConversationAnalysisSource) -> Interpreter? {
        switch source {
        case .listen: return assistant
        case .hermes: return HermesInterpreter.isAvailable ? HermesInterpreter() : nil
        }
    }

    private func runConversationAnalysis(
        sessionID: String, scope: String, source: ConversationAnalysisSource
    ) {
        guard let engine = analysisEngine(for: source) else {
            let message = source == .hermes
                ? "Hermes Agent is not available."
                : "Configure an assistant provider to run deep analysis."
            conversationsModel?.errorMessage = message
            notify(message)
            return
        }
        let label = "\(source.title) is analyzing \(scope == "all" ? "the conversation" : "this chapter")"
        conversationsModel?.beginWork(label)
        backgroundStatus = "deep analysis"
        renderStatus()
        Task {
            do {
                _ = try await ConversationProcessor.analyze(
                    sessionID: sessionID,
                    scope: scope,
                    assistant: engine,
                    storageKey: source == .hermes ? "hermes:\(scope)" : scope
                )
                backgroundStatus = nil
                renderStatus()
                conversationsModel?.finishWork(selecting: sessionID)
            } catch is CancellationError {
                backgroundStatus = nil
                renderStatus()
                conversationsModel?.finishWork(selecting: sessionID)
            } catch {
                backgroundStatus = nil
                renderStatus()
                conversationsModel?.finishWork(
                    selecting: sessionID, error: error.localizedDescription
                )
            }
        }
    }

    private func runConversationFocus(sessionID: String, source: ConversationAnalysisSource) {
        guard let engine = analysisEngine(for: source) else {
            let message = source == .hermes
                ? "Hermes Agent is not available."
                : "Configure an assistant provider to refresh takeaways."
            conversationsModel?.errorMessage = message
            notify(message)
            return
        }
        conversationsModel?.beginWork("\(source.title) is focusing the takeaways")
        backgroundStatus = "focusing takeaways"
        renderStatus()
        Task {
            do {
                _ = try await ConversationProcessor.refreshFocus(
                    sessionID: sessionID, assistant: engine
                )
                backgroundStatus = nil
                renderStatus()
                conversationsModel?.finishWork(selecting: sessionID)
            } catch is CancellationError {
                backgroundStatus = nil
                renderStatus()
                conversationsModel?.finishWork(selecting: sessionID)
            } catch {
                backgroundStatus = nil
                renderStatus()
                conversationsModel?.finishWork(
                    selecting: sessionID, error: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Feedback

    private static var chimes: [String: NSSound] = [:]
    private func playChime(_ name: String) {
        guard settings.sound_enabled else { return }
        guard let sound = Self.chimes[name] ?? {
            let value = NSSound(named: NSSound.Name(name)); Self.chimes[name] = value; return value
        }() else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private func notify(_ message: String) {
        let msg = message.count > 70 ? String(message.prefix(67)) + "…" : message
        transientMessage = msg
        renderStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.transientMessage == msg else { return }
            self.transientMessage = nil; self.renderStatus()
        }
    }
}
