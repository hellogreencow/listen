import Combine
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings
    private let onSave: (AppSettings) -> Void
    private var applyCancellable: AnyCancellable?

    init(_ initial: AppSettings, onSave: @escaping (AppSettings) -> Void) {
        self.settings = initial
        self.onSave = onSave
        // Apply-as-you-edit. The explicit Save button meant closing the
        // window silently discarded changes. Debounced so per-keystroke
        // edits don't thrash provider/hotkey reloads.
        applyCancellable = $settings
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] s in self?.onSave(s) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: String = "General"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag("General")
                Label("Transcription", systemImage: "waveform").tag("Transcription")
                Label("Cleanup", systemImage: "wand.and.stars").tag("Cleanup")
                Label("API Keys", systemImage: "key.fill").tag("Keys")
                Label("About", systemImage: "info.circle").tag("About")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case "Transcription": transcriptionPane
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

    private var cleanupPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Cleanup", "LLM polishing pass on transcripts")
            section("Enabled") {
                Toggle("Run a cleanup LLM after transcription", isOn: $model.settings.cleanup_enabled)
            }
            section("Provider") {
                Picker("Cleanup", selection: $model.settings.interpreter_provider) {
                    Text("OpenRouter").tag("openrouter")
                    Text("OpenAI").tag("openai")
                    Text("Groq").tag("groq")
                    Text("None").tag("none")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.settings.cleanup_enabled)
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
                .disabled(!model.settings.cleanup_enabled)
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
