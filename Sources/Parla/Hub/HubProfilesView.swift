import SwiftUI
import ParlaCore

struct HubProfilesView: View {
    @ObservedObject var model: HubModel
    @State private var draft: DictationProfile?
    @State private var editingIndex: Int?
    @State private var previewBundle = ""
    @State private var previewURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A website profile wins over an app profile. Anything you leave unset uses your global settings.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach(Array(ProfileResolver.warnings(model.settings.profiles).enumerated()), id: \.offset) { _, warning in
                HubBanner(text: warning)
            }
            HubSection("Profiles", footer: "Website profiles work in supported browsers. Subdomains need their own profile.") {
                ForEach(Array(model.settings.profiles.enumerated()), id: \.offset) { index, profile in
                    HubRow(profile.name, detail: (profile.targetKind == .app ? "App: " : "Website: ") + (profile.normalizedTarget ?? profile.target)) {
                        Toggle("Enabled", isOn: Binding(get: { profile.enabled }, set: { enabled in
                            var next = profile
                            next.enabled = enabled
                            model.saveProfile(next, replacing: index)
                        })).labelsHidden()
                        Button { model.moveProfile(at: index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                        Button { model.moveProfile(at: index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index + 1 == model.settings.profiles.count)
                        Button("Edit") { editingIndex = index; draft = profile; model.profileError = nil }
                        Button { model.deleteProfile(at: index) } label: { Image(systemName: "trash") }
                    }
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .parakeet {
                        ParakeetControls(model: model, targetID: .profile(profile.id))
                    }
                    HubDivider()
                }
                if model.settings.profiles.isEmpty { EmptyHint(text: "No profiles yet") }
            }
            HubSection("Nearby text", footer: "Text before the cursor helps cleanup get names and sentences right. It's never saved, and password fields and terminals are skipped.") {
                Toggle("Use nearby text with Apple Intelligence", isOn: $model.settings.cleanup.localSurroundingTextEnabled)
                Text("Stays on this Mac.").font(.caption).foregroundStyle(Theme.muted)
                Text("For online cleanup, turn it on per app below. About 256 characters before the cursor are then sent to your cleanup provider with each dictation.").font(.caption)
                Text(model.surroundingState).font(.headline)
                ForEach(model.settings.profiles.filter { $0.targetKind == .app && $0.enabled }) { profile in
                    HubRow(profile.name, detail: profile.target) {
                        Button("Turn on…") { model.reviewSurrounding(profileID: profile.id) }
                        Button("Turn off") { model.disableSurrounding(profileID: profile.id) }
                    }
                }
                if let review = model.surroundingReview {
                    Text(model.surroundingDisclosure(review.policy)).font(.caption).textSelection(.enabled)
                    Button("Send nearby text for this app") { model.confirmSurrounding() }
                }
                if let message = model.surroundingMessage { Text(message).font(.caption) }
            }
            Button("Add profile") { editingIndex = nil; draft = DictationProfile(); model.profileError = nil }
                .buttonStyle(HubButtonStyle())
            if let error = model.profileError { HubBanner(text: error) }
            HubSection("Test your profiles", footer: "Enter an app or web address to see which profile applies.") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("App bundle ID, e.g. com.apple.Safari", text: $previewBundle).hubField()
                    TextField("Web address (optional)", text: $previewURL).hubField()
                    let result = model.profilePreview(bundleID: previewBundle, browserURL: previewURL)
                    Text("Profile: \(result.name)").fontWeight(.medium)
                    Text("Cleanup: \(result.settings.cleanupEnabled ? "on" : "off") · Style: \(result.settings.cleanupStyle.rawValue) · Language: \(result.settings.language ?? "auto-detect")")
                    Text("Speech model: \(URL(fileURLWithPath: result.settings.whisperModelPath ?? WhisperTranscriber.defaultModelPath()).lastPathComponent)")
                    Text("Cleanup model: \(result.settings.cleanupModelLabel)")
                }.font(.system(size: 12)).padding(12).textSelection(.enabled)
            }
            if let recognition = model.lastRecognitionProfile, let output = model.lastOutputProfile {
                HubSection("Last dictation") {
                    HubRow("Speech", detail: recognition) { EmptyView() }
                    HubRow("Output", detail: output) { EmptyView() }
                }
            }
        }
        .sheet(item: $draft) { profile in
            ProfileEditor(model: model, initial: profile, index: editingIndex)
        }
    }
}

