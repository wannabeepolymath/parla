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
    var example = ""
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(example, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
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
        case .raw: return "As spoken"
        case .selectedPreset: return (try? settings.selectedTransformPreset().name) ?? "Preset not chosen"
        case .cleanup: return settings.cleanupEnabled ? ConsumerCopy.provider(settings.cleanup.provider) : "Basic cleanup"
        }
    }
    var body: some View {
        Form {
            Section {
                Picker("Output", selection: settings.binding(\.outputMode)) {
                    Text("Cleaned up").tag(DictationOutputMode.cleanup); Text("As spoken").tag(DictationOutputMode.raw); Text("Saved preset").tag(DictationOutputMode.selectedPreset)
                }
                if s.outputMode == .selectedPreset {
                    Picker("Preset", selection: settings.binding(\.selectedPresetID)) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(s.transformPresets) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if s.outputMode == .cleanup {
                    Toggle("Use AI cleanup", isOn: settings.binding(\.cleanupEnabled))
                    Picker("Style", selection: settings.binding(\.cleanupStyle)) {
                        Text("Standard").tag(ProfileStyle.standard); Text("Conversational").tag(ProfileStyle.conversational); Text("Formal").tag(ProfileStyle.formal)
                    }
                }
            } footer: {
                Text("As spoken keeps the words Parla recognized. Cleaned up removes fillers and fixes punctuation. Voice shortcuts and word replacements still work with AI cleanup off. If AI cleanup fails, Parla keeps the original transcript and explains why.")
            }
            Section {
                Picker("Provider", selection: Binding(get: { s.cleanup.provider }, set: { provider in settings.update { $0.cleanup.provider = provider; if provider == "apple-intelligence", $0.cleanup.localSourceLocale == nil { $0.cleanup.localSourceLocale = Locale.current.language.languageCode?.identifier } } })) {
                    Text("Apple Intelligence").tag("apple-intelligence"); Text("Anthropic").tag("anthropic"); Text("OpenAI or compatible service").tag("openai-compatible")
                }
                switch s.cleanup.provider {
                case "apple-intelligence":
                    Picker("Spoken language", selection: settings.binding(\.cleanup.localSourceLocale)) {
                        Text("Choose a language").tag(String?.none)
                        if let code = s.cleanup.localSourceLocale, !WhisperTranscriber.languages.contains(where: { $0.code == code }) {
                            Text(ConsumerCopy.language(code)).tag(Optional(code))
                        }
                        ForEach(WhisperTranscriber.languages, id: \.code) { Text($0.name).tag(Optional($0.code)) }
                    }
                case "openai-compatible":
                    CommitField(title: "Service address", example: "https://api.example.com/v1", value: s.cleanup.baseURL ?? "") { value in settings.update { $0.cleanup.baseURL = value.isEmpty ? nil : value } }
                    CommitField(title: "Model ID (optional)", example: "gpt-4.1-mini", value: s.cleanup.model ?? "") { value in settings.update { $0.cleanup.model = value.isEmpty ? nil : value } }
                    keyControls
                default:
                    CommitField(title: "Model ID", example: "claude-haiku-4-5", value: s.cleanupModel) { value in settings.update { $0.cleanupModel = value.isEmpty ? Settings().cleanupModel : value } }
                    keyControls
                }
                if let issue = cleanupConfigurationIssue(settings: s, env: [:], credentials: settings.store.credentials) { Text(ConsumerCopy.message(issue)).font(.footnote).foregroundStyle(.red) }
            } header: { Text("Provider") } footer: {
                Text("Apple Intelligence runs on this iPhone when available and enabled. Online providers receive your transcript, dictionary and snippets through a secure connection. They use your API key and may charge for use. Their data use and retention policies apply. Keys are stored securely on this iPhone and are never shared with the keyboard, widgets or exports. Audio stays on this iPhone.")
            }
            Section("Saved presets") {
                ForEach(s.transformPresets) { preset in NavigationLink(preset.name) { PresetEditor(preset: preset) } }
                NavigationLink("New preset") { PresetEditor(preset: TransformPreset()) }
            }
        }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle("Cleanup")
            .alert("API key", isPresented: Binding(get: { status != nil }, set: { if !$0 { status = nil } })) { Button("OK") { status = nil } } message: { Text(status ?? "") }
    }
    @ViewBuilder var keyControls: some View {
        Text(ConsumerCopy.message(cleanupCredentialSource(settings: s, env: [:], credentials: settings.store.credentials))).font(.footnote).foregroundStyle(.secondary)
        SecureField(s.cleanup.provider == "openai-compatible" ? "API key (optional)" : "API key", text: $key).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Save key") { changeKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove key", role: .destructive) { changeKey(nil) }
    }
    func changeKey(_ value: String?) {
        do {
            try settings.store.changeCredential(scope: CredentialScope.selected(s), replacement: value)
            key = ""; status = value == nil ? "Key removed from this iPhone." : "Key saved securely on this iPhone. No test request was sent."
            settings.reload()
        } catch { status = ConsumerCopy.message((error as? CredentialFailure)?.description ?? "The key could not be changed.") }
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
                        .accessibilityLabel("How should Parla rewrite your words?")
                    Toggle("Keep the spoken language (Apple Intelligence)", isOn: Binding(get: { preset.localPreserveSourceLanguage ?? false }, set: { preset.localPreserveSourceLanguage = $0 ? true : nil }))
                } else { TextField("Translate into (e.g. French)", text: $preset.targetLanguage) }
            } footer: { Text("Choose Saved preset in Output to apply this to every dictation. Describe how you want your words rewritten, or choose a translation language. Parla treats your speech as text to edit.") }
            if let problem = preset.validationError { Section { Text(ConsumerCopy.message(problem)).foregroundStyle(.secondary) } }
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
                    Text("Keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard → Parla. Then enable Allow Full Access so the keyboard can share dictation requests and results with Parla. The keyboard cannot record audio or send what you type. You can type without Full Access.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Audio & feedback") {
                    LabeledContent("Microphone permission", value: AVAudioApplication.shared.recordPermission == .granted ? "Allowed" : "Not allowed")
                    Picker("Microphone", selection: preference(\.microphoneID)) {
                        Text("Automatic").tag(String?.none)
                        ForEach(AVAudioSession.sharedInstance().availableInputs ?? [], id: \.uid) { port in Text(port.portName).tag(Optional(port.uid)) }
                        if let id = store.library.preferences.microphoneID, !(AVAudioSession.sharedInstance().availableInputs ?? []).contains(where: { $0.uid == id }) { Text("Saved microphone (unavailable)").tag(Optional(id)) }
                    }
                    Toggle("Recording feedback", isOn: preference(\.feedback))
                    Text("Recordings stop after 5 minutes. Changing microphones or an interruption from another app cancels dictation. Bluetooth input depends on the connected device.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Keep history") {
                    Picker("Keep text & audio", selection: Binding(get: { store.library.preferences.retention }, set: { retention = $0 })) {
                        ForEach(RetentionPolicy.allCases) { policy in Text(policy.title).tag(policy) }
                    }
                    Text("History saves your original and edited text, plus recordings so you can retry. With Never, no history or audio is saved after processing. Parla still keeps the latest result for two minutes so you can use it. After that, the result cannot be used and is deleted when Parla or its keyboard next opens. With 24 hours, older dictations are deleted while Parla is open or when you next open it. Notes and vocabulary stay until you delete them.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Privacy & help") {
                    Text("Speech is recognized on this iPhone. Your transcript, dictionary and snippets leave it only when you use an online cleanup provider. Settings apply across apps because the keyboard cannot tell Parla which app you are using. No contacts or surrounding text are read.").font(.footnote)
                    ShareLink(item: "Parla feedback\nApp version 1.0\niOS \(UIDevice.current.systemVersion)\n\nDescribe what happened:\n") { Label("Share a feedback report", systemImage: "square.and.arrow.up") }
                }
            }.scrollContentBackground(.hidden).background(Color.paper).navigationTitle("Settings")
                .confirmationDialog("Apply this choice to all saved dictations now?", isPresented: Binding(get: { retention != nil }, set: { if !$0 { retention = nil } }), titleVisibility: .visible) {
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
                ShareLink(item: store.exportText(settings: settings.current)) { Label("Export notes, history & settings", systemImage: "square.and.arrow.up") }
                Text("Export includes saved text, vocabulary and preferences. API keys and recordings are excluded. The file uses a structured format for keeping a copy of your data; it may show technical setting names. Only share it with someone you trust.").font(.footnote).foregroundStyle(.secondary)
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

/// iOS display labels only. Persisted values and shared desktop copy are unchanged.
enum ConsumerCopy {
    static func language(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? "Other language"
    }
    static func modelName(_ model: ModelCatalog.Model) -> String {
        switch model.id {
        case "base.en": return "Base (English)"
        case "small.en-q5_1": return "Small (English)"
        case "large-v3-turbo-q5_0": return "Large v3 Turbo (Multilingual)"
        default: return "Whisper"
        }
    }
    static func provider(_ value: String) -> String {
        switch value {
        case "", "anthropic": return "Anthropic"
        case "apple-intelligence": return "Apple Intelligence"
        case "openai-compatible": return "OpenAI or compatible service"
        default: return "Other provider"
        }
    }
    static func message(_ value: String) -> String {
        let labels = [
            "Apple Intelligence needs macOS 26 or later.": "Apple Intelligence needs iOS 26 or later.",
            "Apple Intelligence isn’t available on this Mac.": "Apple Intelligence isn’t available on this iPhone.",
            "Apple Intelligence is off in System Settings.": "Apple Intelligence is off in iPhone Settings.",
            "Check the cleanup service and base URL.": "Check your cleanup provider and service address.",
            "Choose a cleanup service and base URL first.": "Choose a cleanup provider and enter its service address first.",
            "Your API key needs to move to Keychain. Click Refresh or save the key again.": "Save your API key again to store it securely on this iPhone.",
            "Key stored in Keychain.": "API key saved securely on this iPhone.",
            "No key saved. Local servers may not need one.": "No API key saved. Your provider may require one.",
            "Keychain access was denied. In Keychain Access, delete \"com.parla.provider-credentials.v1\", then add your key again.": "Parla could not access your saved API key. Unlock your iPhone and try again, or save the key again.",
            "Keychain access was canceled. Try again.": "Access to your saved API key was cancelled. Try again.",
            "Enter a preset name (up to 120 characters).": "Enter a short preset name.",
            "Enter an instruction (it can’t be empty or very long).": "Describe how you want your words rewritten. Keep it brief.",
            "Enter a target language.": "Choose a language to translate into.",
            "Couldn’t confirm the language. Check the language in AI Cleanup.": "Choose your spoken language in Cleanup."
        ]
        return labels.reduce(value) { result, label in result.replacingOccurrences(of: label.key, with: label.value) }
    }
}
