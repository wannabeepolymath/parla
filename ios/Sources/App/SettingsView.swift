import SwiftUI
import UIKit
import AVFoundation
import Security
import ParlaCore

struct LanguageView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var search = ""
    static func label(_ code: String?) -> String {
        code.flatMap { code in WhisperTranscriber.languages.first { $0.code == code }?.name } ?? "Follow speech"
    }
    var body: some View {
        List {
            Section { choice(nil, "Follow speech") } footer: { Text("Applies to the multilingual Whisper model. English-only models always transcribe English; Apple Speech uses the language chosen in Models.") }
            Section("Always transcribe as") {
                ForEach(WhisperTranscriber.languages.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.code) { choice($0.code, $0.name) }
            }
        }.searchable(text: $search).navigationTitle("Language")
    }
    func choice(_ code: String?, _ title: String) -> some View {
        Button { settings.update { $0.language = code } } label: {
            HStack { Text(title); Spacer(); if settings.current.language == code { Image(systemName: "checkmark.circle.fill") } }
        }
    }
}

/// Edits commit on Return or when the field disappears, not per keystroke.
struct CommitField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    var body: some View {
        TextField(title, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
            .onAppear { text = value }.onSubmit { commit(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .onDisappear { if text.trimmingCharacters(in: .whitespacesAndNewlines) != value { commit(text.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    }
}

struct CleanupView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var key = ""
    @State private var status: String?
    var s: Settings { settings.current }
    static func summary(_ settings: Settings) -> String {
        switch settings.outputMode {
        case .raw: return "Raw transcript"
        case .selectedPreset: return (try? settings.selectedTransformPreset().name) ?? "Preset not chosen"
        case .cleanup: return settings.cleanupEnabled ? settings.cleanupModelLabel : "Local rules only"
        }
    }
    var body: some View {
        Form {
            Section {
                Picker("Output", selection: settings.binding(\.outputMode)) {
                    Text("Cleaned up").tag(DictationOutputMode.cleanup); Text("Raw transcript").tag(DictationOutputMode.raw); Text("Saved preset").tag(DictationOutputMode.selectedPreset)
                }
                if s.outputMode == .selectedPreset {
                    Picker("Preset", selection: settings.binding(\.selectedPresetID)) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(s.transformPresets) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if s.outputMode == .cleanup {
                    Toggle("Clean up with a model", isOn: settings.binding(\.cleanupEnabled))
                    Picker("Style", selection: settings.binding(\.cleanupStyle)) {
                        Text("Standard").tag(ProfileStyle.standard); Text("Conversational").tag(ProfileStyle.conversational); Text("Formal").tag(ProfileStyle.formal)
                    }
                }
            } footer: {
                Text("Raw returns exactly what was recognized. Cleaned up removes fillers and fixes punctuation; whole-dictation snippets and replacements apply even with the model off. If a model fails, the raw transcript is kept and the reason is shown.")
            }
            Section {
                Picker("Provider", selection: Binding(get: { s.cleanup.provider }, set: { provider in settings.update { $0.cleanup.provider = provider; if provider == "apple-intelligence", $0.cleanup.localSourceLocale == nil { $0.cleanup.localSourceLocale = Locale.current.language.languageCode?.identifier } } })) {
                    Text("Apple Intelligence").tag("apple-intelligence"); Text("Anthropic").tag("anthropic"); Text("OpenAI-compatible").tag("openai-compatible")
                }
                switch s.cleanup.provider {
                case "apple-intelligence":
                    CommitField(title: "Spoken language (e.g. en)", value: s.cleanup.localSourceLocale ?? "") { value in settings.update { $0.cleanup.localSourceLocale = value.isEmpty ? nil : value } }
                case "openai-compatible":
                    CommitField(title: "Base URL (https://…/v1)", value: s.cleanup.baseURL ?? "") { value in settings.update { $0.cleanup.baseURL = value.isEmpty ? nil : value } }
                    CommitField(title: "Model (optional)", value: s.cleanup.model ?? "") { value in settings.update { $0.cleanup.model = value.isEmpty ? nil : value } }
                    keyControls
                default:
                    CommitField(title: "Model", value: s.cleanupModel) { value in settings.update { $0.cleanupModel = value.isEmpty ? Settings().cleanupModel : value } }
                    keyControls
                }
                if let issue = cleanupConfigurationIssue(settings: s, env: [:], credentials: settings.store.credentials) { Text(issue).font(.footnote).foregroundStyle(.red) }
            } header: { Text("Provider") } footer: {
                Text("Apple Intelligence runs on this iPhone when it is available and turned on. Anthropic and OpenAI-compatible providers receive the raw transcript, dictionary and snippets over HTTPS with your own key, under their terms. Keys stay in this iPhone's Keychain and never reach the keyboard, widgets, App Group or exports.")
            }
            Section("Saved presets") {
                ForEach(s.transformPresets) { preset in NavigationLink(preset.name) { PresetEditor(preset: preset) } }
                NavigationLink("New preset") { PresetEditor(preset: TransformPreset()) }
            }
        }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle("Cleanup")
            .alert("API key", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) { Button("OK") { status = nil } } message: { Text(status ?? "") }
    }
    @ViewBuilder var keyControls: some View {
        Text(cleanupCredentialSource(settings: s, env: [:], credentials: settings.store.credentials)).font(.footnote).foregroundStyle(.secondary)
        SecureField(s.cleanup.provider == "openai-compatible" ? "API key (optional)" : "API key", text: $key).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Save key") { changeKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove key", role: .destructive) { changeKey(nil) }
    }
    func changeKey(_ value: String?) {
        do {
            try settings.store.changeCredential(scope: CredentialScope.selected(s), replacement: value)
            key = ""; status = value == nil ? "Key removed from this iPhone." : "Key saved in this iPhone's Keychain. No test request was sent."
            settings.reload()
        } catch { status = (error as? CredentialFailure)?.description ?? "The key could not be changed." }
    }
}

struct PresetEditor: View {
    @State var preset: TransformPreset
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section { TextField("Name", text: $preset.name) }
            Section {
                Picker("Kind", selection: $preset.kind) { Text("Rewrite").tag(TransformPreset.Kind.rewrite); Text("Translate").tag(TransformPreset.Kind.translation) }
                if preset.kind == .rewrite {
                    TextEditor(text: $preset.instruction).frame(minHeight: 120)
                    Toggle("Same language (Apple Intelligence)", isOn: Binding(get: { preset.localPreserveSourceLanguage ?? false }, set: { preset.localPreserveSourceLanguage = $0 ? true : nil }))
                } else { TextField("Target language", text: $preset.targetLanguage) }
            } footer: { Text("A preset transforms each dictation when Output is Saved preset. The instruction is yours; dictated text never supplies instructions.") }
            if let problem = preset.validationError { Section { Text(problem).foregroundStyle(.secondary) } }
            if s.transformPresets.contains(where: { $0.id == preset.id }) {
                Section { Button("Delete preset", role: .destructive) { settings.update { $0.transformPresets.removeAll { $0.id == preset.id } }; dismiss() } }
            }
        }.navigationTitle(preset.name.isEmpty ? "Preset" : preset.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(preset.validationError != nil) } }
    }
    var s: Settings { settings.current }
    func save() {
        settings.update { state in
            if let index = state.transformPresets.firstIndex(where: { $0.id == preset.id }) { state.transformPresets[index] = preset } else { state.transformPresets.append(preset) }
        }
        dismiss()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var retention: RetentionPolicy?
    var body: some View {
        NavigationStack {
            Form {
                Section("Dictation") {
                    NavigationLink { ModelsView() } label: { LabeledContent("Models", value: ModelsView.selectionLabel(settings.current)) }
                    NavigationLink { LanguageView() } label: { LabeledContent("Language", value: LanguageView.label(settings.current.language)) }
                    NavigationLink { CleanupView() } label: { LabeledContent("Cleanup", value: CleanupView.summary(settings.current)) }
                    NavigationLink { DictionaryView() } label: { LabeledContent("Dictionary", value: "\(settings.current.dictionary.count)") }
                    NavigationLink { PairsView(kind: .snippets) } label: { LabeledContent("Snippets", value: "\(settings.current.snippets.count)") }
                    NavigationLink { PairsView(kind: .replacements) } label: { LabeledContent("Replacements", value: "\(settings.current.replacements.count)") }
                }
                Section("General") {
                    Button("Open Parla’s iPhone settings", systemImage: "gearshape") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    Text("Keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → Parla. Then enable Allow Full Access for voice handoff. Keyboard activation must be confirmed manually.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Audio & feedback") {
                    LabeledContent("Microphone permission", value: AVAudioApplication.shared.recordPermission == .granted ? "Allowed" : "Not allowed")
                    Picker("Input", selection: preference(\.microphoneID)) {
                        Text("System default").tag(String?.none)
                        ForEach(AVAudioSession.sharedInstance().availableInputs ?? [], id: \.uid) { port in Text(port.portName).tag(Optional(port.uid)) }
                        if let id = store.library.preferences.microphoneID, !(AVAudioSession.sharedInstance().availableInputs ?? []).contains(where: { $0.uid == id }) { Text("Saved input (currently unavailable)").tag(Optional(id)) }
                    }
                    Toggle("Recording feedback", isOn: preference(\.feedback))
                    Text("Recordings stop after 5 minutes. Audio route changes and interruptions cancel the session. Bluetooth input depends on the connected device.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Local history retention") {
                    Picker("Keep text & audio", selection: Binding(get: { store.library.preferences.retention }, set: { retention = $0 })) {
                        ForEach(RetentionPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                    }
                    Text("History keeps the raw, cleaned and final text, plus 16 kHz audio for Retry. Never keeps no dictation history or audio after processing; an active dictation and a temporary delivery result still exist. The delivery result becomes unusable after two minutes and is removed the next time Parla or the Parla keyboard runs. 24-hour deletion runs while Parla is active and at next entry. Notes and vocabulary stay until you delete them.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Privacy & help") {
                    Text("Speech is recognized on this iPhone. Text leaves it only when you choose a network cleanup provider. Per-app profiles are not available: an iOS keyboard cannot tell Parla which app you are typing in. No contacts or surrounding text are read.").font(.footnote)
                    ShareLink(item: "Parla feedback\nApp version 1.0\niOS \(UIDevice.current.systemVersion)\n\nDescribe what happened:\n") { Label("Share a feedback report", systemImage: "square.and.arrow.up") }
                }
            }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle("Settings")
                .confirmationDialog("Apply retention policy to all history now?", isPresented: Binding(get: { retention != nil }, set: { if !$0 { retention = nil } }), titleVisibility: .visible) {
                    Button("Apply \(retention?.title ?? "")") {
                        if let retention { var preferences = store.library.preferences; preferences.retention = retention; do { try store.savePreferences(preferences) } catch { store.error = error.localizedDescription } }; retention = nil
                    }
                }
        }
    }
    func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { store.library.preferences[keyPath: keyPath] }, set: { value in
            var preferences = store.library.preferences; preferences[keyPath: keyPath] = value
            do { try store.savePreferences(preferences) } catch { store.error = error.localizedDescription }
        })
    }
}

struct LocalAccountView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var clear = false
    var body: some View {
        Form {
            Section {
                ParlaMark(size: 36).padding(.vertical, 20)
                Text("Your space, on this iPhone.").font(.custom("EBGaramond-Regular", size: 28))
                Text("Parla has no sign-in, subscription, backup or sync service. Notes, history, settings and models stay in local storage. Reinstalling or losing this iPhone can lose your data.")
            }
            Section("Export") {
                ShareLink(item: store.exportText(settings: settings.current)) { Label("Export notes, history & settings as JSON", systemImage: "square.and.arrow.up") }
                Text("Export contains your saved text, vocabulary and preferences. API keys and audio are excluded.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Delete") {
                Button("Delete all local data & API keys", role: .destructive) { clear = true }.disabled(coordinator.busy)
                Text("This deletes notes, history, recordings, settings, vocabulary and saved API keys, and resets onboarding. Downloaded speech models stay until you delete them in Models.").font(.footnote).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(Color.paper)
            .confirmationDialog("Permanently delete all Parla data on this iPhone?", isPresented: $clear, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    coordinator.cancel()
                    do {
                        // Every key this app saved (all providers and endpoints); the app keychain holds nothing else.
                        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)
                        guard status == errSecSuccess || status == errSecItemNotFound else { throw ParlaError.message("Could not remove saved API keys. Unlock your iPhone and try again.") }
                        try store.mutate { $0 = Library() }; try store.sweepAudio()
                        try? FileManager.default.removeItem(at: settings.store.url)
                        settings.reset()
                        coordinator.lastResult = ""; coordinator.closeNoteEditor(); coordinator.route = "Home"
                    } catch { store.error = error.localizedDescription }
                }
            }
    }
}
