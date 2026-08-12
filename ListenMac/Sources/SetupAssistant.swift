import AppKit
import AVFoundation
import Combine
import Speech
import SwiftUI

enum SetupCompletion {
    static let currentVersion = 1
    private static let key = "ListenSetupAssistantVersion"

    static var isComplete: Bool {
        UserDefaults.standard.integer(forKey: key) >= currentVersion
    }

    static func markComplete() {
        UserDefaults.standard.set(currentVersion, forKey: key)
    }
}

@MainActor
final class SetupAssistantModel: ObservableObject {
    enum AutomationState: Equatable {
        case unchecked
        case checking
        case ready
        case blocked(String)
    }

    enum TestPhase: Equatable {
        case idle
        case recording
        case transcribing
        case pasting
        case passed
        case failed
    }

    @Published var step = 0
    @Published var settings: AppSettings
    @Published private(set) var microphoneStatus: AVAuthorizationStatus
    @Published private(set) var speechStatus: SFSpeechRecognizerAuthorizationStatus
    @Published private(set) var accessibilityReady = false
    @Published private(set) var automationState: AutomationState = .unchecked
    @Published var testFieldText = ""
    @Published private(set) var testPhase: TestPhase = .idle
    @Published private(set) var testMessage = "Your transcript will appear here automatically."
    @Published private(set) var testLatencyMS: Int?

    private var expectedTestText = ""
    private var permissionTimer: Timer?
    private var settingsCancellable: AnyCancellable?
    private let onSettingsChanged: (AppSettings) -> Void
    private let onStartTest: () -> Void
    private let onFinish: () -> Void

