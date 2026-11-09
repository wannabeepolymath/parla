import AppKit
import ParlaCore
import SwiftUI

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var model: HubModel
    private let permissionTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Tracks the warm-mic toggle below, so the permissions row never promises a
    /// closed mic the app is actually holding open (or vice versa).
    private var micDetail: String {
        model.settings.warmMic ? "Stays on between dictations so recording starts instantly"
            : "Used only while you dictate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HubSection("Permissions") {
                permissionRow("Microphone", granted: model.micGranted,
                              pane: "Privacy_Microphone", detail: micDetail)
                HubDivider()
                permissionRow("Accessibility", granted: model.axGranted,
                              pane: "Privacy_Accessibility",
                              detail: "Needed for shortcuts and typing into apps")
            }

            if let problem = model.downloadError {
                HubBanner(text: problem)
            }
            HubSection("Speech recognition", footer: model.settings.recognitionEngine == .whisper || model.recognitionCapabilityDetail.isEmpty ? nil : model.recognitionCapabilityDetail) {
                HubRow("Engine") {
                    Picker("", selection: $model.settings.recognitionEngine) {
                        Text("Whisper").tag(RecognitionEngine.whisper)
                        Text("Apple Speech").tag(RecognitionEngine.appleSpeech)
                        if model.settings.recognitionEngine == .parakeet || model.parakeetChoiceRefusal == nil {
                    Text("Parakeet").tag(RecognitionEngine.parakeet)
                }
                if model.settings.recognitionEngine == .invalid { Text("Choose an engine").tag(RecognitionEngine.invalid) }
                    }.labelsHidden()
                }
                if model.settings.recognitionEngine == .parakeet { ParakeetGlobalControls(model: model) }
                else if model.parakeetChoiceRefusal == nil {
                    DisclosureGroup("Parakeet model") { ParakeetControls(model: model) }
                }
                if model.settings.recognitionEngine == .parakeet, let reason = model.parakeetChoiceRefusal { Text(reason.message).font(.caption) }
                if model.settings.recognitionEngine == .appleSpeech {
                    TextField("Language, e.g. en-US", text: optBinding($model.settings.appleSpeechLocale)).hubField()
                    AppleSpeechControls(model: model)
                }
            }
            if model.settings.recognitionEngine == .whisper {
            HubSection("Whisper model") {
                ForEach(ModelCatalog.all) { m in
                    if m.id != ModelCatalog.all.first?.id { HubDivider() }
                    HubRow(m.displayName, detail: m.sizeLabel) {
                        modelControl(m)
                    }
                }
                HubDivider()
                HubRow("Language", detail: englishOnlyModel ? "This model understands English only" : nil) {
                    Picker("", selection: optBinding($model.settings.language)) {
                        Text("Auto-detect").tag("")
                        Divider()
                        ForEach(WhisperTranscriber.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .disabled(englishOnlyModel)
                }
            }

            }
            HubSection("Live preview") {
                HubRow("Show text while recording", detail: "Draft text appears in the pill; the final text may differ") {
                    Toggle("", isOn: $model.settings.streamPreviewEnabled).labelsHidden()
                }
                HubDivider()
                HubRow("Preview model", detail: "Choose a smaller downloaded model for faster drafts") {
                    Picker("", selection: optBinding($model.settings.recognitionPreviewModelID)) {
                        Text("Same as dictation").tag("")
                        ForEach(model.recognitionPreviewChoices) { entry in Text(entry.displayName).tag(entry.id) }
                        if let id = model.recognitionPreviewUnavailableID { Text("Not downloaded · \(id)").tag(id) }
                    }.labelsHidden().frame(width: 240)
                }
            }
            HubSection("App") {
                HubRow("Launch at login") {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { _ in model.toggleLaunchAtLogin() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Always show the pill",
                       detail: "Keep the dictation pill on screen when idle") {
                    Toggle("", isOn: $model.settings.showHudAlways)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Idle pill size") {
                    Picker("", selection: $model.settings.hudIdleSize) {
                        Text("Small").tag("small")
                        Text("Medium").tag("medium")
                        Text("Large").tag("large")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 210)
                }
                HubDivider()
                // Labelled by consequence, not mechanism: the orange dot is the
                // thing users will actually notice.
                HubRow("Start dictation instantly",
                       detail: "Keeps the mic on so no words are cut off. The orange mic dot stays lit.") {
                    Toggle("", isOn: $model.settings.warmMic)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Microphone") {
                    Picker("", selection: optBinding($model.settings.inputDeviceUID)) {
                        Text("System default").tag("")
                        ForEach(micOptions, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                HubDivider()
                HubRow("Activity analysis", detail: "Adds speech timing to Diagnostics. Doesn't change results.") {
                    Toggle("", isOn: $model.settings.energyActivityShadowEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow("Settings file", detail: "Edit settings.json directly") {
                    Button("Open file") { model.onOpenSettingsFile() }
                        .buttonStyle(HubButtonStyle())
                }
            }

            if let problem = model.hotkeyError {
                HubBanner(text: problem)
            }
            HubSection("Shortcuts", footer: "Click Change, then press the new keys. Esc cancels.") {
                shortcutRow("Push to talk", "Hold to dictate",
                            \.pushToTalk, modifierOnly: true)
                HubDivider()
                shortcutRow("Hands-free mode",
                            "Press while holding push to talk. Press again, Space or Return to stop.",
                            \.handsFree)
                HubDivider()
                HubRow("Command mode", detail: "Edit selected text by voice") {
                    ShortcutPill(text: model.commandShortcutDisplay)
                }
                HubDivider()
                shortcutRow("Paste last dictation", nil, \.pasteLast)
                HubDivider()
                shortcutRow("Open Scratchpad", "A private place to dictate and edit", \.openScratchpad)
                HubDivider()
                HubRow("Run selected preset", detail: "Apply your selected preset to highlighted text") {
                    ShortcutRecorder(model: model, optionalPath: \.runSelectedPreset)
                }
                HubDivider()
                HubRow("Mouse push to talk", detail: model.settings.mouseBinding.map {
                    $0.buttonNumber == 2 ? "Hold the middle button to dictate. Its normal click won't work."
                        : "Hold \($0.display) to dictate. Its normal action, like Back, won't work."
                }) {
                    Picker("Mouse push to talk", selection: Binding(
                        get: { model.settings.mouseBinding?.buttonNumber ?? 0 },
                        set: { model.settings.mouseBinding = MouseButtonBinding(buttonNumber: $0) })) {
                        Text("Off").tag(0)
                        Text("Middle").tag(2)
                        ForEach(3...15, id: \.self) { number in Text("Button \(number + 1)").tag(number) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                if let problem = model.settings.mouseBindingProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                if model.settings.mouseBinding != nil, model.inputTapStatus != .ready {
                    HStack {
                        Text(model.inputTapStatus.message)
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { model.onRetryInput() }
                    }
                }
                HubDivider()
                HubRow("Cancel", detail: "Stop dictation or close a notification") {
                    ShortcutPill(text: "Esc")
                }
            }
        }
        .onReceive(permissionTick) { _ in model.refreshPermissions() }
    }

    private func shortcutRow(_ label: String, _ detail: String?,
                             _ path: WritableKeyPath<HotkeyBindings, KeyChord>,
                             modifierOnly: Bool = false) -> some View {
        HubRow(label, detail: detail) {
            ShortcutRecorder(model: model, path: path, modifierOnly: modifierOnly)
        }
    }

    /// The catalog's English-only models carry it in their name. A model of the
    /// user's own is unknown, so the picker stays live for it.
    private var englishOnlyModel: Bool {
        model.recognitionCapabilities.modelLanguages == .englishOnly
    }

    /// Live input devices, plus the saved device if it's currently unplugged —
    /// so the picker still shows the user's choice instead of blanking.
    private var micOptions: [AudioRecorder.InputDevice] {
        var devices = AudioRecorder.availableInputs()
        if let uid = model.settings.inputDeviceUID, !uid.isEmpty,
           !devices.contains(where: { $0.uid == uid }) {
            devices.append(.init(uid: uid, name: "Disconnected device"))
        }
        return devices
    }

    /// Downloading / not here / selected / on disk. Only one download runs at
    /// a time, so the other Download buttons go while it does — but the
    /// installed rows keep their state, or a download hides which model is in
    /// use. "Installed" is file existence only: hashing three models on every
    /// render is exactly ghost-pepper #163.
    @ViewBuilder
    private func modelControl(_ m: ModelCatalog.Model) -> some View {
        if let row = model.catalogDownloads[m.id], row.phase != .installed || ModelCatalog.isInstalled(m) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(row.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                if row.active { ProgressView(value: Double(row.percent) / 100).frame(width: 120) }
                HStack {
                    ForEach(row.actions, id: \.rawValue) { action in
                        Button(action.rawValue) { model.onCatalogDownloadAction(action, m) }
                            .buttonStyle(HubButtonStyle())
                            .disabled(!row.active && model.downloadingModel != nil)
                    }
                }
                if row.phase == .installed {
                    if model.isSelected(m) {
                        StatusChip(text: model.modelLoaded ? "In use" : "Selected",
                                   color: model.modelLoaded ? Theme.success : Theme.danger)
                    } else {
                        Button("Use") { model.selectModel(m) }.buttonStyle(HubButtonStyle())
                    }
                }
            }
        } else if !ModelCatalog.isInstalled(m) {
            if model.downloadingModel == nil {
                Button("Download") { model.onDownloadModel(m) }
                    .buttonStyle(HubButtonStyle(kind: model.isSelected(m) ? .primary : .normal))
            }
        } else if model.isSelected(m) {
            StatusChip(text: model.modelLoaded ? "In use" : "Selected",
                       color: model.modelLoaded ? Theme.success : Theme.danger)
        } else {
            Button("Use") { model.selectModel(m) }
                .buttonStyle(HubButtonStyle())
        }
    }

    private func permissionRow(_ name: String, granted: Bool, pane: String,
                               detail: String) -> some View {
        HubRow(name, detail: detail) {
            if granted {
                StatusChip(text: "Granted")
            } else {
                Button("Open System Settings") { model.openPrivacyPane(pane) }
                    .buttonStyle(HubButtonStyle())
            }
        }
    }
}

/// Records the next keypress into one binding. A local monitor is enough — the
/// Hub window is key while recording — but the global tap has to stand down for
/// the duration or it swallows the very chords being re-recorded.
struct ShortcutRecorder: View {
    @ObservedObject var model: HubModel
    let path: WritableKeyPath<HotkeyBindings, KeyChord>?
    let optionalPath: WritableKeyPath<HotkeyBindings, KeyChord?>?
    /// Push to talk is *held*, so it records a bare modifier off flagsChanged;
    /// every other binding waits for a real key press.
    var modifierOnly = false
    @State private var lease: CaptureAdmission.Lease?
    @State private var monitor: Any?
    /// One armed row at a time. The invocation host owns its admission and
    /// hotkey suspension tokens, so a late row stop cannot release another owner.
    private static var disarm: (() -> Void)?

    init(model: HubModel, path: WritableKeyPath<HotkeyBindings, KeyChord>, modifierOnly: Bool = false) {
        self.model = model; self.path = path; optionalPath = nil; self.modifierOnly = modifierOnly
    }

    init(model: HubModel, optionalPath: WritableKeyPath<HotkeyBindings, KeyChord?>) {
        self.model = model; path = nil; self.optionalPath = optionalPath
    }

    private var chord: KeyChord? {
        if let path { return model.settings.hotkeys[keyPath: path] }
        if let optionalPath { return model.settings.hotkeys[keyPath: optionalPath] }
        return nil
    }
    private var original: KeyChord? { path.map { HotkeyBindings()[keyPath: $0] } }

    var label: String { monitor == nil ? model.shortcutDisplay(chord) : "Press keys…" }

    var body: some View {
        HStack(spacing: 8) {
            ShortcutPill(text: label)
            Button(monitor == nil ? "Change" : "Cancel") {
                if monitor == nil { start() } else { stop() }
            }
            .buttonStyle(HubButtonStyle())
            if chord != original {
                Button(optionalPath == nil ? "Reset" : "Clear") {
                    stop()
                    if let path, let original { model.setHotkey(path, to: original) }
                    if let optionalPath { model.setOptionalHotkey(optionalPath, to: nil) }
                }
                .buttonStyle(HubButtonStyle())
            }
        }
        .onDisappear(perform: stop)
        // The local monitor only hears keys while the Hub is key, so "Change"
        // followed by a click into another app — or closing the window, which
        // never fires onDisappear (see OnboardingView) — left the global tap
        // suspended and every hotkey dead until the Hub was reopened. Any
        // window, on purpose: stop() is idempotent and a stray one is harmless.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stop()
        }
    }

    private func start() {
        Self.disarm?()
        guard let acquired = model.onShortcutBegin() else {
            model.hotkeyError = "Finish the microphone test or recording first."; return
        }
        lease = acquired
        Self.disarm = { stop() }
        model.hotkeyError = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let code = UInt16(event.keyCode)
            let mods = KeyChord.Modifiers(event.modifierFlags)
            if event.type == .keyDown {
                if code == 53 {
                    stop() // Esc: give up, keep the binding that's there
                } else {
                    // A plain key in modifier-only mode is recorded as-is and
                    // refused by validation, which explains why better than
                    // silently ignoring it would.
                    commit(KeyChord(code, modifierOnly ? [] : mods))
                }
            } else if modifierOnly, let m = KeyChord.modifierKey(code), mods.contains(m) {
                commit(KeyChord(code)) // press, not release
            }
            return nil // swallow: the recorded chord must not also act on the Hub
        }
    }

    private func commit(_ chord: KeyChord) {
        stop()
        if let path { model.setHotkey(path, to: chord) }
        if let optionalPath { model.setOptionalHotkey(optionalPath, to: chord) }
    }

    /// No-op unless this row is the armed one — every row hears onDisappear and
    /// the resign-key notification, and only the armed one owns the flag.
    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        Self.disarm = nil
        if let lease { model.onShortcutEnd(lease) }; lease = nil
    }
}

// MARK: - AI Cleanup

struct CleanupPage: View {
    @ObservedObject var model: HubModel

    private var isAnthropic: Bool { ["", "anthropic"].contains(model.settings.cleanup.provider) }
    private var isLocal: Bool { model.settings.usesAppleIntelligence }

    private var configIssue: String? { model.credentialIssue }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let issue = configIssue {
                HubBanner(text: "Cleanup is off: \(issue)")
            }
            HubSection("Provider",
                       footer: "If cleanup fails, Parla inserts your original text.") {
                HubRow("Service") {
                    Picker("", selection: $model.settings.cleanup.provider) {
                        Text("Anthropic").tag("anthropic")
                        Text("OpenAI-compatible").tag("openai-compatible")
                        Text("Apple Intelligence (on this Mac)").tag("apple-intelligence")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 300)
                }
            }

            if isLocal {
                HubSection("Apple Intelligence", footer: "Runs on this Mac. Works with one language at a time; translation isn't supported.") {
                    Text(model.localCleanupStatus?.message ?? "Apple Intelligence is ready.")
                        .font(.caption).padding(12)
                    HubRow("Language", detail: "The language you dictate in") {
                        TextField("e.g. en or hi", text: optBinding($model.settings.cleanup.localSourceLocale)).hubField().frame(width: 240)
                    }
                    Button("Check again", action: model.recheckLocalCleanup).padding(12)
                }
                HubSection("Saved API keys", footer: "Moves API keys saved in settings.json into Keychain.") {
                    Button("Move keys to Keychain", action: model.retryCredentialMigration).padding(12)
                    if let message = model.credentialMessage { Text(message).font(.caption) }
                }
            } else if isAnthropic {
                HubSection("Anthropic") {
                    HubRow("Model") {
                        TextField("claude-sonnet-5", text: $model.settings.cleanupModel)
                            .hubField().frame(width: 260)
                    }
                    HubDivider()

                }
            } else {
                HubSection("Server",
                           footer: "Any OpenAI-compatible server, online or local. Leave the key empty if it doesn't need one.") {
                    HubRow("Base URL") {
                        TextField("https://api.example.com/v1",
                                  text: optBinding($model.settings.cleanup.baseURL))
                            .hubField().frame(width: 260)
                    }
                    HubDivider()
                    HubRow("Model", detail: "Optional. Leave empty to use the server's default.") {
                        TextField("openai/gpt-oss-120b",
                                  text: optBinding($model.settings.cleanup.model))
                            .hubField().frame(width: 260)
                    }
                    HubDivider()

                }
            }

            if !isLocal {
            HubSection("API key", footer: model.credentialStatus) {
                HubRow("API key", detail: "Stored in Keychain. Leave blank to keep the current key.") {
                    SecureField("New key…", text: $model.credentialDraft).hubField().frame(width: 260)
                }
                HStack {
                    Button("Save", action: model.saveCredential).disabled(model.credentialDraft.isEmpty)
                    Button("Remove", action: model.removeCredential)
                    Button("Refresh", action: model.retryCredentialMigration)
                }
                if let message = model.credentialMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }

            }

            CleanupFailoverSection(model: model)

            // Absent until the first cleanup with usage reported — an empty card
            // saying nothing is worse than no card.
            if let est = CleanupCostEstimate.over(model.historyEntries) { costSection(est) }
        }
    }

    @ViewBuilder
    private func costSection(_ est: CleanupCostEstimate) -> some View {
        HubSection("Estimated cost",
                   footer: "Based on list prices for dictations in History. Not a bill.") {
            HubRow("Cleanup spend",
                   detail: "\(est.dictations) dictation\(est.dictations == 1 ? "" : "s") since "
                       + est.since.formatted(date: .abbreviated, time: .shortened)
                       + (est.unpriced > 0
                          ? " · \(est.unpriced) not priced" : "")) {
                Text(Self.money(est.usd)).font(.system(size: 13, design: .monospaced))
            }
            if let monthly = est.monthlyUSD {
                HubDivider()
                HubRow("At this rate", detail: "Projected over 30 days") {
                    Text(Self.money(monthly) + "/mo").font(.system(size: 13, design: .monospaced))
                }
            }
        }
    }

    /// Per-dictation cleanup is fractions of a cent, so two decimals would read
    /// "$0.00" for real spend; monthly figures are ordinary money.
    private static func money(_ usd: Double) -> String {
        String(format: usd < 1 ? "$%.4f" : "$%.2f", usd)
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var model: HubModel
    /// Read on appear rather than published: proposals are written by the
    /// dictation path (possibly in an earlier launch), and this page is the only
    /// thing that ever shows them.
    @State private var proposals: [DictionaryLearner.Proposal] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !proposals.isEmpty {
                HubSection("Suggested",
                           footer: "You corrected these after Parla typed them. Add the ones you want Parla to learn.") {
                    ForEach(proposals, id: \.key) { proposal in
                        HubRow(proposal.to, detail: "Parla typed “\(proposal.from)”") {
                            HStack(spacing: 8) {
                                Button("Add") {
                                    model.words.append(.init(text: proposal.to))
                                    resolve(proposal, dismissed: false)
                                }
                                .buttonStyle(HubButtonStyle(kind: .primary))
                                Button("Dismiss") { resolve(proposal, dismissed: true) }
                                    .buttonStyle(HubButtonStyle())
                            }
                        }
                        if proposal.key != proposals.last?.key { HubDivider() }
                    }
                }
            }
            HubSection("Words",
                       footer: "Words near the top take priority.") {
                if model.words.isEmpty {
                    EmptyHint(text: "No dictionary entries yet")
                } else {
                    ForEach($model.words) { $row in
                        HStack(spacing: 8) {
                            TextField("Word or phrase", text: $row.text)
                                .hubField()
                            Button { model.moveWord(row.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.plain).help("Higher priority")
                            Button { model.moveWord(row.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.plain).help("Lower priority")
                            Button {
                                model.words.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        if row.id != model.words.last?.id { HubDivider() }
                    }
                }
            }
            let usedWords = VocabularyHints.select(model.words.map(\.text), byteLimit: VocabularyHints.asrBytes).count
            if usedWords < model.words.filter({ !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }).count {
                Text("The list is long, so only the top \(usedWords) words help recognition.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Button {
                model.words.append(.init())
            } label: {
                Label("Add word", systemImage: "plus")
            }
            .buttonStyle(HubButtonStyle(kind: .primary))
            HubVocabularyView(model: model)
        }
        .onAppear { proposals = DictionaryLearner.Store.shared.pending }
    }

    private func resolve(_ proposal: DictionaryLearner.Proposal, dismissed: Bool) {
        DictionaryLearner.Store.shared.resolve(proposal, dismissed: dismissed)
        proposals.removeAll { $0.key == proposal.key }
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @ObservedObject var model: HubModel

    // Trimmed, non-empty triggers that appear more than once — only the last
    // survives save() (Dictionary uniquingKeysWith), so flag the rest.
    private var duplicateTriggers: Set<String> {
        let trimmed = model.snippets.map { $0.trigger.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var counts: [String: Int] = [:]
        for t in trimmed { counts[t, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSection("Snippets",
                       footer: "Say the trigger phrase while dictating and Parla types the expansion instead."
                           + (duplicateTriggers.isEmpty ? "" : " Some triggers repeat; only the last one is kept.")) {
                if model.snippets.isEmpty {
                    EmptyHint(text: "No snippets yet")
                } else {
                    ForEach($model.snippets) { $row in
                        HStack(spacing: 8) {
                            TextField("Trigger phrase", text: $row.trigger)
                                .hubField().frame(width: 170)
                                .overlay {
                                    if duplicateTriggers.contains(row.trigger.trimmingCharacters(in: .whitespaces)) {
                                        RoundedRectangle(cornerRadius: 8).stroke(Theme.danger)
                                    }
                                }
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                            TextField("Expansion", text: $row.expansion)
                                .hubField()
                            Button {
                                model.snippets.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        if row.id != model.snippets.last?.id { HubDivider() }
                    }
                }
            }
            Button {
                model.snippets.append(.init())
            } label: {
                Label("Add snippet", systemImage: "plus")
            }
            .buttonStyle(HubButtonStyle(kind: .primary))
        }
    }
}

// MARK: - History

struct HistoryPage: View {
    @ObservedObject var model: HubModel
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] { model.filteredHistory(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    TextField("Search history", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))

                Spacer()

                Button("Export (\(filtered.count))…") { model.prepareFilteredHistoryExport(query) }
                    .buttonStyle(HubButtonStyle(kind: .normal))
                    .disabled(filtered.isEmpty)

                Button("Clear history") { confirmClear = true }
                    .buttonStyle(HubButtonStyle(kind: .danger))
                    .disabled((model.historyEntries.isEmpty && model.pendingHistory.isEmpty) || model.history.loadBlocked)
                    .confirmationDialog("Delete all dictation history? Saved audio isn't affected.",
                                        isPresented: $confirmClear) {
                        Button("Delete all", role: .destructive) { model.clearHistory() }
                    }
            }

            HistoryStatus(model: model)
            if let request = model.historyExport {
                HistoryExportReview(model: model, request: request)
            }
            if let message = model.historyExportMessage {
                Text(message).font(.caption).foregroundStyle(Theme.muted)
            }
            if let message = model.historyRetryMessage {
                Text(message).font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(model.historyRetries.values.sorted { $0.original.date > $1.original.date }) { preview in
                HistoryRetryReview(model: model, preview: preview)
            }

            ForEach(model.pendingHistory) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not saved — kept until you quit Parla").font(.system(size: 12, weight: .semibold))
                    historyRow(entry, pending: true)
                    HStack {
                        Button("Try saving again") { model.retryHistorySave(entry.id) }.disabled(model.history.loadBlocked)
                        Button("Discard", role: .destructive) { model.discardHistory(entry.id) }
                    }
                }
            }

            if filtered.isEmpty {
                VStack(spacing: 0) {
                    EmptyHint(text: model.historyEntries.isEmpty
                        ? (model.pendingHistory.isEmpty ? "No dictations yet" : "Nothing saved yet")
                        : "No matches for “\(query)”")
                }
                .frame(maxWidth: .infinity)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            } else {
                VStack(spacing: 10) {
                    ForEach(filtered) { entry in
                        historyRow(entry, pending: false)
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let retry = entry.retries?.last {
                Text(retry.configuration.retryMode == .segmentedV1 ? "Cleaned up in sections" : retry.configuration.kind == .cleanup ? "Cleaned up again" : "Preset applied")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            }
            if let operation = entry.operation {
                Text(operation.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Text(entry.best)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            DisclosureGroup("Original and result") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Original").font(.caption).foregroundStyle(Theme.muted)
                    Text(entry.raw).textSelection(.enabled)
                    Text("Result").font(.caption).foregroundStyle(Theme.muted)
                    Text(entry.best).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if let app = entry.appName {
                    Text(app)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentFill))
                }
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                if entry.cleaned == nil {
                    Text("raw")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Copy original") { model.copyOriginal(entry) }.buttonStyle(.plain)
                Button("Copy result") { model.copyResult(entry) }.buttonStyle(.plain)
                if !pending {
                    if entry.operation == nil {
                        Button("Clean up in sections…") { model.prepareSegmentedHistoryRetry(entry.id) }
                            .buttonStyle(.plain)
                    }
                    Button("Export…") { model.prepareHistoryExport(rowID: entry.id) }.buttonStyle(.plain)
                    Button(entry.operation == nil ? "Clean up again…" : "Apply preset again…") {
                        model.prepareHistoryRetry(entry.id, applyPreset: entry.operation != nil)
                    }.buttonStyle(.plain).disabled(model.loadError != nil || model.saveError != nil || model.history.loadBlocked)
                    Button("Delete", role: .destructive) { model.deleteHistory(entry.id) }
                        .buttonStyle(.plain).disabled(model.history.loadBlocked)
                        .help("Deletes the text only")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

// MARK: - Data & Privacy

struct PrivacyPage: View {
    @ObservedObject var model: HubModel
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HubSection("History",
                       footer: "Dictations into password fields and canceled dictations are never saved.") {
                HubRow("Keep history",
                       detail: "Saved on this Mac only") {
                    Toggle("", isOn: $model.settings.historyEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("History limit", detail: "Number of dictations to keep") {
                    Stepper(value: $model.settings.historyTextCount, in: HistoryStore.countRange) {
                        Text("\(model.settings.historyTextCount)").monospacedDigit()
                    }.frame(width: 130)
                }
                HubDivider()
                HubRow("Clear history",
                       detail: "\(model.historyEntries.count) saved" + (model.pendingHistory.isEmpty ? "" : ", \(model.pendingHistory.count) not saved")) {
                    Button("Clear…") { confirmClear = true }
                        .buttonStyle(HubButtonStyle(kind: .danger))
                        .disabled((model.historyEntries.isEmpty && model.pendingHistory.isEmpty) || model.history.loadBlocked)
                        .confirmationDialog("Delete all dictation history? Saved audio isn't affected.",
                                            isPresented: $confirmClear) {
                            Button("Delete all", role: .destructive) { model.clearHistory() }
                        }
                }
            }.disabled(model.loadError != nil)
            HistoryStatus(model: model)

            HubSection("Clipboard") {
                HubRow("Restore clipboard sooner", detail: "Puts your clipboard back as soon as the app has read the pasted text") {
                    Toggle("", isOn: $model.settings.clipboardReceiptRestoreEnabled).toggleStyle(.switch).labelsHidden()
                }
            }.disabled(model.loadError != nil)

            HubSection("Undo cancel") {
                HubRow("Allow undoing a canceled dictation", detail: "For 3 seconds after you cancel. Audio stays in memory only and is never saved.") {
                    Toggle("", isOn: $model.settings.canceledCaptureUndoEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
            HubSection("Original text") {
                HubRow("Keep original text briefly", detail: "Keeps your last dictation's original text in memory for 30 seconds, even with history off") {
                    Toggle("", isOn: $model.settings.keepLastOriginalEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow("Copy original", detail: model.originalCopyStatus.message) {
                    Button("Copy original") { model.copyLastOriginal() }.buttonStyle(HubButtonStyle())
                        .disabled(model.originalCopyStatus.token == nil || model.loadError != nil)
                }
            }.disabled(model.loadError != nil)

            HubSection("Shortcuts app") {
                HubRow("Allow Shortcuts to dictate", detail: "Shortcuts receive the text; nothing is pasted. The last result is kept in memory for up to 5 minutes.") {
                    Toggle("", isOn: $model.settings.automationEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow("Clear last result") {
                    Button("Clear") { model.onClearAutomationResult() }.buttonStyle(HubButtonStyle())
                }
            }.disabled(model.loadError != nil)

            HubRecoveryView(model: model)
            HubDiagnosticsView(model: model)

            HubSection("How Parla handles your data") {
                HubRow("Speech recognition runs on this Mac",
                       detail: "Your audio never leaves this Mac") { EmptyView() }
                HubDivider()
                HubRow("Your clipboard is restored",
                       detail: "Parla pastes through the clipboard, then puts back what was there") { EmptyView() }
                HubDivider()
                HubRow("Password fields are protected",
                       detail: "Parla never types, saves or sends anything in a password field") { EmptyView() }
                HubDivider()
                HubRow("Apple Intelligence cleanup stays on this Mac", detail: "Your text isn't sent to a server") { EmptyView() }
                HubDivider()
                HubRow("Online cleanup sends text only",
                       detail: "Your dictation, selected text, dictionary and snippets — never audio, app names or web addresses") { EmptyView() }
            }
        }
        .onAppear { model.refreshRecovery(); model.refreshOriginalCopy() }
        .onDisappear { model.stopRecoveryPlayback() }
    }
}

/// Shared persistence status on History and Privacy, including settings-save
/// failures separately from a count policy whose trim could not be written.
struct HistoryStatus: View {
    @ObservedObject var model: HubModel
    var body: some View {
        if let error = model.historyError {
            VStack(alignment: .leading, spacing: 8) {
                HubBanner(text: error)
                if model.history.loadBlocked {
                    Button("Try again") { model.reloadHistory() }
                } else if let limit = model.history.countLimit, model.historyEntries.count > limit {
                    Button("Apply history limit") { model.retryHistoryTrim() }
                }
            }
        }
    }
}


private struct CleanupFailoverSection: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubSection("Backup cleanup", footer: "If cleanup fails, Parla tries up to two backup services in order. Each one gets your text and may charge you.") {
            Text(model.failoverState).font(.headline)
            ForEach(model.failoverBackups.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Backup \(index + 1)").font(.headline)
                    Picker("Provider", selection: $model.failoverBackups[index].provider) {
                        Text("Anthropic").tag("anthropic")
                        Text("OpenAI-compatible").tag("openai-compatible")
                    }
                    .onChange(of: model.failoverBackups[index].provider) { provider in
                        if provider == "anthropic" { model.failoverBackups[index].baseURL = nil }
                    }
                    TextField("Base URL (blank for Anthropic)", text: optBinding($model.failoverBackups[index].baseURL)).hubField()
                    TextField("Model", text: $model.failoverBackups[index].model).hubField()
                    Picker("API key", selection: $model.failoverBackups[index].source) {
                        Text("Environment variable").tag(CleanupBackupSource.namedEnvironment)
                        Text("Keychain").tag(CleanupBackupSource.scopedKeychain)
                        Text("No key needed").tag(CleanupBackupSource.keylessCompatible)
                    }
                    .onChange(of: model.failoverBackups[index].source) { source in
                        if source != .namedEnvironment { model.failoverBackups[index].environmentName = nil }
                    }
                    if model.failoverBackups[index].source == .namedEnvironment {
                        TextField("Environment variable name", text: optBinding($model.failoverBackups[index].environmentName)).hubField()
                    }
                    if model.failoverBackups[index].source == .scopedKeychain {
                        Text("Shared by every model on this server.")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("New key", text: Binding(get: { model.failoverKeyDraft(index) }, set: { model.setFailoverKeyDraft(index, $0) })).hubField()
                        HStack {
                            Button("Save key") { model.changeFailoverKey(index) }.disabled(model.failoverKeyDraft(index).isEmpty)
                            Button("Remove key") { model.changeFailoverKey(index, remove: true) }
                        }
                    }
                    HStack {
                        Button("Move up") { model.moveFailoverBackup(index, by: -1) }.disabled(index == 0)
                        Button("Move down") { model.moveFailoverBackup(index, by: 1) }.disabled(index + 1 == model.failoverBackups.count)
                        Button("Remove backup") { model.failoverBackups.remove(at: index) }
                    }
                }.padding(12)
            }
            HStack {
                Button("Add backup") { model.failoverBackups.append(CleanupBackup()) }.disabled(model.failoverBackups.count >= 2)
                Button("Reload saved", action: model.loadFailoverDraft)
                Button("Save without turning on", action: model.saveFailoverDraft)
                Button("Review and turn on…", action: model.reviewFailover)
                Button("Turn off", action: model.disableFailover)
            }
            if let review = model.failoverReview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm these services").font(.headline)
                    identity(review.primary, label: "Primary")
                    ForEach(review.policy.backups.indices, id: \.self) { index in
                        if let value = try? review.policy.backups[index].identity() { identity(value, label: "Backup \(index + 1)") }
                    }
                    Button("Turn on backups", action: model.confirmFailover)
                }.padding(12)
            }
            if let message = model.failoverMessage { Text(message).font(.caption) }
        }
    }
    private func identity(_ value: CleanupChainIdentity, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label + " · " + value.provider).bold()
            Text(value.endpoint).textSelection(.enabled)
            Text("Model: " + value.model)
            Text("Key: " + value.source)
        }.font(.caption)
    }
}
