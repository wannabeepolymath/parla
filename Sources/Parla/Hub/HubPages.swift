import AppKit
import ParlaCore
import SwiftUI

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var model: HubModel
    private let permissionTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Tracks the warm-mic toggle below, so the permissions row never promises a
    /// closed mic the app is actually holding open (or vice versa). Hoisted out of
    /// the body: a ternary over concatenated literals inside a ViewBuilder is the
    /// kind of expression SwiftUI's type-checker gives up on.
    private var micDetail: String {
        model.settings.warmMic
            ? "Held open between dictations (not Bluetooth ones) so one starts instantly; "
                + "only what you dictate is transcribed"
            : "Opened only while you dictate; only what you dictate is transcribed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button("Safe Start controls · \(model.preparationSnapshot.status.rawValue)") { model.requestedPage = .safeStart }
            HubSection("Permissions") {
                permissionRow("Microphone", granted: model.micGranted,
                              pane: "Privacy_Microphone", detail: micDetail)
                HubDivider()
                permissionRow("Accessibility", granted: model.axGranted,
                              pane: "Privacy_Accessibility",
                              detail: "Global hotkey and typing into the frontmost app")
            }

            if let problem = model.downloadError {
                HubBanner(text: problem)
            }
            HubSection("Recognition engine", footer: model.recognitionCapabilityDetail) {
                HubRow("Engine", detail: "Whisper remains the default. Apple Speech requires macOS 26 and an exact supported locale.") {
                    Picker("", selection: $model.settings.recognitionEngine) {
                        Text("Whisper").tag(RecognitionEngine.whisper)
                        Text("Apple Speech · batch").tag(RecognitionEngine.appleSpeech)
                        if model.settings.recognitionEngine == .parakeet || model.parakeetChoiceRefusal == nil {
                    Text("Parakeet · local batch").tag(RecognitionEngine.parakeet)
                }
                if model.settings.recognitionEngine == .invalid { Text("Invalid configuration").tag(RecognitionEngine.invalid) }
                    }.labelsHidden()
                }
                if model.settings.recognitionEngine == .parakeet { ParakeetGlobalControls(model: model) }
                else {
                    DisclosureGroup("Parakeet installation") { ParakeetControls(model: model) }
                }
                if let reason = model.parakeetChoiceRefusal { Text(reason.message).font(.caption) }
                if model.settings.recognitionEngine == .appleSpeech {
                    TextField("Exact locale, for example en-US", text: optBinding($model.settings.appleSpeechLocale)).hubField()
                    AppleSpeechControls(model: model)
                }
            }
            if model.settings.recognitionEngine == .whisper {
            HubSection("Whisper model", footer: model.modelPath) {
                ForEach(ModelCatalog.all) { m in
                    if m.id != ModelCatalog.all.first?.id { HubDivider() }
                    HubRow(m.displayName, detail: "\(m.sizeLabel) · \(m.filename)") {
                        modelControl(m)
                    }
                }
                HubDivider()
                HubRow("Language", detail: languageDetail) {
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
            HubSection("Energy/activity shadow", footer: "Off by default. For future ordinary physical dictations only. Bounded energy proxy facts stay in RAM Diagnostics until Clear or quit; review and export explicitly. Accuracy is unqualified; energy is not speech proof. Rejection and edge suggestions are NOT APPLIED. Adds analysis work; no speed or resource benefit is established.") {
                HubRow("Enable energy/activity shadow", detail: "Suggestions NOT APPLIED · no audio or text in shadow facts") {
                    Toggle("", isOn: $model.settings.energyActivityShadowEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
            HubSection("Speculative HUD preview", footer: "Global preview only; the final model still follows the global or start profile selection. Both choices must be installed catalog Whisper models. Drafts are speculative and never become final text. English-only choices have limited auto-language previews and refuse pinned non-English. This experiment adds model loads and can delay the final result after stop; quality, speed and memory benefits are unqualified. Changes apply to the next capture.") {
                HubRow("Show recording preview", detail: "A separate model requires both this switch and an explicit choice below.") {
                    Toggle("", isOn: $model.settings.streamPreviewEnabled).labelsHidden()
                }
                HubDivider()
                HubRow("Global preview model", detail: "Installed choices only. No model is downloaded or prepared here.") {
                    Picker("", selection: optBinding($model.settings.recognitionPreviewModelID)) {
                        Text("Same final-model stream (default)").tag("")
                        ForEach(model.recognitionPreviewChoices) { entry in Text(entry.displayName).tag(entry.id) }
                        if let id = model.recognitionPreviewUnavailableID { Text("Unavailable · \(id)").tag(id) }
                    }.labelsHidden().frame(width: 240)
                }
            }
            HubSection("App") {
                HubRow("Launch at Login", detail: "Start Parla when you log in") {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { _ in model.toggleLaunchAtLogin() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Show pill at all times",
                       detail: "Keep the dictation pill floating on screen when idle") {
                    Toggle("", isOn: $model.settings.showHudAlways)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Idle pill size", detail: "Size of the bar when not dictating") {
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
                // Labelled by consequence, not mechanism: "holds the mic open"
                // means nothing to a user, while the orange dot is the thing they
                // will actually notice and have to explain to themselves.
                HubRow("Start dictation instantly",
                       detail: "Holds the mic open so no speech is clipped. "
                           + "macOS's orange microphone indicator stays lit the whole time Parla runs") {
                    Toggle("", isOn: $model.settings.warmMic)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Microphone", detail: "Input device to record from") {
                    Picker("", selection: optBinding($model.settings.inputDeviceUID)) {
                        Text("System Default").tag("")
                        ForEach(micOptions, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                HubDivider()
                HubRow("Settings file", detail: "Everything here is stored in settings.json") {
                    Button("Open File") { model.onOpenSettingsFile() }
                        .buttonStyle(HubButtonStyle())
                }
            }

            if let problem = model.hotkeyError {
                HubBanner(text: problem)
            }
            HubSection("Shortcuts", footer: "Press Change, then the keys you want. Esc keeps the current one. Labels follow your keyboard layout. “Physical key” means its layout label is unavailable; shortcuts keep the same key positions.") {
                shortcutRow("Push to talk", "Hold to say something short",
                            \.pushToTalk, modifierOnly: true)
                HubDivider()
                shortcutRow("Hands-free mode",
                            "Start while holding push to talk; it, Space, or Return finishes",
                            \.handsFree)
                HubDivider()
                HubRow("Command mode", detail: "Transform selected text by voice") {
                    ShortcutPill(text: model.commandShortcutDisplay)
                }
                HubDivider()
                shortcutRow("Paste last transcript", "Paste the last thing you dictated", \.pasteLast)
                HubDivider()
                shortcutRow("Open Scratchpad", "A safe place to dictate and edit", \.openScratchpad)
                HubDivider()
                HubRow("Run selected preset", detail: "Transform selected text in the destination app; no recording") {
                    ShortcutRecorder(model: model, optionalPath: \.runSelectedPreset)
                }
                HubDivider()
                HubRow("Mouse push to talk", detail: model.settings.mouseBinding.map {
                    $0.buttonNumber == 2 ? "Hold Middle to dictate. Its click is used by Parla."
                        : "Hold \($0.display) to dictate. Its normal action, including Back/Forward navigation, is consumed."
                } ?? "Optional. Left and right clicks are always available.") {
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
                if model.settings.mouseBinding != nil {
                    HStack {
                        Text(model.inputTapStatus.message + " Native mouse, remapper, browser navigation and secure-input checks are pending.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.inputTapStatus != .ready { Button("Retry") { model.onRetryInput() } }
                    }
                }
                HubDivider()
                HubRow("Cancel", detail: "Dismiss dictation and notifications") {
                    ShortcutPill(text: "Esc")
                }
            }
        }
        .onReceive(permissionTick) { _ in model.refreshPermissions() }
    }

    private func shortcutRow(_ label: String, _ detail: String,
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

    private var languageDetail: String {
        model.recognitionCapabilityDetail + (englishOnlyModel ? "" : " Auto follows the speaker; choose a language to pin it.")
    }

    /// Live input devices, plus the saved device if it's currently unplugged —
    /// so the picker still shows the user's choice instead of blanking.
    private var micOptions: [AudioRecorder.InputDevice] {
        var devices = AudioRecorder.availableInputs()
        if let uid = model.settings.inputDeviceUID, !uid.isEmpty,
           !devices.contains(where: { $0.uid == uid }) {
            devices.append(.init(uid: uid, name: "Unavailable device"))
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
            model.hotkeyError = "Finish the microphone test or current capture first."; return
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
                HubBanner(text: "Cleanup won't run — \(issue). Dictations will insert the raw transcript unpolished.")
            }
            HubSection("Provider",
                       footer: "Cleanup polishes the raw transcript. If it fails, the raw text is inserted instead.") {
                HubRow("Service") {
                    Picker("", selection: $model.settings.cleanup.provider) {
                        Text("Anthropic").tag("anthropic")
                        Text("OpenAI-compatible").tag("openai-compatible")
                        Text("Apple Intelligence · on-device").tag("apple-intelligence")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 300)
                }
            }

            if isLocal {
                HubSection("Apple Intelligence · on-device", footer: "No endpoint or API key. Apple manages system assets and may use its own network for downloads/updates. This adapter sends no transcript request to a server.") {
                    Text(model.localCleanupStatus?.message ?? "Availability checked: eligible for a new request; each request checks again.")
                        .font(.caption).padding(12)
                    HubRow("Declared source locale", detail: "Explicit intent, separate from speech recognition. Unknown refuses local generation.") {
                        TextField("Locale identifier, e.g. en or hi", text: optBinding($model.settings.cleanup.localSourceLocale)).hubField().frame(width: 240)
                    }
                    Button("Recheck availability", action: model.recheckLocalCleanup).padding(12)
                    Text("Only confidently identified single-language text is admitted. Short, mixed, code, names or uncertain text may be refused. Ordinary cleanup keeps raw text with your literal rules on failure. Translation and spoken commands are unavailable; saved rewrites require explicit same-language confirmation. No remote fallback.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                    Text("8 KiB source/instruction/selection; 16 KiB full prompt; 32 KiB response. The 15-second logical acceptance deadline requests cancellation, then waits for actual exit; it does not guarantee a 15-second return.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }
                HubSection("Saved network credentials", footer: "A separate deliberate action for retained legacy network keys. Availability and local requests never migrate them.") {
                    Button("Migrate saved network credentials", action: model.retryCredentialMigration).padding(12)
                    if let message = model.credentialMessage { Text(message).font(.caption) }
                }
            } else if isAnthropic {
                HubSection("Anthropic",
                           footer: "The ANTHROPIC_API_KEY environment variable takes precedence over the key stored here (terminal launches only).") {
                    HubRow("Model") {
                        TextField("claude-sonnet-5", text: $model.settings.cleanupModel)
                            .hubField().frame(width: 260)
                    }
                    HubDivider()

                }
            } else {
                HubSection("Endpoint",
                           footer: "Any OpenAI-compatible endpoint, hosted or local. Leave the key empty for keyless local servers.") {
                    HubRow("Base URL", detail: "Parla POSTs to {base}/chat/completions") {
                        TextField("https://api.example.com/v1",
                                  text: optBinding($model.settings.cleanup.baseURL))
                            .hubField().frame(width: 260)
                    }
                    HubDivider()
                    HubRow("Model", detail: "Optional — empty uses the server's first model") {
                        TextField("openai/gpt-oss-120b",
                                  text: optBinding($model.settings.cleanup.model))
                            .hubField().frame(width: 260)
                    }
                    HubDivider()

                }
            }

            if !isLocal {
            HubSection("Credential", footer: model.credentialStatus) {
                HubRow("API key", detail: "Blank preserves the stored key. Keys stay in Keychain.") {
                    SecureField("New key…", text: $model.credentialDraft).hubField().frame(width: 260)
                }
                HStack {
                    Button("Save / Replace", action: model.saveCredential).disabled(model.credentialDraft.isEmpty)
                    Button("Remove", action: model.removeCredential)
                    Button("Refresh / Retry migration", action: model.retryCredentialMigration)
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
                   footer: "An estimate from published list prices, not a bill. Configured text limit: \(model.settings.historyTextCount). "
                       + "This covers priced producer usage in retained original dictations, not all-attempt spend. Experimental failover models are unpriced; failed or discarded attempts and retry requests are excluded. Discounts and cached input aren't counted.") {
            HubRow("Cleanup spend",
                   detail: "\(est.dictations) dictation\(est.dictations == 1 ? "" : "s") since "
                       + est.since.formatted(date: .abbreviated, time: .shortened)
                       + (est.unpriced > 0
                          ? " · \(est.unpriced) not priced (local or unknown model)" : "")) {
                Text(Self.money(est.usd)).font(.system(size: 13, design: .monospaced))
            }
            if let monthly = est.monthlyUSD {
                HubDivider()
                HubRow("At this rate", detail: "Straight-line projection over 30 days") {
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
                           footer: "Parla noticed you fixing these words right after it typed them. "
                               + "Nothing is added to the dictionary until you add it.") {
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
                       footer: "Top words have priority. ASR gets up to 2,048 UTF-8 bytes; cleanup gets 8,192. Each hint must fit in 256 bytes. Omitted words stay saved.") {
                if model.words.isEmpty {
                    EmptyHint(text: "No dictionary entries yet")
                } else {
                    ForEach($model.words) { $row in
                        HStack(spacing: 8) {
                            TextField("word or phrase", text: $row.text)
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
            Text("Currently selected: \(VocabularyHints.select(model.words.map(\.text), byteLimit: VocabularyHints.asrBytes).count) ASR hints; \(VocabularyHints.select(model.words.map(\.text), byteLimit: VocabularyHints.cleanupBytes).count) cleanup hints of \(model.words.count) saved rows.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
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
                           + (duplicateTriggers.isEmpty ? "" : " Duplicate triggers exist — only the last one is saved.")) {
                if model.snippets.isEmpty {
                    EmptyHint(text: "No snippets yet")
                } else {
                    ForEach($model.snippets) { $row in
                        HStack(spacing: 8) {
                            TextField("trigger phrase", text: $row.trigger)
                                .hubField().frame(width: 170)
                                .overlay {
                                    if duplicateTriggers.contains(row.trigger.trimmingCharacters(in: .whitespaces)) {
                                        RoundedRectangle(cornerRadius: 8).stroke(Theme.danger)
                                    }
                                }
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                            TextField("expansion", text: $row.expansion)
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

                Button("Export Filtered (\(filtered.count))…") { model.prepareFilteredHistoryExport(query) }
                    .buttonStyle(HubButtonStyle(kind: .normal))
                    .disabled(filtered.isEmpty)

                Button("Clear History") { confirmClear = true }
                    .buttonStyle(HubButtonStyle(kind: .danger))
                    .disabled((model.historyEntries.isEmpty && model.pendingHistory.isEmpty) || model.history.loadBlocked)
                    .confirmationDialog("Delete all saved and unsaved text? Recording files are managed separately.",
                                        isPresented: $confirmClear) {
                        Button("Delete All", role: .destructive) { model.clearHistory() }
                    }
            }

            HistoryStatus(model: model)
            if let request = model.historyExport {
                HistoryExportReview(model: model, request: request)
            }
            if let message = model.historyExportMessage {
                Text(message).font(.caption).foregroundStyle(Theme.muted)
            }
            Text("Deleting or clearing removes text only. Recording files are managed separately; audio recovery follows its independent lifetime policy.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)

            if let message = model.historyRetryMessage {
                Text(message).font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(model.historyRetries.values.sorted { $0.original.date > $1.original.date }) { preview in
                HistoryRetryReview(model: model, preview: preview)
            }

            ForEach(model.pendingHistory) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unsaved result — available until Parla quits").font(.system(size: 12, weight: .semibold))
                    historyRow(entry, pending: true)
                    HStack {
                        Button("Retry Save") { model.retryHistorySave(entry.id) }.disabled(model.history.loadBlocked)
                        Button("Discard", role: .destructive) { model.discardHistory(entry.id) }
                    }
                }
            }

            if filtered.isEmpty {
                VStack(spacing: 0) {
                    EmptyHint(text: model.historyEntries.isEmpty
                        ? (model.pendingHistory.isEmpty ? "No dictations yet — hold fn and speak" : "No saved text yet — unsaved results are above")
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
                Text(retry.configuration.retryMode == .segmentedV1 ? "Result: experimental segmented cleanup" : retry.configuration.kind == .cleanup ? "Result: retried ordinary cleanup" : "Result: explicitly applied preset")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            }
            if let operation = entry.operation {
                Text("Initial operation: " + operation.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Text(entry.best)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            DisclosureGroup(entry.operation?.origin == .selection ? "Original source / Result" : "Original / Result") {
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
                Button("Copy Original") { model.copyOriginal(entry) }.buttonStyle(.plain)
                Button("Copy Result") { model.copyResult(entry) }.buttonStyle(.plain)
                if !pending {
                    if entry.operation == nil {
                        Button("Review segmented cleanup (experimental)…") { model.prepareSegmentedHistoryRetry(entry.id) }
                            .buttonStyle(.plain)
                    }
                    Button("Export…") { model.prepareHistoryExport(rowID: entry.id) }.buttonStyle(.plain)
                    Button(entry.operation == nil ? "Review Retry Cleanup" : "Review Selected Preset") {
                        model.prepareHistoryRetry(entry.id, applyPreset: entry.operation != nil)
                    }.buttonStyle(.plain).disabled(model.loadError != nil || model.saveError != nil || model.history.loadBlocked)
                    Button("Delete", role: .destructive) { model.deleteHistory(entry.id) }
                        .buttonStyle(.plain).disabled(model.history.loadBlocked)
                        .help("Deletes text only; recording files are managed separately")
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
                       footer: "Off stops saving newly started sessions; in-flight sessions keep their starting permission. Existing text stays readable and copyable. Secure-field and cancelled dictations are never recorded. Text limits do not change audio retention.") {
                HubRow("Keep local history",
                       detail: "Save new sessions on this Mac only") {
                    Toggle("", isOn: $model.settings.historyEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Saved text limit", detail: "1–1,000 saved entries. Unsaved results require Save or Discard.") {
                    Stepper(value: $model.settings.historyTextCount, in: HistoryStore.countRange) {
                        Text("\(model.settings.historyTextCount)").monospacedDigit()
                    }.frame(width: 130)
                }
                HubDivider()
                HubRow("Clear history",
                       detail: "\(model.historyEntries.count) saved, \(model.pendingHistory.count) unsaved. Removes text only.") {
                    Button("Clear…") { confirmClear = true }
                        .buttonStyle(HubButtonStyle(kind: .danger))
                        .disabled((model.historyEntries.isEmpty && model.pendingHistory.isEmpty) || model.history.loadBlocked)
                        .confirmationDialog("Delete all saved and unsaved text? Recording files are managed separately.",
                                            isPresented: $confirmClear) {
                            Button("Delete All", role: .destructive) { model.clearHistory() }
                        }
                }
            }.disabled(model.loadError != nil)
            HistoryStatus(model: model)

            HubSection("Clipboard restore experiment",
                       footer: "Off by default. Observes requests for clipboard data, never paste acceptance or every reader. Local only; known remote clients keep the fixed delay. Requests restoration within 8 seconds, with a 0.8-second floor and 0.3-second quiet period; a stalled app or IPC can exceed that deadline. Oversized or unreadable clipboards are refused. One full original snapshot stays in RAM until settlement; a failed restore retains it and can prevent quit or restart. Force quit cannot preserve promises.") {
                HubRow("Observe clipboard data requests", detail: "Experimental; paste remains unverified") {
                    Toggle("", isOn: $model.settings.clipboardReceiptRestoreEnabled).toggleStyle(.switch).labelsHidden()
                }
            }.disabled(model.loadError != nil)

            HubSection("Undo accidental cancellation",
                       footer: "Off by default. Keep at most 10 seconds of canceled audio in RAM for a fixed 3-second Undo window. Undo opens a temporary raw transcript for 30 seconds; only an explicit Copy writes it to the clipboard. No app audio files or history. New capture, Discard, disable, security refusal, expiry or quit clears it. Native work may retain copies until it exits; this does not promise physical erasure or prevent OS swap.") {
                HubRow("Undo capture cancellation", detail: "Temporary transcript and explicit Copy only; no field insertion") {
                    Toggle("", isOn: $model.settings.canceledCaptureUndoEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
            HubSection("Brief Original copy",
                       footer: "Opt in to keep one ordinary dictation Original in RAM for 30 seconds from paste dispatch, up to 64 KiB of UTF-8. Works with history off. Only an explicit Copy Original writes it to the clipboard; no transcript preview. Paste acceptance is unverified. Guarded Undo / Restore Raw remain unavailable pending native qualification.") {
                HubRow("Keep last Original briefly", detail: "Off by default; new capture, insertion, disable, expiry or quit clears it") {
                    Toggle("", isOn: $model.settings.keepLastOriginalEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow("Copy Original", detail: model.originalCopyStatus.message) {
                    Button("Copy Original") { model.copyLastOriginal() }.buttonStyle(HubButtonStyle())
                        .disabled(model.originalCopyStatus.token == nil || model.loadError != nil)
                }
            }.disabled(model.loadError != nil)

            HubSection("Automation source preview",
                       footer: "Native Shortcuts actions are pending. When enabled, one final result can live in RAM for up to 5 minutes (64 KiB maximum), until a new capture, Clear, disable or quit. History and recording retention still follow their normal settings. Returned text cannot be retracted.") {
                HubRow("Enable automation", detail: "Result-only dictation; no automatic paste or copy") {
                    Toggle("", isOn: $model.settings.automationEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow("Clear last result", detail: "Also prevents a held completion from repopulating retrieval") {
                    Button("Clear Last Result") { model.onClearAutomationResult() }.buttonStyle(HubButtonStyle())
                }
            }.disabled(model.loadError != nil)

            HubRecoveryView(model: model)
            HubDiagnosticsView(model: model)

            HubSection("How Parla handles your data") {
                HubRow("Transcription is on-device",
                       detail: "Audio never leaves this Mac — whisper.cpp runs locally") { EmptyView() }
                HubDivider()
                HubRow("Your clipboard is restored",
                       detail: "Dictation uses a temporary paste. Your clipboard is restored unless you copy something new; temporary text is marked to exclude it from compatible clipboard history apps.") { EmptyView() }
                HubDivider()
                HubRow("Password fields are protected",
                       detail: "Dictation is refused in secure fields — nothing is typed, stored, or sent to the cleanup model") { EmptyView() }
                HubDivider()
                HubRow("Optional on-device cleanup", detail: "Apple Intelligence uses the system model on this Mac. Apple manages downloads and updates; Parla’s local adapter sends no transcript request to a server.") { EmptyView() }
                HubDivider()
                HubRow("Endpoint cleanup sends text only",
                       detail: "The transcript, selected text for voice commands, dictionary, snippets, and a fixed formatting hint — never audio, app names, or browser URLs") { EmptyView() }
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
                    Button("Retry Load") { model.reloadHistory() }
                } else if let limit = model.history.countLimit, model.historyEntries.count > limit {
                    Button("Apply Saved Text Limit") { model.retryHistoryTrim() }
                }
                Text("Retry Delete or Clear with the corresponding action. Unsaved results can be copied, retried or discarded in History.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}


private struct CleanupFailoverSection: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HubSection("Backup cleanup · experiment", footer: "Ordinary keyboard, mouse and result-only Shortcuts only. Presets, transforms, history, eval and Apple Intelligence never use backups.") {
            Text(model.failoverState).font(.headline)
            Text("After a transient failure, try up to two reviewed network destinations in order. Each may receive the same transcript and context and may charge you. Loopback is still network transport and cannot prove that a server keeps text on-device.")
                .font(.caption).foregroundStyle(.secondary)
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
                    TextField("Exact model identifier", text: $model.failoverBackups[index].model).hubField()
                    Picker("Credential source", selection: $model.failoverBackups[index].source) {
                        Text("Named environment variable only").tag(CleanupBackupSource.namedEnvironment)
                        Text("Keychain key for this endpoint").tag(CleanupBackupSource.scopedKeychain)
                        Text("Explicitly keyless compatible server").tag(CleanupBackupSource.keylessCompatible)
                    }
                    .onChange(of: model.failoverBackups[index].source) { source in
                        if source != .namedEnvironment { model.failoverBackups[index].environmentName = nil }
                    }
                    if model.failoverBackups[index].source == .namedEnvironment {
                        TextField("Environment variable name", text: optBinding($model.failoverBackups[index].environmentName)).hubField()
                    }
                    if model.failoverBackups[index].source == .scopedKeychain {
                        Text("This Keychain entry is shared by models at the same provider and endpoint, including the primary when it uses Keychain. Replacing or removing it affects every model using the entry. Environment credentials are unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("New key for this endpoint", text: Binding(get: { model.failoverKeyDraft(index) }, set: { model.setFailoverKeyDraft(index, $0) })).hubField()
                        HStack {
                            Button("Save / Replace key") { model.changeFailoverKey(index) }.disabled(model.failoverKeyDraft(index).isEmpty)
                            Button("Remove key") { model.changeFailoverKey(index, remove: true) }
                        }
                    }
                    Text("A missing selected source stops cleanup; it never falls through to another source.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Move up") { model.moveFailoverBackup(index, by: -1) }.disabled(index == 0)
                        Button("Move down") { model.moveFailoverBackup(index, by: 1) }.disabled(index + 1 == model.failoverBackups.count)
                        Button("Remove backup") { model.failoverBackups.remove(at: index) }
                    }
                }.padding(12)
            }
            HStack {
                Button("Add backup") { model.failoverBackups.append(CleanupBackup()) }.disabled(model.failoverBackups.count >= 2)
                Button("Load saved chain", action: model.loadFailoverDraft)
                Button("Save disabled draft", action: model.saveFailoverDraft)
                Button("Review complete chain", action: model.reviewFailover)
                Button("Disable backups", action: model.disableFailover)
            }
            if let review = model.failoverReview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm these exact destinations").font(.headline)
                    identity(review.primary, label: "Primary")
                    ForEach(review.policy.backups.indices, id: \.self) { index in
                        if let value = try? review.policy.backups[index].identity() { identity(value, label: "Backup \(index + 1)") }
                    }
                    Text("The primary keeps its credential precedence and uses noninteractive access with bounded HTTP. Each backup uses only its selected source. Keyless means no credential is sent by this adapter. Review again to accept this result deadline and drain contract.").font(.caption)
                    Button("Confirm and enable for new captures", action: model.confirmFailover)
                }.padding(12)
            }
            Text("One 15-second cleanup result budget begins before primary credential setup. Under executor progress, expiry returns raw text with local rules once, while canceled work drains. Capture, recognition and entry preparation are outside this timer. New ordinary starts stay busy until actual exit. A recording already in progress is preserved; after stopping it waits for prior cleanup and can be discarded. Actual exit and queued recognition may wait indefinitely. All chain prompts over 16 KiB stop without truncation. A backup needs at least 3 seconds remaining. Disable revokes backups; frozen primary intent remains until deadline, discard or lifecycle abort. Quit/restart cancel the operation and await drain; finish or cancel an existing recording first. Producer tokens exclude other attempts; remote processing and billing may continue.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.failoverMessage { Text(message).font(.caption) }
        }
    }
    private func identity(_ value: CleanupChainIdentity, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label + " · " + value.provider).bold()
            Text(value.endpoint).textSelection(.enabled)
            Text("Exact model: " + value.model)
            Text("Credential policy: " + value.source)
            Text("Access: " + value.access)
        }.font(.caption)
    }
}
