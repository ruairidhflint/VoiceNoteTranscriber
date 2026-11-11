import AppKit
import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @Environment(TranscriptionQueue.self) private var queue
    @AppStorage(Prefs.modelKey) private var model = TranscriptionModel.recommended.rawValue
    @AppStorage(Prefs.strictnessKey) private var strictness = InaudibleStrictness.balanced.rawValue
    @AppStorage(Prefs.formatKey) private var format = OutputFormat.markdown.rawValue
    @AppStorage(Prefs.folderKey) private var folder = Prefs.defaultFolder.path
    @AppStorage(Prefs.promptKey) private var prompt = DefaultPrompt.text
    @State private var keyDraft = ""
    @State private var keyError: String?

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $keyDraft, prompt: Text(queue.hasAPIKey ? "Saved in Keychain" : "sk-…"))
                    .onSubmit(saveKey)
                HStack {
                    Button(queue.hasAPIKey ? "Replace Key" : "Save Key", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if queue.hasAPIKey {
                        Button("Remove Key", role: .destructive) { queue.removeKey() }
                    }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.callout)
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
                Picker("Model", selection: $model) {
                    ForEach(TranscriptionModel.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Text(TranscriptionModel(rawValue: model)?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !usesPrompt {
                    Picker("Mark as [inaudible]", selection: $strictness) {
                        ForEach(InaudibleStrictness.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Text(InaudibleStrictness(rawValue: strictness)?.summary ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Output") {
                LabeledContent("Save to") {
                    HStack {
                        Text(abbreviated(folder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Format", selection: $format) {
                    ForEach(OutputFormat.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            if usesPrompt { promptSection }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: usesPrompt ? 740 : 448)
    }

    /// Only gpt-audio-1.5 takes a prompt; gpt-transcribe ignores instructions.
    private var usesPrompt: Bool { TranscriptionModel(rawValue: model) == .gptAudio }

    private var promptSection: some View {
        Section {
            TextEditor(text: $prompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 230)
            Button("Reset to Default") { prompt = DefaultPrompt.text }
                .disabled(prompt == DefaultPrompt.text)
        } header: {
            Text("Transcription prompt")
        } footer: {
            Text("Sent with every recording to gpt-audio-1.5. Keep the [inaudible] rule. The app relies on it, and on [no speech] for silent stretches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try queue.saveKey(key)
            keyDraft = ""
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }
}
