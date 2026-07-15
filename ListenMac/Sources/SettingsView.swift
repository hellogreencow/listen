import Combine
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var conversationRecording: Bool
    private let onSave: (AppSettings) -> Void
    private let onMicrophoneTest: () -> Void
    private let onQuickThoughtTest: () -> Void
    private let onToggleConversation: () -> Bool
    private var applyCancellable: AnyCancellable?

    init(
        _ initial: AppSettings,
        conversationRecording: Bool = false,
        onSave: @escaping (AppSettings) -> Void,
        onMicrophoneTest: @escaping () -> Void = {},
        onQuickThoughtTest: @escaping () -> Void = {},
        onToggleConversation: @escaping () -> Bool = { false }
    ) {
        self.settings = initial
        self.conversationRecording = conversationRecording
        self.onSave = onSave
        self.onMicrophoneTest = onMicrophoneTest
        self.onQuickThoughtTest = onQuickThoughtTest
        self.onToggleConversation = onToggleConversation
        // Apply-as-you-edit. The explicit Save button meant closing the
        // window silently discarded changes. Debounced so per-keystroke
        // edits don't thrash provider/hotkey reloads.
        applyCancellable = $settings
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] s in self?.onSave(s) }
    }

    func testMicrophone() { onMicrophoneTest() }
    func testQuickThought() { onQuickThoughtTest() }
    func toggleConversation() { conversationRecording = onToggleConversation() }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: String = "General"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag("General")
                Label("Appearance", systemImage: "paintpalette").tag("Appearance")
                Label("Transcription", systemImage: "waveform").tag("Transcription")
                Label("Voice", systemImage: "waveform.badge.mic").tag("Voice")
                Label("Assistant", systemImage: "wand.and.stars").tag("Cleanup")
                Label("API Keys", systemImage: "key.fill").tag("Keys")
                Label("About", systemImage: "info.circle").tag("About")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case "Appearance":    appearancePane
                    case "Transcription": transcriptionPane
                    case "Voice":         voicePane
                    case "Cleanup":       cleanupPane
                    case "Keys":          keysPane
                    case "About":         aboutPane
                    default:              generalPane
                    }
                }
                .padding(28)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(minWidth: 520, minHeight: 460)
        }
        .navigationTitle("Listen")
    }

    // MARK: - Panes

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("General", "Behavior and hotkey")
            section("Hotkey") {
                Picker("Hold to record", selection: $model.settings.hotkey) {
                    ForEach(Hotkey.supportedKeys, id: \.key) { k in
                        Text(k.label).tag(k.key)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text("Press and hold this key to record. Release to transcribe.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            section("Feedback") {
                Toggle("Play sound when recording starts", isOn: $model.settings.sound_enabled)
                Button("Run 3-second microphone test (never pastes)") { model.testMicrophone() }
                    .buttonStyle(.bordered)
            }
            footer
        }
    }

    private var transcriptionPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Transcription", "Speech-to-text provider")
            section("Provider") {
                Picker("STT", selection: $model.settings.stt_provider) {
                    Text("Apple (on-device)").tag("apple")
                    Text("ElevenLabs Scribe").tag("elevenlabs")
                    Text("OpenAI Whisper").tag("openai")
                    Text("Groq Whisper").tag("groq")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Group {
                switch model.settings.stt_provider {
                case "apple":
                    section("Model") {
                        Text("On-device SpeechTranscriber — no API key, no network, no rate limits.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                case "openai":
                    section("OpenAI model") {
                        TextField("model", text: $model.settings.openai_whisper_model)
                            .textFieldStyle(.roundedBorder)
                    }
                case "groq":
                    section("Groq model") {
                        TextField("model", text: $model.settings.groq_stt_model)
                            .textFieldStyle(.roundedBorder)
                    }
                default:
                    section("ElevenLabs model") {
                        TextField("model id", text: $model.settings.elevenlabs_model)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            footer
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Appearance", "The listening indicator in your menu bar")
            section("Live preview") {
                HStack {
                    Spacer()
                    MenuBarAppearancePreview(
                        styleName: model.settings.menubar_color_style,
                        speed: model.settings.menubar_animation_speed,
                        intensity: model.settings.menubar_color_intensity,
                        padding: model.settings.menubar_text_padding,
                        large: true
                    )
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            section("Color effect") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(StatusColorStyle.allCases) { style in
                        appearanceChoice(style)
                    }
                }
            }
            section("Motion") {
                HStack {
                    Text("Speed")
                    Slider(
                        value: $model.settings.menubar_animation_speed,
                        in: StatusAppearance.speedRange
                    )
                    Text(String(format: "%.2f×", model.settings.menubar_animation_speed))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 48)
                }
                HStack {
                    Text("Intensity")
                    Slider(
                        value: $model.settings.menubar_color_intensity,
                        in: StatusAppearance.intensityRange
                    )
                    Text("\(Int(model.settings.menubar_color_intensity * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 48)
                }
            }
            section("Text spacing") {
                HStack {
                    Text("Breathing room")
                    Slider(
                        value: $model.settings.menubar_text_padding,
                        in: StatusAppearance.textPaddingRange,
                        step: 1
                    )
                    Text("\(Int(model.settings.menubar_text_padding)) pt")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 48)
                }
                Text("The width stays fixed between Listen and listening, so the label does not jump when recording begins.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("macOS adds its own microphone privacy indicator while the mic is active. Listen keeps that system item separated from this text, but apps cannot disable it on the built-in display.")
                .font(.caption).foregroundStyle(.tertiary)
            footer
        }
    }

    private func appearanceChoice(_ style: StatusColorStyle) -> some View {
        let selected = model.settings.menubar_color_style == style.rawValue
        return Button {
            model.settings.menubar_color_style = style.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                MenuBarAppearancePreview(
                    styleName: style.rawValue,
                    speed: model.settings.menubar_animation_speed,
                    intensity: model.settings.menubar_color_intensity,
                    padding: 12,
                    large: false
                )
                Text(style.title).font(.callout).fontWeight(.medium).foregroundStyle(.primary)
                Text(style.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: selected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.title) menu bar colors")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var voicePane: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Voice", "Quick thoughts, wake word, and conversations")
            section("Quick Thought") {
                Text("Hold Left Command + Option, speak, then release. Listen answers aloud and saves both sides to Notes.")
                    .foregroundStyle(.secondary).font(.callout)
                Button("Test Quick Thought for 4 seconds") { model.testQuickThought() }
                    .buttonStyle(.bordered)
            }
            section("Wake word") {
                Toggle("Listen continuously for the wake phrase", isOn: $model.settings.wake_word_enabled)
                TextField("Wake phrase", text: $model.settings.wake_word_phrase)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.settings.wake_word_enabled)
                Text("Off by default. Enabling requests Apple's Speech Recognition permission and keeps the microphone active until disabled.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            section("Conversation loop") {
                Toggle("Speak assistant answers", isOn: $model.settings.tts_enabled)
                Picker("Voice output", selection: $model.settings.tts_provider) {
                    Text("xAI voice").tag("xai")
                    Text("System fallback").tag("system")
                }
                .pickerStyle(.segmented)
                .disabled(!model.settings.tts_enabled)
                TextField("xAI voice ID", text: $model.settings.xai_voice_id)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.settings.tts_enabled || model.settings.tts_provider != "xai")
                Text("xAI uses the migrated voice-daemon voice. System speech is used automatically if xAI is unavailable.")
                    .foregroundStyle(.secondary).font(.callout)
                HStack {
                    Text("Return to wake mode after")
                    TextField("30", value: $model.settings.wake_conversation_timeout, format: .number)
                        .frame(width: 64).textFieldStyle(.roundedBorder)
                    Text("seconds idle").foregroundStyle(.secondary)
                }
            }
            section("Long recordings") {
                Stepper("Roll audio every \(model.settings.conversation_chunk_minutes) minutes",
                        value: $model.settings.conversation_chunk_minutes, in: 2...30)
                Text("Recordings, transcripts, reports, and analysis stay under ~/.listen/sessions/.")
                    .foregroundStyle(.secondary).font(.callout)
                Button(model.conversationRecording ? "Stop & Process Conversation" : "Start Conversation Recording") {
                    model.toggleConversation()
                }.buttonStyle(.borderedProminent)
            }
            footer
        }
    }

    private var cleanupPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Assistant & Cleanup", "Direct provider for reflections, reports, analysis, and optional dictation polish")
            section("Enabled") {
                Toggle("Also clean up dictation before pasting", isOn: $model.settings.cleanup_enabled)
            }
            section("Provider") {
                Picker("Assistant", selection: $model.settings.interpreter_provider) {
                    Text("OpenRouter").tag("openrouter")
                    Text("OpenAI").tag("openai")
                    Text("Groq").tag("groq")
                    Text("None").tag("none")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Quick Thought, wake replies, conversation reports, and deep analysis use this provider even when dictation cleanup is off.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            section("Model") {
                Group {
                    switch model.settings.interpreter_provider {
                    case "openai":
                        TextField("model", text: $model.settings.openai_cleanup_model)
                    case "groq":
                        TextField("model", text: $model.settings.groq_model)
                    default:
                        TextField("model", text: $model.settings.openrouter_model)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            section("Prompt") {
                Text("Use `{text}` where the transcript should be inserted.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.settings.cleanup_prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .disabled(!model.settings.cleanup_enabled)
            }
            footer
        }
    }

    private var keysPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("API Keys", "Stored locally in ~/.listen/config.json")
            keyField("ElevenLabs", text: $model.settings.elevenlabs_api_key)
            keyField("OpenAI",     text: $model.settings.openai_api_key)
            keyField("Groq",       text: $model.settings.groq_api_key)
            keyField("OpenRouter", text: $model.settings.openrouter_api_key)
            keyField("xAI Voice",  text: $model.settings.xai_api_key)
            footer
        }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Listen", "Fast voice-to-text for macOS")
            Text("Hold a hotkey, speak, release, and the transcription is pasted into the focused app.")
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 8)
            HStack {
                Text("Config file")
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.url])
                }.buttonStyle(.bordered)
            }
            HStack {
                Text("Permissions")
                Spacer()
                Button("Open Accessibility") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }.buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Building blocks

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).bold()
            Text(sub).foregroundStyle(.secondary)
        }.padding(.bottom, 4)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption).foregroundStyle(.secondary).tracking(0.8)
            content()
        }
    }

    private func keyField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption).foregroundStyle(.secondary).tracking(0.8)
            SecureField("sk-…", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        Text("Changes are saved as you edit.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
    }
}

private struct MenuBarAppearancePreview: View {
    let styleName: String
    let speed: Double
    let intensity: Double
    let padding: Double
    let large: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = StatusAppearance.phase(at: context.date, speed: speed)
            let colors = StatusAppearance.previewColors(
                styleName: styleName,
                phase: phase,
                intensity: intensity
            ).map(Color.init(nsColor:))
            Text("listening")
                .font(.system(size: large ? 14 : 12, weight: .medium, design: .rounded))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .padding(.horizontal, CGFloat(padding) / 2)
                .padding(.vertical, large ? 7 : 5)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .accessibilityLabel("Animated \(StatusAppearance.style(named: styleName).title) preview")
    }
}