private struct ProfileEditor: View {
    @ObservedObject var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: DictationProfile
    @State private var profileAtLastObservation: DictationProfile
    let index: Int?

    init(model: HubModel, initial: DictationProfile, index: Int?) {
        self.model = model
        _profile = State(initialValue: initial)
        _profileAtLastObservation = State(initialValue: initial)
        self.index = index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(index == nil ? "Add profile" : "Edit profile").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Profile name", text: $profile.name).hubField()
                    Toggle("Enabled", isOn: $profile.enabled)
                    Picker("Target", selection: $profile.targetKind) {
                        Text("App (bundle ID)").tag(ProfileTargetKind.app)
                        Text("Website (host name)").tag(ProfileTargetKind.host)
                    }
                    TextField(profile.targetKind == .app ? "com.apple.TextEdit" : "mail.google.com", text: $profile.target).hubField()
                    Picker("AI cleanup", selection: $profile.cleanup) {
                        Text("Same as global").tag(ProfileCleanup.inherit)
                        Text("Off (snippets still apply)").tag(ProfileCleanup.off)
                        Text("On").tag(ProfileCleanup.on)
                    }
                    Picker("Style", selection: $profile.style) {
                        Text("Same as global").tag(Optional<ProfileStyle>.none)
                        ForEach(ProfileStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                    }
                    Picker("Speech engine", selection: $profile.recognitionEngine) {
                        Text("Same as global").tag(Optional<RecognitionEngine>.none)
                        Text("Whisper").tag(Optional(RecognitionEngine.whisper))
                        Text("Apple Speech").tag(Optional(RecognitionEngine.appleSpeech))
                        if profile.recognitionEngine == .parakeet || model.parakeetProfileChoiceRefusal == nil {
                            Text("Parakeet").tag(Optional(RecognitionEngine.parakeet))
                        }
                        if profile.recognitionEngine == .invalid { Text("Choose an engine").tag(Optional(RecognitionEngine.invalid)) }
                    }
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .parakeet {
                        ParakeetSettingsFields(modelID: $profile.parakeetModelID, filter: $profile.parakeetLanguageFilter, inherits: true)
                        Text("Save the profile to install or prepare Parakeet for it.").font(.caption)
                    }
                    TextField("Apple Speech language (optional)", text: optBinding($profile.appleSpeechLocale)).hubField()
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .appleSpeech {
                        Text("Save the profile before setting up its language.").font(.caption)
                        AppleSpeechControls(model: model, locale: profile.appleSpeechLocale ?? model.settings.appleSpeechLocale)
                    }
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .whisper {
                    Picker("Language", selection: optBinding($profile.language)) {
                        Text("Same as global").tag("")
                        Text("Auto-detect").tag("auto")
                        ForEach(WhisperTranscriber.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    Picker("Whisper model", selection: optBinding($profile.whisperModelPath)) {
                        Text("Same as global").tag("")
                        ForEach(ModelCatalog.all.filter { ModelCatalog.isInstalled($0) }) {
                            Text($0.displayName).tag(ModelCatalog.path(for: $0))
                        }
                        if let path = profile.whisperModelPath,
                           !ModelCatalog.all.contains(where: { ModelCatalog.path(for: $0) == path && ModelCatalog.isInstalled($0) }) {
                            Text(path).tag(path)
                        }
                    }
                    TextField("Custom model file (optional)", text: optBinding($profile.whisperModelPath)).hubField()
                    }
                    TextField("Cleanup model (optional)", text: optBinding($profile.cleanupModel)).hubField()
                    Text("Extra dictionary words, one per line").font(.caption)
                    TextEditor(text: Binding(get: { profile.dictionary.joined(separator: "\n") }, set: {
                        profile.dictionary = $0.components(separatedBy: "\n")
                    })).font(.system(size: 12)).frame(height: 100)
                    if let error = model.profileError { HubBanner(text: error) }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save profile") {
                    if model.saveProfile(profile, replacing: index) { dismiss() }
                }.buttonStyle(HubButtonStyle(kind: .primary))
            }
        }.padding(24).frame(width: 570, height: 680).background(Theme.bg)
        .onChange(of: profile) { new in
            model.surroundingProfileDraftChanged(from: profileAtLastObservation, to: new)
            profileAtLastObservation = new
            model.onParakeetDraftChanged()
        }
        .onDisappear { model.refreshPreparationConfiguration() }
    }
}