    init(
        settings: AppSettings,
        onSettingsChanged: @escaping (AppSettings) -> Void,
        onStartTest: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.settings = settings
        self.microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.speechStatus = SFSpeechRecognizer.authorizationStatus()
        self.onSettingsChanged = onSettingsChanged
        self.onStartTest = onStartTest
        self.onFinish = onFinish
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        settingsCancellable = $settings
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.onSettingsChanged(value)
                if self.testPhase == .passed {
                    self.testPhase = .idle
                    self.testMessage = "Settings changed. Run the final test again."
                }
            }
    }

    var appleSTTAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var providerIssue: String? {
        SetupReadiness.providerIssue(settings, appleSTTAvailable: appleSTTAvailable)
    }

    var providerReady: Bool { providerIssue == nil }
    var requiresSpeechPermission: Bool { settings.stt_provider == "apple" }
    var microphoneReady: Bool { microphoneStatus == .authorized }
    var speechReady: Bool { !requiresSpeechPermission || speechStatus == .authorized }
    var automationReady: Bool { automationState == .ready }

    var permissionsReady: Bool {
        microphoneReady && speechReady && accessibilityReady && automationReady
    }

    var canStartTest: Bool {
        SetupReadiness.canRunEndToEndTest(
            providerReady: providerReady,
            microphoneReady: microphoneReady,
            speechReady: speechReady,
            accessibilityReady: accessibilityReady,
            automationReady: automationReady
        ) && ![.recording, .transcribing, .pasting].contains(testPhase)
    }

    var canFinish: Bool { testPhase == .passed }

    var maxUnlockedStep: Int {
        if permissionsReady { return 3 }
        if providerReady { return 2 }
        return 1
    }

    var selectedHotkeyLabel: String {
        Hotkey.supportedKeys.first(where: { $0.key == settings.hotkey })?.label ?? settings.hotkey
    }

    func refreshPermissions() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        accessibilityReady = AXIsProcessTrusted()
    }

    func requestMicrophone() {
        if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        } else if !microphoneReady {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestSpeech() {
        if speechStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        } else if !speechReady {
            openPrivacyPane("Privacy_SpeechRecognition")
        }
    }

    func requestAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestAutomation() {
        guard accessibilityReady else {
            automationState = .blocked("Allow Accessibility first.")
            requestAccessibility()
            return
        }
        automationState = .checking
        let outcome = Paster.probeAutomation()
        switch outcome {
        case .success:
            automationState = .ready
        case .accessibilityDenied:
            automationState = .blocked(outcome.message)
            requestAccessibility()
        case .automationDenied:
            automationState = .blocked(outcome.message)
            openPrivacyPane("Privacy_Automation")
        case .failed(let message):
            automationState = .blocked(message)
        }
    }

    func beginTest() {
        guard canStartTest else { return }
        expectedTestText = ""
        testFieldText = ""
        testLatencyMS = nil
        testMessage = "Speak now — recording for four seconds…"
        testPhase = .recording
        onStartTest()
    }

    func markTranscribing() {
        guard testPhase == .recording else { return }
        testPhase = .transcribing
        testMessage = "Transcribing your recording…"
    }

    func prepareForPaste(_ text: String, latencyMS: Int) {
        expectedTestText = text
        testLatencyMS = latencyMS
        testPhase = .pasting
        testMessage = "Transcription complete — verifying automatic paste…"
    }

    func completePaste(_ outcome: Paster.Outcome) {
        switch outcome {
        case .success where !expectedTestText.isEmpty && testFieldText.contains(expectedTestText):
            automationState = .ready
            testPhase = .passed
            testMessage = "Everything works: recording, transcription, and automatic paste."
        case .success:
            testPhase = .failed
            testMessage = "Transcription worked, but the paste did not reach the test field. Try again."
        case .accessibilityDenied:
            accessibilityReady = false
            testPhase = .failed
            testMessage = outcome.message
        case .automationDenied:
            automationState = .blocked(outcome.message)
            testPhase = .failed
            testMessage = outcome.message
        case .failed(let message):
            testPhase = .failed
            testMessage = message
        }
    }

    func failTest(_ message: String) {
        testPhase = .failed
        testMessage = message
    }

    func finish() {
        guard canFinish else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        onFinish()
    }

    func openProviderSignup() {
        let address: String
        switch settings.stt_provider {
        case "groq": address = "https://console.groq.com/keys"
        case "openai": address = "https://platform.openai.com/api-keys"
        case "elevenlabs": address = "https://elevenlabs.io/app/settings/api-keys"
        default: return
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct SetupAssistantView: View {
    @ObservedObject var model: SetupAssistantModel
    @FocusState private var testFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch model.step {
                    case 0: welcomeStep
                    case 1: providerStep
                    case 2: permissionsStep
                    default: testStep
                    }
                }
                .padding(34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer
            }
        }
        .frame(width: 780, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.testPhase) { phase in
            if phase == .recording || phase == .pasting { testFieldFocused = true }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.red, .green, .blue, .purple],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            .frame(width: 5, height: 22)
                            .shadow(color: .purple.opacity(0.55), radius: 5)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listen").font(.headline)
                    Text("Setup").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)

            setupStep(0, "Welcome", "How Listen works", "sparkles")
            setupStep(1, "Transcription", "Free or cloud STT", "waveform")
            setupStep(2, "Permissions", "Guided privacy checks", "checkmark.shield")
            setupStep(3, "Test", "Prove the full flow", "checkmark.circle")
            Spacer()
            Text("About 2 minutes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(width: 205)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
    }

    private func setupStep(_ index: Int, _ title: String, _ subtitle: String, _ symbol: String) -> some View {
        Button {
            model.step = index
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(model.step == index ? Color.accentColor : Color.primary)
            .padding(10)
            .background(model.step == index ? Color.accentColor.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(index > model.maxUnlockedStep)
        .opacity(index > model.maxUnlockedStep ? 0.45 : 1)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Voice to text that is ready before you need it.")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text("Hold one key, speak naturally, release, and Listen pastes the words into the app you were already using.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                feature("No Listen subscription", "Apple on-device transcription is free on supported Macs.", "dollarsign.circle")
                feature("Private by default", "Audio stays on your Mac when Apple on-device transcription is selected.", "lock.shield")
                feature("Proven before you finish", "Setup records, transcribes, and pastes into its own test field.", "checkmark.seal")
            }
            .padding(.top, 8)
        }
    }

    private func feature(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader("Choose transcription", "Start free with Apple, or bring a cloud provider for different speed and language tradeoffs.")
            Picker("Speech-to-text provider", selection: $model.settings.stt_provider) {
                Text("Apple · Free").tag("apple")
                Text("Groq · Fast").tag("groq")
                Text("ElevenLabs").tag("elevenlabs")
                Text("OpenAI").tag("openai")
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                if model.settings.stt_provider == "apple" {
                    Label("No account, API key, network request, or usage bill.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(model.providerReady ? Color.green : Color.orange)
                    if !model.appleSTTAvailable {
                        Text(model.providerIssue ?? "Apple transcription is unavailable on this Mac.")
                            .foregroundStyle(.orange)
                    }
                } else {
                    SecureField("Paste your \(providerName) API key", text: providerKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Get an API key") { model.openProviderSignup() }
                            .buttonStyle(.link)
                        Spacer()
                        if let issue = model.providerIssue {
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        } else {
                            Label("Key added", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    Text("Listen is free. Your selected cloud provider may charge for its own usage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(15)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text("HOLD TO DICTATE").font(.caption).foregroundStyle(.secondary).tracking(0.8)
                Picker("Shortcut", selection: $model.settings.hotkey) {
                    ForEach(Hotkey.supportedKeys, id: \.key) { key in
                        Text(key.label).tag(key.key)
                    }
                }
                .pickerStyle(.menu)
                Text("Hold \(model.selectedHotkeyLabel), speak, then release.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var providerName: String {
        switch model.settings.stt_provider {
        case "groq": return "Groq"
        case "openai": return "OpenAI"
        default: return "ElevenLabs"
        }
    }

    private var providerKey: Binding<String> {
        switch model.settings.stt_provider {
        case "groq": return $model.settings.groq_api_key
        case "openai": return $model.settings.openai_api_key
        default: return $model.settings.elevenlabs_api_key
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Allow what Listen needs", "Each permission has one job. Status updates automatically when you return from System Settings.")
            PermissionRow(
                title: "Microphone",
                detail: "Records only while you hold the shortcut.",
                ready: model.microphoneReady,
                button: model.microphoneStatus == .notDetermined ? "Allow" : "Open Settings",
                action: model.requestMicrophone
            )
            if model.requiresSpeechPermission {
                PermissionRow(
                    title: "Speech Recognition",
                    detail: "Runs Apple's free transcription engine.",
                    ready: model.speechReady,
                    button: model.speechStatus == .notDetermined ? "Allow" : "Open Settings",
                    action: model.requestSpeech
                )
            }
            PermissionRow(
                title: "Accessibility",
                detail: "Detects your hold shortcut and permits paste keystrokes.",
                ready: model.accessibilityReady,
                button: "Open Settings",
                action: model.requestAccessibility
            )
            PermissionRow(
                title: "Automation",
                detail: "Lets Listen ask System Events to press Command-V.",
                ready: model.automationReady,
                button: automationButtonTitle,
                working: model.automationState == .checking,
                action: model.requestAutomation
            )
            if case .blocked(let message) = model.automationState {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var automationButtonTitle: String {
        switch model.automationState {
        case .ready: return "Verified"
        case .checking: return "Checking…"
        case .blocked: return "Open / Retry"
        case .unchecked: return "Allow & Verify"
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Prove it works", "This checks the real path: microphone → transcription → clipboard → automatic paste.")
            Text("Click Start, then say: “Listen is ready.” Recording stops automatically after four seconds.")
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.testFieldText)
                    .font(.system(size: 16))
                    .padding(8)
                    .focused($testFieldFocused)
                if model.testFieldText.isEmpty {
                    Text("Your words will paste here…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 125)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(testBorderColor, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button(testButtonTitle) { model.beginTest() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canStartTest)
                if [.recording, .transcribing, .pasting].contains(model.testPhase) {
                    ProgressView().controlSize(.small)
                }
                Text(model.testMessage)
                    .font(.callout)
                    .foregroundStyle(model.testPhase == .failed ? Color.orange : Color.secondary)
                Spacer()
            }
            if let latency = model.testLatencyMS {
                Label("Transcribed in \(String(format: "%.2f", Double(latency) / 1000)) seconds after recording stopped", systemImage: "speedometer")
                    .font(.callout)
                    .foregroundStyle(model.testPhase == .passed ? Color.green : Color.secondary)
            }
            if model.testPhase == .passed {
                Label("Listen is ready everywhere you type.", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .padding(.top, 6)
            }
        }
    }

    private var testButtonTitle: String {
        switch model.testPhase {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .pasting: return "Testing paste…"
        case .passed: return "Run again"
        default: return "Start 4-second test"
        }
    }

    private var testBorderColor: Color {
        switch model.testPhase {
        case .passed: return .green
        case .failed: return .orange
        case .recording: return .red
        default: return Color.secondary.opacity(0.3)
        }
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            if model.step > 0 {
                Button("Back") { model.step -= 1 }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if model.step < 3 {
                Button(model.step == 0 ? "Set up Listen" : "Continue") {
                    model.step += 1
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            } else {
                Button("Finish Setup") { model.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canFinish)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }

    private var canContinue: Bool {
        switch model.step {
        case 1: return model.providerReady
        case 2: return model.permissionsReady
        default: return true
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let ready: Bool
    let button: String
    var working = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(ready ? Color.green : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if working {
                ProgressView().controlSize(.small)
            } else if ready {
                Text("Ready").font(.callout).fontWeight(.medium).foregroundStyle(.green)
            } else {
                Button(button, action: action).buttonStyle(.bordered)
            }
        }
        .padding(13)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}
