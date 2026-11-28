import AppKit
import SwiftUI
import ParlaCore

struct HubProfilesView: View {
    @ObservedObject var model: HubModel
    @State private var draft: DictationProfile?
    @State private var editingIndex: Int?
    @State private var previewBundle = ""
    @State private var previewURL = ""
    @State private var showTester = false
    @State private var hovered: Int?

    /// The app that currently shares nearby text with online cleanup, if any.
    private var sharingProfile: DictationProfile? {
        guard let policy = model.surroundingPolicy, policy.revision != nil else { return nil }
        return model.settings.profiles.first { $0.id == policy.profileID }
    }
    /// Apps that may share nearby text: enabled app profiles, never terminals or
    /// code editors (mirrors NativeSurroundingText).
    private var eligibleApps: [DictationProfile] {
        model.settings.profiles.filter {
            $0.targetKind == .app && $0.enabled && ![AppCategory.terminal, .code].contains(TextRules.category(bundleID: $0.target))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            ForEach(Array(ProfileResolver.warnings(model.settings.profiles).enumerated()), id: \.offset) { _, warning in
                HubBanner(text: warning, kind: .warning)
            }
            HubSection("Profiles",
                       footer: "A website profile wins over an app profile. Anything you leave unset uses your global settings. Website profiles work in supported browsers; subdomains need their own profile.",
                       accessory: { HubAddButton("Add Profile") { editingIndex = nil; draft = DictationProfile(); model.profileError = nil } }) {
                if model.settings.profiles.isEmpty {
                    EmptyHint(text: "No profiles yet", detail: "Add one to use a different style or engine in a specific app or website.")
                }
                ForEach(Array(model.settings.profiles.enumerated()), id: \.offset) { index, profile in
                    if index > 0 { HubDivider() }
                    profileRow(index, profile)
                    if (profile.recognitionEngine ?? model.settings.recognitionEngine) == .parakeet {
                        ParakeetControls(model: model, targetID: .profile(profile.id))
                            .padding(.horizontal, HubLayout.rowInset).padding(.bottom, 12)
                    }
                }
                HubDivider()
                HubDisclosureRow(title: "Check which settings apply", summary: "Test an app or website", isExpanded: $showTester)
                if showTester { tester }
            }
            if let error = model.profileError { HubBanner(text: error) }

            HubSection("Nearby text", footer: model.surroundingMessage
                       ?? "Text before the cursor helps cleanup get names and sentences right. It’s never saved. Password fields, terminals and code editors are always skipped.") {
                HubToggleRow("Use with Apple Intelligence", detail: "Stays on this Mac",
                             isOn: $model.settings.cleanup.localSurroundingTextEnabled)
                HubDivider()
                if let profile = sharingProfile {
                    HubRow("Send to online cleanup",
                           detail: (model.store.surroundingTextIsPaused ? "Paused for " : "On for ") + profile.name + ". About 256 characters before the cursor go with each dictation.") {
                        HStack(spacing: 8) {
                            if model.store.surroundingTextIsPaused {
                                Button("Turn On Again…") { model.reviewSurrounding(profileID: profile.id) }.buttonStyle(HubButtonStyle())
                            }
                            Button("Turn Off") { model.disableSurrounding(profileID: profile.id) }.buttonStyle(HubButtonStyle())
                        }
                    }
                } else if let policy = model.surroundingPolicy, policy.revision != nil {
                    HubRow("Send to online cleanup", detail: "On for \(policy.target)") {
                        Button("Turn Off") { model.disableSurrounding(profileID: policy.profileID) }.buttonStyle(HubButtonStyle())
                    }
                } else {
                    HubRow("Send to online cleanup", detail: eligibleApps.isEmpty
                           ? "Add an app profile to choose an app. About 256 characters before the cursor go with each dictation."
                           : "Off. Choose an app to send up to 256 characters before the cursor with each dictation.") {
                        Menu("Turn On For…") {
                            ForEach(eligibleApps) { profile in
                                Button(profile.name) { model.reviewSurrounding(profileID: profile.id) }
                            }
                        }
                        .menuStyle(.borderedButton).fixedSize()
                        .disabled(eligibleApps.isEmpty)
                    }
                }
                if let review = model.surroundingReview {
                    HubDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.surroundingDisclosure(review.policy))
                            .font(.system(size: 12)).foregroundStyle(Theme.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Send Nearby Text for This App") { model.confirmSurrounding() }
                                .buttonStyle(HubButtonStyle(kind: .primary))
                        }
                    }
                    .hubInset()
                }
            }
        }
        .sheet(item: $draft) { profile in
            ProfileEditor(model: model, initial: profile, index: editingIndex)
        }
    }

    private func profileRow(_ index: Int, _ profile: DictationProfile) -> some View {
        let edit = { editingIndex = index; draft = profile; model.profileError = nil }
        return HStack(spacing: 10) {
            ProfileIcon(profile: profile).opacity(profile.enabled ? 1 : 0.5)
            HubRow(profile.name, detail: summary(profile)) {
                HStack(spacing: 8) {
                    HubMoreMenu(label: "More actions for \(profile.name)") { rowActions(index, edit: edit) }
                        .modifier(HoverReveal(hovering: hovered == index))
                    Toggle("Use \(profile.name)", isOn: Binding(get: { profile.enabled }, set: { enabled in
                        var next = profile
                        next.enabled = enabled
                        model.saveProfile(next, replacing: index)
                    }))
                    .toggleStyle(.switch).labelsHidden()
                    .help(profile.enabled ? "Profile is on" : "Profile is off")
                }
            }
            .padding(.leading, -HubLayout.rowInset)
        }
        .padding(.leading, HubLayout.rowInset)
        .background(hovered == index ? Theme.border.opacity(0.35) : .clear) // the row itself opens the editor
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .contextMenu { rowActions(index, edit: edit) }
        .help("Click to edit · " + (profile.normalizedTarget ?? profile.target))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit", edit)
    }

    @ViewBuilder private func rowActions(_ index: Int, edit: @escaping () -> Void) -> some View {
        Button("Edit…", action: edit)
        Divider()
        Button("Move Up") { model.moveProfile(at: index, by: -1) }.disabled(index == 0)
        Button("Move Down") { model.moveProfile(at: index, by: 1) }
            .disabled(index + 1 == model.settings.profiles.count)
        Divider()
        Button("Delete", role: .destructive) { model.deleteProfile(at: index) }
    }

    @ViewBuilder private var tester: some View {
        let result = model.profilePreview(bundleID: previewBundle, browserURL: previewURL)
        HubDivider()
        HubRow("App bundle ID") {
            TextField("App bundle ID", text: $previewBundle, prompt: Text("com.apple.Safari")).hubField().hubControl()
        }
        HubDivider()
        HubRow("Web address", detail: "Optional") {
            TextField("Web address", text: $previewURL, prompt: Text("docs.google.com")).hubField().hubControl()
        }
        HubDivider()
        HubRow("Profile") { HubValue(result.name) }
        HubDivider()
        HubRow("Cleanup") {
            HubValue((result.settings.cleanupEnabled ? "On" : "Off") + " · " + result.settings.cleanupStyle.rawValue.capitalized)
        }
        HubDivider()
        HubRow("Language") { HubValue(languageName(result.settings.language)) }
        HubDivider()
        HubRow("Speech model") { HubValue(modelName(result.settings.whisperModelPath ?? WhisperTranscriber.defaultModelPath())) }
        HubDivider()
        HubRow("Cleanup model") { HubValue(result.settings.cleanupModelLabel) }
        if let recognition = model.lastRecognitionProfile, let output = model.lastOutputProfile {
            HubDivider()
            HubRow("Last dictation", detail: "Speech: \(recognition) · Output: \(output)")
        }
    }

    /// Only what differs from global settings; where it applies is in the tooltip.
    private func summary(_ profile: DictationProfile) -> String {
        var parts: [String] = []
        if profile.targetKind == .host {
            parts.append(profile.normalizedTarget ?? profile.target)
        } else {
            // Only a resolved app name that differs from the profile's own name adds anything.
            if let app = installedAppName(profile.target), app.caseInsensitiveCompare(profile.name) != .orderedSame { parts.append(app) }
        }
        if let style = profile.style { parts.append(style.rawValue.capitalized) }
        if profile.cleanup == .off { parts.append("Cleanup off") } else if profile.cleanup == .on { parts.append("Cleanup on") }
        if let engine = profile.recognitionEngine { parts.append(engine == .appleSpeech ? "Apple Speech" : engine.rawValue.capitalized) }
        return parts.isEmpty ? "Uses global settings" : parts.joined(separator: " · ")
    }

    private func installedAppName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func languageName(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "Auto-detect" }
        return WhisperTranscriber.languages.first { $0.code == code }?.name ?? code
    }

    private func modelName(_ path: String) -> String {
        ModelCatalog.all.first { ModelCatalog.path(for: $0) == path }?.hubName ?? URL(fileURLWithPath: path).lastPathComponent
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

    private var engine: RecognitionEngine { profile.recognitionEngine ?? model.settings.recognitionEngine }

    var body: some View {
        HubSheet(title: index == nil ? "New Profile" : "Edit Profile", width: 580) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HubSection("Where it applies") {
                        HubRow("Name") {
                            TextField("Profile name", text: $profile.name, prompt: Text("Slack")).hubField().hubControl()
                        }
                        HubDivider()
                        HubToggleRow("Enabled", isOn: $profile.enabled)
                        HubDivider()
                        HubRow("Applies to") {
                            Picker("Applies to", selection: $profile.targetKind) {
                                Text("An app").tag(ProfileTargetKind.app)
                                Text("A website").tag(ProfileTargetKind.host)
                            }
                            .hubControl()
                        }
                        HubDivider()
                        HubRow(profile.targetKind == .app ? "Bundle ID" : "Host name") {
                            TextField("Target", text: $profile.target,
                                      prompt: Text(profile.targetKind == .app ? "com.apple.TextEdit" : "mail.google.com"))
                                .hubField().hubControl()
                        }
                    }
                    HubSection("Cleanup") {
                        HubRow("AI cleanup") {
                            Picker("AI cleanup", selection: $profile.cleanup) {
                                Text("Same as global").tag(ProfileCleanup.inherit)
                                Text("Off (snippets still apply)").tag(ProfileCleanup.off)
                                Text("On").tag(ProfileCleanup.on)
                            }
                            .hubControl()
                        }
                        HubDivider()
                        HubRow("Style") {
                            Picker("Style", selection: $profile.style) {
                                Text("Same as global").tag(Optional<ProfileStyle>.none)
                                ForEach(ProfileStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                            }
                            .hubControl()
                        }
                        HubDivider()
                        HubRow("Cleanup model", detail: "Optional") {
                            TextField("Cleanup model", text: optBinding($profile.cleanupModel), prompt: Text("Same as global")).hubField().hubControl()
                        }
                    }
                    HubSection("Speech") {
                        HubRow("Engine") {
                            Picker("Speech engine", selection: $profile.recognitionEngine) {
                                Text("Same as global").tag(Optional<RecognitionEngine>.none)
                                Text("Whisper").tag(Optional(RecognitionEngine.whisper))
                                Text("Apple Speech").tag(Optional(RecognitionEngine.appleSpeech))
                                if profile.recognitionEngine == .parakeet || (!model.parakeetUnavailable && model.parakeetProfileChoiceRefusal == nil) {
                                    Text("Parakeet").tag(Optional(RecognitionEngine.parakeet))
                                }
                                if profile.recognitionEngine == .invalid { Text("Choose an engine").tag(Optional(RecognitionEngine.invalid)) }
                            }
                            .hubControl()
                        }
                        if engine == .parakeet {
                            HubDivider()
                            ParakeetSettingsFields(modelID: $profile.parakeetModelID, filter: $profile.parakeetLanguageFilter, inherits: true)
                            HubNote("Save the profile to install or prepare Parakeet for it.").hubInset()
                        }
                        HubDivider()
                        HubRow("Apple Speech language") {
                            AppleSpeechLocalePicker(label: "Apple Speech language", locale: $profile.appleSpeechLocale, noneLabel: "Same as global")
                        }
                        if engine == .appleSpeech {
                            HubNote("Save the profile before setting up its language.").hubInset().padding(.top, -6)
                            HubDivider()
                            AppleSpeechControls(model: model, locale: profile.appleSpeechLocale ?? model.settings.appleSpeechLocale)
                        }
                        if engine == .whisper {
                            HubDivider()
                            HubRow("Language") {
                                Picker("Language", selection: optBinding($profile.language)) {
                                    Text("Same as global").tag("")
                                    Text("Auto-detect").tag("auto")
                                    ForEach(WhisperTranscriber.languages, id: \.code) { Text($0.name).tag($0.code) }
                                }
                                .hubControl()
                            }
                            HubDivider()
                            HubRow("Whisper model") {
                                Picker("Whisper model", selection: optBinding($profile.whisperModelPath)) {
                                    Text("Same as global").tag("")
                                    ForEach(ModelCatalog.all.filter { ModelCatalog.isInstalled($0) }) {
                                        Text($0.hubName).tag(ModelCatalog.path(for: $0))
                                    }
                                    if let path = profile.whisperModelPath,
                                       !ModelCatalog.all.contains(where: { ModelCatalog.path(for: $0) == path && ModelCatalog.isInstalled($0) }) {
                                        Text(path).tag(path)
                                    }
                                }
                                .hubControl()
                            }
                            HubDivider()
                            HubRow("Custom model file", detail: "Optional path to a model of your own") {
                                TextField("Custom model file", text: optBinding($profile.whisperModelPath), prompt: Text("/path/to/model.bin"))
                                    .hubField().hubControl()
                            }
                        }
                    }
                    HubSection("Extra dictionary words", footer: "One per line. Added to your main dictionary in this app.") {
                        TextEditor(text: Binding(get: { profile.dictionary.joined(separator: "\n") }, set: {
                            profile.dictionary = $0.components(separatedBy: "\n")
                        }))
                        .hubEditor().frame(height: 90).hubInset()
                    }
                    if let error = model.profileError { HubBanner(text: error) }
                }
            }
            .frame(height: 520)
        } actions: {
            Button("Cancel") { dismiss() }.buttonStyle(HubButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Save Profile") {
                if model.saveProfile(profile, replacing: index) { dismiss() }
            }
            .buttonStyle(HubButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        }
        .onChange(of: profile) { new in
            model.surroundingProfileDraftChanged(from: profileAtLastObservation, to: new)
            profileAtLastObservation = new
            model.onParakeetDraftChanged()
        }
        .onDisappear { model.refreshPreparationConfiguration() }
    }
}

/// 20 pt app icon for app profiles, a globe for websites.
private struct ProfileIcon: View {
    let profile: DictationProfile
    var body: some View {
        Group {
            if profile.targetKind == .app,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.target) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: profile.targetKind == .app ? "app.dashed" : "globe")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
