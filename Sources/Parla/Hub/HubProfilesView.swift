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
            Text("Exact browser host → exact app → global settings. One winner; unset fields inherit globals. Recognition is chosen at capture start. Output is chosen at landing.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach(Array(ProfileResolver.warnings(model.settings.profiles).enumerated()), id: \.offset) { _, warning in
                HubBanner(text: warning)
            }
            HubSection("Profiles", footer: "Saved order breaks ties in hand-edited files. Site rules require a recognized browser and an available HTTP(S) URL. Bundle IDs are case-sensitive; hosts ignore case and one trailing dot. Subdomains are separate targets.") {
                ForEach(Array(model.settings.profiles.enumerated()), id: \.offset) { index, profile in
                    HubRow(profile.name, detail: "\(profile.targetKind.rawValue): \(profile.normalizedTarget ?? profile.target)") {
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
                if model.settings.profiles.isEmpty { EmptyHint(text: "No profiles — global settings apply") }
            }
            HubSection("Surrounding text source experiment", footer: "Default off. Review one saved app profile; browser/site/global profiles cannot opt in. Review never samples a field or reads credentials.") {
                Text(model.surroundingState).font(.headline)
                ForEach(model.settings.profiles.filter { $0.targetKind == .app && $0.enabled }) { profile in
                    HubRow(profile.name, detail: profile.target) {
                        Button("Review") { model.reviewSurrounding(profileID: profile.id) }
                        Button("Disable") { model.disableSurrounding(profileID: profile.id) }
                    }
                }
                if let review = model.surroundingReview {
                    Text(model.surroundingDisclosure(review.policy)).font(.caption).textSelection(.enabled)
                    Button("Confirm reviewed scope for future captures") { model.confirmSurrounding() }
                }
                if let message = model.surroundingMessage { Text(message).font(.caption) }
            }
            Button("Add profile") { editingIndex = nil; draft = DictationProfile(); model.profileError = nil }
                .buttonStyle(HubButtonStyle())
            if let error = model.profileError { HubBanner(text: error) }
            HubSection("Resolver preview", footer: "Enter a target explicitly. This does not read the Hub's frontmost app, load a model, or contact a provider. URLs stay local; only the host is matched.") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Bundle ID, e.g. com.apple.Safari", text: $previewBundle).hubField()
                    TextField("Optional HTTP(S) URL", text: $previewURL).hubField()
                    let result = model.profilePreview(bundleID: previewBundle, browserURL: previewURL)
                    Text("Winner: \(result.name)").fontWeight(.medium)
                    Text("Cleanup: \(result.settings.cleanupEnabled ? "on if configured" : "off") · Style: \(result.settings.cleanupStyle.rawValue) · Language: \(result.settings.language ?? "auto")")
                    Text("ASR model: \(result.settings.whisperModelPath ?? WhisperTranscriber.defaultModelPath())")
                    Text("Cleanup model: \(result.settings.cleanupModelLabel)")
                    Text("Hints selected: \(VocabularyHints.select(result.settings.dictionary, byteLimit: VocabularyHints.asrBytes).count) ASR / \(VocabularyHints.select(result.settings.dictionary, byteLimit: VocabularyHints.cleanupBytes).count) cleanup")
                }.font(.system(size: 12)).padding(12).textSelection(.enabled)
            }
            if let recognition = model.lastRecognitionProfile, let output = model.lastOutputProfile {
                HubSection("Last session") {
                    HubRow("Recognition", detail: recognition) { EmptyView() }
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
                        Text("Exact app bundle ID").tag(ProfileTargetKind.app)
                        Text("Exact browser host").tag(ProfileTargetKind.host)
                    }
                    TextField(profile.targetKind == .app ? "com.apple.TextEdit" : "mail.google.com", text: $profile.target).hubField()
                    Picker("AI cleanup", selection: $profile.cleanup) {
                        Text("Inherit global").tag(ProfileCleanup.inherit)
                        Text("Off — local snippets and replacements").tag(ProfileCleanup.off)
                        Text("On — requires global provider setup").tag(ProfileCleanup.on)
                    }
                    Picker("Style", selection: $profile.style) {
                        Text("Inherit global").tag(Optional<ProfileStyle>.none)
                        ForEach(ProfileStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                    }
                    Picker("Recognition engine", selection: $profile.recognitionEngine) {
                        Text("Inherit global").tag(Optional<RecognitionEngine>.none)
                        Text("Whisper").tag(Optional(RecognitionEngine.whisper))
                        Text("Apple Speech · batch").tag(Optional(RecognitionEngine.appleSpeech))
                        if profile.recognitionEngine == .parakeet || model.parakeetProfileChoiceRefusal == nil {
                            Text("Parakeet · local batch").tag(Optional(RecognitionEngine.parakeet))
                        }
                        if profile.recognitionEngine == .invalid { Text("Invalid configuration").tag(Optional(RecognitionEngine.invalid)) }
                    }
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .parakeet {
                        ParakeetSettingsFields(modelID: $profile.parakeetModelID, filter: $profile.parakeetLanguageFilter, inherits: true)
                        Text("Save the profile before using its saved-row installation and preparation controls.").font(.caption)
                    }
                    TextField("Exact Apple locale (empty inherits)", text: optBinding($profile.appleSpeechLocale)).hubField()
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .appleSpeech {
                        Text("Save the profile before preparing its language. Words apply to cleanup only. Inherited Apple with legacy Whisper overrides needs an explicit Whisper engine or replacement Apple locale.").font(.caption)
                        AppleSpeechControls(model: model, locale: profile.appleSpeechLocale ?? model.settings.appleSpeechLocale)
                    }
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .whisper {
                    Picker("Whisper spoken language", selection: optBinding($profile.language)) {
                        Text("Inherit global").tag("")
                        Text("Auto — follow speaker").tag("auto")
                        ForEach(WhisperTranscriber.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    Picker("Local ASR model", selection: optBinding($profile.whisperModelPath)) {
                        Text("Inherit global").tag("")
                        ForEach(ModelCatalog.all.filter { ModelCatalog.isInstalled($0) }) {
                            Text($0.displayName).tag(ModelCatalog.path(for: $0))
                        }
                        if let path = profile.whisperModelPath,
                           !ModelCatalog.all.contains(where: { ModelCatalog.path(for: $0) == path && ModelCatalog.isInstalled($0) }) {
                            Text(path).tag(path)
                        }
                    }
                    TextField("Existing local model path (empty inherits)", text: optBinding($profile.whisperModelPath)).hubField()
                    }
                    TextField("Cleanup model ID in current provider (empty inherits)", text: optBinding($profile.cleanupModel)).hubField()
                    Text("Ordered words — one per line, ahead of globals").font(.caption)
                    TextEditor(text: Binding(get: { profile.dictionary.joined(separator: "\n") }, set: {
                        profile.dictionary = $0.components(separatedBy: "\n")
                    })).font(.system(size: 12)).frame(height: 100)
                    Text("No downloads or provider changes. English-only models ignore language. Saved words are preserved; shared UTF-8 budgets and deduplication apply. Destination and single-line constraints take precedence over style.")
                        .font(.caption).foregroundStyle(Theme.muted)
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
