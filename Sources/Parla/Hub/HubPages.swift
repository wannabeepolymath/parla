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

    @State private var moreShortcuts = false
    @State private var showPermissions = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            // Once both are granted there's nothing to do here, so it folds to one row.
            let allGranted = model.micGranted && model.axGranted
            HubSection(allGranted ? nil : "Permissions") {
                if allGranted {
                    HubDisclosureRow(title: "Permissions granted", summary: "Microphone and Accessibility", isExpanded: $showPermissions)
                }
                if !allGranted || showPermissions {
                    if allGranted { HubDivider() }
                    permissionRow("Microphone", granted: model.micGranted,
                                  pane: "Privacy_Microphone", detail: micDetail)
                    HubDivider()
                    permissionRow("Accessibility", granted: model.axGranted,
                                  pane: "Privacy_Accessibility",
                                  detail: "Lets Parla hear shortcuts and type into apps")
                }
            }

            if let problem = model.hotkeyError {
                HubBanner(text: problem, kind: .warning)
            }
            HubSection("Shortcuts", footer: "Click a shortcut, then press the new keys. Esc cancels.") {
                shortcutRow("Push to talk", "Hold to dictate, release to insert",
                            \.pushToTalk, modifierOnly: true)
                HubDivider()
                shortcutRow("Hands-free mode",
                            "Press while holding push to talk. Press again, Space or Return to stop.",
                            \.handsFree)
                HubDivider()
                HubDisclosureRow(title: "More shortcuts", summary: "Command mode, paste last, Scratchpad, presets, mouse", isExpanded: $moreShortcuts)
                if moreShortcuts {
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
                    HubRow("Cancel", detail: "Stop dictation or close a notification") {
                        ShortcutPill(text: "Esc")
                    }
                    HubDivider()
                    HubRow("Mouse push to talk", detail: model.settings.mouseBinding.map {
                        $0.buttonNumber == 2 ? "Hold the middle button to dictate. Its normal click won’t work."
                            : "Hold \($0.display) to dictate. Its normal action, like Back, won’t work."
                    }) {
                        Picker("Mouse push to talk", selection: Binding(
                            get: { model.settings.mouseBinding?.buttonNumber ?? 0 },
                            set: { model.settings.mouseBinding = MouseButtonBinding(buttonNumber: $0) })) {
                            Text("Off").tag(0)
                            Text("Middle button").tag(2)
                            ForEach(3...15, id: \.self) { number in Text("Button \(number + 1)").tag(number) }
                        }
                        .hubControl()
                    }
                }
                if let problem = model.settings.mouseBindingProblem {
                    HubNote(problem, warning: true).hubInset()
                }
                if model.settings.mouseBinding != nil, model.inputTapStatus != .ready {
                    HubDivider()
                    HubRow(model.inputTapStatus.message) {
                        Button("Try Again") { model.onRetryInput() }.buttonStyle(HubButtonStyle())
                    }
                }
            }

            if let problem = model.downloadError {
                HubBanner(text: problem)
            }
            HubSection("Speech recognition", footer: model.settings.recognitionEngine == .whisper || model.recognitionCapabilityDetail.isEmpty ? nil : model.recognitionCapabilityDetail) {
                HubRow("Engine") { EnginePicker(model: model) }
                HubDivider()
                HubRow("Microphone", detail: MicrophonePicker.detail(for: model.settings.inputDeviceUID)) {
                    MicrophonePicker(selection: $model.settings.inputDeviceUID)
                }
                if model.settings.recognitionEngine == .whisper {
                    HubDivider()
                    HubRow("Language", detail: englishOnlyModel ? "This model understands English only" : nil) {
                        Picker("Language", selection: optBinding($model.settings.language)) {
                            Text("Auto-detect").tag("")
                            Divider()
                            ForEach(WhisperTranscriber.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .hubControl()
                        .disabled(englishOnlyModel)
                    }
                } else if model.settings.recognitionEngine == .appleSpeech {
                    HubDivider()
                    AppleSpeechLocaleRow(locale: $model.settings.appleSpeechLocale)
                    HubDivider()
                    AppleSpeechControls(model: model)
                } else if model.settings.recognitionEngine == .parakeet {
                    HubDivider()
                    ParakeetGlobalControls(model: model)
                    if let reason = model.parakeetChoiceRefusal { HubNote(reason.message, warning: true).hubInset() }
                }
                if model.settings.recognitionEngine != .parakeet, !model.parakeetUnavailable {
                    HubDivider()
                    DisclosureGroup("Parakeet model") { ParakeetControls(model: model) }.hubInset()
                }
                HubDivider()
                HubToggleRow("Live preview", detail: "Shows draft text in the pill while you speak; the final text may differ",
                             isOn: $model.settings.streamPreviewEnabled)
                HubDivider()
                    HubRow("Preview model", detail: "A smaller downloaded model gives faster drafts") {
                        Picker("Preview model", selection: optBinding($model.settings.recognitionPreviewModelID)) {
                            Text("Same as dictation").tag("")
                            ForEach(model.recognitionPreviewChoices) { entry in Text(entry.hubName).tag(entry.id) }
                            if let id = model.recognitionPreviewUnavailableID { Text("Not downloaded · \(id)").tag(id) }
                        }
                        .hubControl()
                    }
            }

            if model.settings.recognitionEngine == .whisper {
                HubSection("Whisper model", footer: "Larger models are more accurate but slower. Only one download runs at a time.") {
                    ForEach(ModelCatalog.all) { m in
                        if m.id != ModelCatalog.all.first?.id { HubDivider() }
                        HubRow(m.hubName, detail: m.hubDetail) { modelControl(m) }
                    }
                }
            }

            HubSection("App") {
                HubToggleRow("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLaunchAtLogin() }))
                HubDivider()
                // Labelled by consequence, not mechanism: the orange dot is the
                // thing users will actually notice.
                HubToggleRow("Start dictation instantly",
                             detail: "Keeps the mic on so no words are cut off. The orange mic dot stays lit.",
                             isOn: $model.settings.warmMic)
                HubDivider()
                HubToggleRow("Always show the pill", detail: "Keeps the dictation pill on screen when idle",
                             isOn: $model.settings.showHudAlways)
                HubDivider()
                HubRow("Idle pill size") {
                    Picker("Idle pill size", selection: $model.settings.hudIdleSize) {
                        Text("Small").tag("small")
                        Text("Medium").tag("medium")
                        Text("Large").tag("large")
                    }
                    .pickerStyle(.menu)
                    .hubControl()
                }
            }

            HubSection(nil) {
                HubDisclosureRow(title: "Advanced", summary: "Clipboard, undo, activity analysis, settings file", isExpanded: $showAdvanced)
                if showAdvanced {
                    HubDivider()
                HubToggleRow("Restore clipboard sooner", detail: "Puts your clipboard back as soon as the app has read the pasted text",
                             isOn: $model.settings.clipboardReceiptRestoreEnabled)
                HubDivider()
                HubToggleRow("Undo a canceled dictation", detail: "For 3 seconds after you cancel. The audio stays in memory and is never saved.",
                             isOn: $model.settings.canceledCaptureUndoEnabled)
                HubDivider()
                HubToggleRow("Activity analysis", detail: "Adds speech timing to Diagnostics. Doesn’t change results.",
                             isOn: $model.settings.energyActivityShadowEnabled)
                HubDivider()
                HubRow("Settings file", detail: "Edit settings.json directly") {
                    Button("Open File") { model.onOpenSettingsFile() }
                        .buttonStyle(HubButtonStyle())
                }
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

    /// Downloading / not here / selected / on disk. Only one download runs at
    /// a time, so the other Download buttons are disabled while it does — but
    /// the installed rows keep their state, or a download hides which model is
    /// in use. "Installed" is file existence only: hashing three models on
    /// every render is exactly ghost-pepper #163.
    @ViewBuilder
    private func modelControl(_ m: ModelCatalog.Model) -> some View {
        if let row = model.catalogDownloads[m.id], row.phase != .installed {
            ModelDownloadProgress(model: model, catalogModel: m, row: row)
        } else if !ModelCatalog.isInstalled(m) {
            Button("Download") { model.onDownloadModel(m) }
                .buttonStyle(HubButtonStyle())
                .disabled(model.downloadingModel != nil)
                .help(model.downloadingModel != nil ? "One download at a time" : "Download \(m.sizeLabel)")
        } else if model.isSelected(m) {
            StatusChip(text: model.modelLoaded ? "In use" : "Selected",
                       color: model.modelLoaded ? Theme.success : Theme.muted)
        } else {
            Button("Use") { model.selectModel(m) }
                .buttonStyle(HubButtonStyle())
        }
    }

    private func permissionRow(_ name: String, granted: Bool, pane: String,
                               detail: String) -> some View {
        let purpose = pane == "Privacy_Microphone" ? "to record your voice." : "to hear shortcuts and type into apps."
        return HubRow(name, detail: granted ? detail : "Not allowed yet. Parla needs this " + purpose,
               detailColor: granted ? Theme.muted : Theme.danger) {
            if granted {
                StatusChip(text: "Granted")
            } else {
                Button("Open System Settings") { model.openPrivacyPane(pane) }
                    .buttonStyle(HubButtonStyle())
            }
        }
    }
}

/// One-line download state: bar + percent (or phase) + Pause/Resume/Retry.
/// Shared by General and onboarding.
struct ModelDownloadProgress: View {
    @ObservedObject var model: HubModel
    let catalogModel: ModelCatalog.Model
    let row: CatalogDownloadRow
    var body: some View {
        HStack(spacing: 8) {
            if row.active {
                ProgressView(value: Double(row.percent) / 100).frame(width: 96)
                Text(row.phase == .downloading ? "\(row.percent)%" : row.phase.rawValue)
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
            } else {
                Text(row.phase.rawValue).font(.system(size: 12))
                    .foregroundStyle(row.phase == .failed ? Theme.danger : Theme.muted)
            }
            ForEach(row.actions, id: \.rawValue) { action in
                Button(action.rawValue) { model.onCatalogDownloadAction(action, catalogModel) }
                    .buttonStyle(HubButtonStyle())
                    .disabled(!row.active && model.downloadingModel != nil)
            }
        }
    }
}

extension ModelCatalog.Model {
    /// "Large v3 Turbo": language coverage first; compression is secondary detail.
    var hubName: String {
        displayName.replacingOccurrences(of: ", quantized", with: "").replacingOccurrences(of: " (quantized)", with: "")
    }
    var englishOnly: Bool { displayName.contains("English") }
    var hubDetail: String {
        (englishOnly ? "English only" : "Multilingual, about 100 languages") + " · " + sizeLabel
            + (displayName.contains("quantized") ? " · compressed" : "")
    }
}

/// One engine popup shared by General and Safe Start.
struct EnginePicker: View {
    @ObservedObject var model: HubModel
    var body: some View {
        Picker("Speech engine", selection: $model.settings.recognitionEngine) {
            Text("Whisper").tag(RecognitionEngine.whisper)
            Text("Apple Speech").tag(RecognitionEngine.appleSpeech)
            if model.settings.recognitionEngine == .parakeet || (!model.parakeetUnavailable && model.parakeetChoiceRefusal == nil) {
                Text("Parakeet").tag(RecognitionEngine.parakeet)
            }
            if model.settings.recognitionEngine == .invalid { Text("Choose an engine").tag(RecognitionEngine.invalid) }
        }
        .hubControl()
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
        let recording = monitor != nil
        HStack(spacing: 4) {
            // Leading, so the keycap always ends on the row's trailing edge.
            HubIconButton(optionalPath == nil ? "arrow.uturn.backward" : "xmark",
                          label: optionalPath == nil ? "Reset to default" : "Clear shortcut") {
                stop()
                if let path, let original { model.setHotkey(path, to: original) }
                if let optionalPath { model.setOptionalHotkey(optionalPath, to: nil) }
            }
            .opacity(chord != original ? 1 : 0)
            .disabled(chord == original)
            .accessibilityHidden(chord == original)
            Button {
                if monitor == nil { start() } else { stop() }
            } label: {
                Text(recording ? label : keycapText(label))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(recording ? Theme.accent : Theme.text)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Theme.accentFill : Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording ? Theme.accent : Theme.control))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .modifier(DimWhenDisabled())
            .help(recording ? "Press the new keys. Esc cancels." : "Click to change")
            .accessibilityLabel(recording ? "Recording shortcut. Press the new keys." : "Shortcut \(label). Click to change.")
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
    @State private var editingBackups = false
    @State private var customModel = false
    @State private var replacingKey = false

    private var outputDetail: String {
        switch model.settings.outputMode {
        case .raw: return "Types exactly what you said"
        case .cleanup: return "Fixes punctuation, filler words and wording"
        case .selectedPreset:
            let name = model.settings.transformPresets.first { $0.id == model.settings.selectedPresetID }?.name
            return name.map { "Rewrites every dictation with “\($0)”" } ?? "Choose a preset"
        }
    }

    /// Plain-language names for the models Parla knows; anything else is "Custom".
    private static let anthropicModels: [(id: String, name: String, note: String)] = [
        ("claude-haiku-4-5", "Claude Haiku 4.5", "Fastest and lowest cost. Recommended."),
        ("claude-sonnet-5", "Claude Sonnet 5", "More careful with tricky wording"),
        ("claude-opus-4-5", "Claude Opus 4.5", "Most capable, highest cost"),
    ]
    private var keyStatus: String {
        // The "local servers" hint only applies to OpenAI-compatible servers.
        isAnthropic ? model.credentialStatus.replacingOccurrences(of: " Local servers may not need one.", with: "")
                    : model.credentialStatus
    }

    private var isAnthropic: Bool { ["", "anthropic"].contains(model.settings.cleanup.provider) }
    private var isLocal: Bool { model.settings.usesAppleIntelligence }

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            if let issue = model.credentialIssue {
                HubBanner(text: "Cleanup can’t run. \(issue)", kind: .warning,
                          actionTitle: !isLocal && isAnthropic ? "Get a Key" : nil) {
                    if let url = URL(string: "https://console.anthropic.com/settings/keys") { NSWorkspace.shared.open(url) }
                }
            }
            HubSection(nil, footer: model.settings.outputMode == .raw ? "Cleanup is off. Parla types your original text, without snippets or replacements." : nil) {
                HubRow("Dictation output", detail: outputDetail) {
                    DictationOutputPicker(model: model)
                }
            }
            HubSection("Service", footer: model.failoverMessage
                       ?? "If cleanup fails, Parla tries your backup services, then inserts your original text.") {
                HubRow("Provider") {
                    Picker("Provider", selection: $model.settings.cleanup.provider) {
                        Text("Anthropic").tag("anthropic")
                        Text("OpenAI-compatible").tag("openai-compatible")
                        Text("Apple Intelligence").tag("apple-intelligence")
                    }
                    .pickerStyle(.menu)
                    .hubControl()
                }
                HubDivider()
                if isLocal {
                    HubRow("Status", detail: model.localCleanupStatus?.message ?? "Apple Intelligence is ready.") {
                        Button("Check Again", action: model.recheckLocalCleanup).buttonStyle(HubButtonStyle())
                    }
                    HubDivider()
                    HubRow("Language", detail: "The language you dictate in, like en or hi") {
                        TextField("Language", text: optBinding($model.settings.cleanup.localSourceLocale), prompt: Text("en"))
                            .hubField().hubControl()
                    }
                } else if isAnthropic {
                    let known = Self.anthropicModels.contains { $0.id == model.settings.cleanupModel }
                    HubRow("Model", detail: Self.anthropicModels.first { $0.id == model.settings.cleanupModel && !customModel }?.note) {
                        Picker("Model", selection: Binding(
                            get: { known && !customModel ? model.settings.cleanupModel : "custom" },
                            set: { value in
                                if value == "custom" { customModel = true }
                                else { customModel = false; model.settings.cleanupModel = value }
                            })) {
                            ForEach(Self.anthropicModels, id: \.id) { Text($0.name).tag($0.id) }
                            Divider()
                            Text("Custom…").tag("custom")
                        }
                        .hubControl()
                    }
                    if customModel || !known {
                        HubDivider()
                        HubRow("Model ID", detail: "The exact model name from Anthropic") {
                            TextField("Model ID", text: $model.settings.cleanupModel, prompt: Text("claude-sonnet-5"))
                                .hubField().hubControl()
                        }
                    }
                } else {
                    HubRow("Base URL", detail: "Any OpenAI-compatible server, online or local") {
                        TextField("Base URL", text: optBinding($model.settings.cleanup.baseURL), prompt: Text("https://api.example.com/v1"))
                            .hubField().hubControl()
                    }
                    HubDivider()
                    HubRow("Model", detail: "Optional. Empty uses the server’s default.") {
                        TextField("Model", text: optBinding($model.settings.cleanup.model), prompt: Text("openai/gpt-oss-120b"))
                            .hubField().hubControl()
                    }
                }
                if !isLocal {
                    HubDivider()
                    let saved = model.credentialStatus == CredentialStatus.present.message
                    HubRow("API key", detail: saved && !replacingKey ? "Saved in Keychain" : keyStatus) {
                        HStack(spacing: 8) {
                            if saved && !replacingKey {
                                // A saved key reads as saved: masked, never an empty field.
                                Text("•••••••••••")
                                    .font(.system(size: 9)).tracking(1).foregroundStyle(Theme.muted)
                                    .accessibilityLabel("Key saved")
                                Button("Replace…") { replacingKey = true }.buttonStyle(HubButtonStyle())
                            } else {
                                SecureField("API key", text: $model.credentialDraft,
                                            prompt: Text(saved ? "Paste a replacement key" : "Paste your key"))
                                    .hubField().hubControl(160)
                                    .onSubmit { model.saveCredential(); replacingKey = false }
                                if replacingKey {
                                    Button("Cancel") { replacingKey = false; model.credentialDraft = "" }.buttonStyle(HubButtonStyle())
                                }
                                Button("Save") { model.saveCredential(); replacingKey = false }
                                    .buttonStyle(HubButtonStyle())
                                    .disabled(model.credentialDraft.isEmpty)
                            }
                            HubMoreMenu(label: "Key actions") {
                                Button("Remove Saved Key", role: .destructive, action: model.removeCredential)
                                    .disabled(!saved)
                                Button("Move Keys from settings.json to Keychain", action: model.retryCredentialMigration)
                            }
                        }
                    }
                }
                HubDivider()
                HubRow("Backup services", detail: model.failoverState == "Off"
                       ? "Up to two other services, tried in order. Each gets your text and may charge you."
                       : model.failoverState) {
                    HStack(spacing: 8) {
                        if model.failoverState != "Off" {
                            Button("Turn Off", action: model.disableFailover).buttonStyle(HubButtonStyle())
                        }
                        Button(model.failoverBackups.isEmpty ? "Set Up…" : "Edit…") { editingBackups = true }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
            if let message = model.credentialMessage { HubNote(message, warning: true) }
            if isLocal {
                HubSection("Saved API keys") {
                    HubRow("Keys in settings.json", detail: "Moves API keys saved in settings.json into Keychain") {
                        Button("Move to Keychain", action: model.retryCredentialMigration).buttonStyle(HubButtonStyle())
                    }
                }
            }

            // Absent until the first cleanup with usage reported — an empty card
            // saying nothing is worse than no card.
            if let est = CleanupCostEstimate.over(model.historyEntries) { costSection(est) }
        }
        .sheet(isPresented: $editingBackups) { CleanupFailoverSheet(model: model) }
    }

    @ViewBuilder
    private func costSection(_ est: CleanupCostEstimate) -> some View {
        HubSection("Estimated cost",
                   footer: "Based on list prices for dictations in History. Not a bill.") {
            HubRow("So far",
                   detail: "\(est.dictations) dictation\(est.dictations == 1 ? "" : "s") since "
                       + est.since.formatted(date: .abbreviated, time: .omitted)
                       + (est.unpriced > 0 ? " · \(est.unpriced) not priced" : "")) {
                HubValue(Self.money(est.usd))
            }
            if let monthly = est.monthlyUSD {
                HubDivider()
                HubRow("At this rate", detail: "Projected over 30 days") {
                    HubValue(Self.money(monthly) + " a month")
                }
            }
        }
    }

    /// Per-dictation cleanup is fractions of a cent; say so instead of "$0.0065".
    private static func money(_ usd: Double) -> String {
        usd < 0.01 ? "Under $0.01" : String(format: "$%.2f", usd)
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var model: HubModel
    /// Read on appear rather than published: proposals are written by the
    /// dictation path (possibly in an earlier launch), and this page is the only
    /// thing that ever shows them.
    @State private var proposals: [DictionaryLearner.Proposal] = []
    @State private var hovered: UUID?

    private var wordsFooter: String? {
        let retained = model.retainedVocabularyCount()
        let total = model.words.filter({ !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }).count
        guard retained.count < total else { return nil }
        return retained.exact
            ? "\(retained.count) of \(total) words fit the speech model’s prompt. Words near the top win."
            : "About \(retained.count) of \(total) words help recognition. The exact number appears once the speech model is loaded."
    }

    /// Suggestions already in the list aren't offered again.
    private var openProposals: [DictionaryLearner.Proposal] {
        let existing = Set(model.words.map { $0.text.trimmingCharacters(in: .whitespaces).lowercased() })
        return proposals.filter { !existing.contains($0.to.lowercased()) }
    }

    var body: some View {
        if model.loadError != nil {
            HubSection(nil) {
                EmptyHint(text: "Your dictionary is unavailable",
                          detail: "Words, replacements and import come back once Parla can read its settings.")
            }
        } else {
            content.onAppear { proposals = DictionaryLearner.Store.shared.pending }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            if !openProposals.isEmpty {
                HubSection("Suggested",
                           footer: "You corrected these after Parla typed them. Add the ones you want Parla to learn.") {
                    ForEach(openProposals, id: \.key) { proposal in
                        HubRow(proposal.to, detail: "Parla typed “\(proposal.from)”") {
                            HStack(spacing: 8) {
                                Button("Dismiss") { resolve(proposal, dismissed: true) }
                                    .buttonStyle(HubButtonStyle())
                                Button("Add") {
                                    model.words.append(.init(text: proposal.to))
                                    resolve(proposal, dismissed: false)
                                }
                                .buttonStyle(HubButtonStyle())
                            }
                        }
                        if proposal.key != openProposals.last?.key { HubDivider() }
                    }
                }
            }
            HubSection("Words", footer: wordsFooter.map { "Click a word to edit. Drag to reorder. " + $0 } ?? "Click a word to edit. Drag to reorder; words near the top take priority.", accessory: {
                HubAddButton("Add Word") { model.words.append(.init()) }
            }) {
                if model.words.isEmpty {
                    EmptyHint(text: "No words yet", detail: "Add names and terms Parla should spell your way.")
                } else {
                    ForEach($model.words) { $row in
                        wordRow($row)
                        if row.id != model.words.last?.id { HubDivider() }
                    }
                }
            }
            HubVocabularyView(model: model)
        }
    }

    private func wordRow(_ row: Binding<HubModel.WordRow>) -> some View {
        let id = row.wrappedValue.id
        let delete = { model.words.removeAll { $0.id == id } }
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
                .draggable(id.uuidString)
                .help("Drag to reorder")
                .accessibilityHidden(true)
            TextField("Word or phrase", text: row.text, prompt: Text("Word or phrase"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .labelsHidden()
                .modifier(DimWhenDisabled())
            HubIconButton("trash", label: "Delete word", action: delete)
                .modifier(HoverReveal(hovering: hovered == id))
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            moveWord(source, onto: id); return true
        }
        .contextMenu {
            Button("Move Up") { model.moveWord(id, by: -1) }.disabled(id == model.words.first?.id)
            Button("Move Down") { model.moveWord(id, by: 1) }.disabled(id == model.words.last?.id)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { model.moveWord(id, by: -1) }
        .accessibilityAction(named: "Move down") { model.moveWord(id, by: 1) }
    }

    /// Drag-and-drop move in one assignment, so the list saves once.
    private func moveWord(_ source: UUID, onto target: UUID) {
        guard let from = model.words.firstIndex(where: { $0.id == source }),
              let to = model.words.firstIndex(where: { $0.id == target }), from != to else { return }
        var words = model.words
        words.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        model.words = words
    }

    private func resolve(_ proposal: DictionaryLearner.Proposal, dismissed: Bool) {
        DictionaryLearner.Store.shared.resolve(proposal, dismissed: dismissed)
        proposals.removeAll { $0.key == proposal.key }
    }
}

// MARK: - Snippets

/// "trigger → expansion" with a hover-revealed delete — shared by Snippets and Replacements.
struct MappingRow: View {
    let from: Binding<String>
    let to: Binding<String>
    let fromPrompt: String
    let toPrompt: String
    var invalid = false
    let deleteLabel: String
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(fromPrompt, text: from, prompt: Text(fromPrompt))
                .hubField().labelsHidden().frame(width: 170)
                .overlay { if invalid { RoundedRectangle(cornerRadius: 6).stroke(Theme.danger) } }
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(height: 24)
                .accessibilityHidden(true)
            // The field runs to the card's trailing line; delete overlays its end on hover.
            TextField(toPrompt, text: to, prompt: Text(toPrompt), axis: .vertical)
                .lineLimit(1...4)
                .hubField().labelsHidden()
                .overlay(alignment: .topTrailing) {
                    HubIconButton("trash", label: deleteLabel, action: onDelete)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
                        .modifier(HoverReveal(hovering: hovering))
                }
        }
        .padding(.horizontal, HubLayout.rowInset)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { Button("Delete", role: .destructive, action: onDelete) }
    }
}

/// Column labels above a MappingRow list.
struct MappingHeader: View {
    let from: String
    let to: String
    var body: some View {
        HStack(spacing: 8) {
            Text(from).frame(width: 170, alignment: .leading)
            Color.clear.frame(width: 11, height: 1)
            Text(to).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, HubLayout.rowInset)
        .padding(.top, 10).padding(.bottom, 2)
    }
}

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
        HubSection("Snippets",
                   footer: "Say the phrase while dictating and Parla types the text instead. Import and export them with your dictionary."
                       + (duplicateTriggers.isEmpty ? "" : " Some phrases repeat; only the last one is kept."),
                   accessory: {
                       HStack(spacing: 8) {
                           HubMoreMenu(label: "Import or export") {
                               // The import preview lives on Dictionary, so open it there.
                               Button("Import…") { model.requestedPage = .dictionary; model.chooseVocabularyImport() }
                               Button("Export…") { model.exportVocabulary() }
                           }
                           HubAddButton("Add Snippet") { model.snippets.append(.init()) }
                       }
                   }) {
            if model.snippets.isEmpty {
                EmptyHint(text: "No snippets yet", detail: "Add a short phrase, like “my address”, and what it should become.")
            } else {
                MappingHeader(from: "When I say", to: "Type this")
                ForEach($model.snippets) { $row in
                    MappingRow(from: $row.trigger, to: $row.expansion, fromPrompt: "Phrase", toPrompt: "Text to type",
                               invalid: duplicateTriggers.contains(row.trigger.trimmingCharacters(in: .whitespaces)),
                               deleteLabel: "Delete snippet") { model.snippets.removeAll { $0.id == row.id } }
                    if row.id != model.snippets.last?.id { HubDivider() }
                }
            }
        }
    }
}

// MARK: - History

struct HistoryPage: View {
    @ObservedObject var model: HubModel
    @State private var query = ""
    @State private var confirmClear = false
    @State private var expanded: Set<HistoryEntry.ID> = []
    @State private var hovered: HistoryEntry.ID?

    /// Today / Yesterday / Earlier, newest first, as the store already orders them.
    private var groups: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var today: [HistoryEntry] = [], yesterday: [HistoryEntry] = [], earlier: [HistoryEntry] = []
        for entry in filtered {
            if calendar.isDateInToday(entry.date) { today.append(entry) }
            else if calendar.isDateInYesterday(entry.date) { yesterday.append(entry) }
            else { earlier.append(entry) }
        }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)].filter { !$0.1.isEmpty }
    }

    private var filtered: [HistoryEntry] { model.filteredHistory(query) }
    private var retryBlocked: Bool { model.loadError != nil || model.saveError != nil || model.history.loadBlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                    TextField("Search history", text: $query, prompt: Text("Search"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.control))

                Button("Export…") { model.prepareFilteredHistoryExport(query) }
                    .buttonStyle(HubButtonStyle())
                    .disabled(filtered.isEmpty)
                    .help(query.isEmpty ? "Export all dictations" : "Export the \(filtered.count) dictations shown")

                Button("Clear…") { confirmClear = true }
                    .buttonStyle(HubButtonStyle())
                    .disabled((model.historyEntries.isEmpty && model.pendingHistory.isEmpty) || model.history.loadBlocked)
                    .help("Delete all dictation history")
                    .confirmationDialog("Delete all dictation history? Saved audio isn’t affected.",
                                        isPresented: $confirmClear) {
                        Button("Delete All", role: .destructive) { model.clearHistory() }
                    }
            }

            HistoryStatus(model: model)
            if let request = model.historyExport {
                HistoryExportReview(model: model, request: request)
            }
            if let message = model.historyExportMessage { HubNote(message) }
            if let message = model.historyRetryMessage { HubNote(message) }
            ForEach(model.historyRetries.values.sorted { $0.original.date > $1.original.date }) { preview in
                HistoryRetryReview(model: model, preview: preview)
            }

            ForEach(model.pendingHistory) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HubBanner(text: "Not saved. Parla keeps this until you quit.", kind: .warning,
                              actionTitle: model.history.loadBlocked ? nil : "Try Again") { model.retryHistorySave(entry.id) }
                    HubSection(nil) { historyRow(entry, pending: true) }
                }
            }

            if filtered.isEmpty {
                HubSection(nil) {
                    if !model.historyEntries.isEmpty {
                        EmptyHint(text: "No matches for “\(query)”")
                    } else if !model.pendingHistory.isEmpty {
                        EmptyHint(text: "Nothing saved yet")
                    } else {
                        EmptyHint(text: "No dictations yet",
                                  detail: "Hold \(model.shortcutDisplay(model.settings.hotkeys.pushToTalk)) in any app to dictate. Your text shows up here.")
                    }
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    HubSection(group.title) {
                        ForEach(group.entries) { entry in
                            if entry.id != group.entries.first?.id { HubDivider() }
                            historyRow(entry, pending: false)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ entry: HistoryEntry, pending: Bool) -> some View {
        Button(expanded.contains(entry.id) ? "Hide Original" : "Compare with Original") {
            if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
        }
        Divider()
        Button("Copy Original") { model.copyOriginal(entry) }
        Button("Copy Result") { model.copyResult(entry) }
        if pending {
            Divider()
            Button("Try Saving Again") { model.retryHistorySave(entry.id) }.disabled(model.history.loadBlocked)
            Button("Discard", role: .destructive) { model.discardHistory(entry.id) }
        } else {
            Divider()
            Button(entry.operation == nil ? "Clean Up Again…" : "Apply Preset Again…") {
                model.prepareHistoryRetry(entry.id, applyPreset: entry.operation != nil)
            }.disabled(retryBlocked)
            if entry.operation == nil {
                Button("Clean Up in Sections…") { model.prepareSegmentedHistoryRetry(entry.id) }
            }
            Button("Export…") { model.prepareHistoryExport(rowID: entry.id) }
            Divider()
            Button("Delete Text", role: .destructive) { model.deleteHistory(entry.id) }
                .disabled(model.history.loadBlocked)
        }
    }

    private func historyRow(_ entry: HistoryEntry, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.best)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let app = entry.appName {
                    Text(app)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Theme.border))
                        .fixedSize()
                }
                Text(tags(entry))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                let open = expanded.contains(entry.id)
                Button {
                    if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                } label: {
                    HStack(spacing: 3) {
                        Text("Compare")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HoverReveal(hovering: open || hovered == entry.id))
                .help(open ? "Hide the original text" : "Compare the original and the result")
                .accessibilityLabel(open ? "Hide original and result" : "Show original and result")
                Spacer(minLength: 8)
                // Copy rests on the trailing line; ⋯ appears beside it on hover.
                HStack(spacing: 2) {
                    HubMoreMenu { actions(entry, pending: pending) }
                        .modifier(HoverReveal(hovering: hovered == entry.id || pending))
                    HubIconButton("doc.on.doc", label: "Copy text") { model.copyResult(entry) }
                }
                .padding(.trailing, -6) // the glyph, not its hit area, meets the trailing line
            }
            if expanded.contains(entry.id) {
                VStack(alignment: .leading, spacing: 10) {
                    version("Original", entry.raw) { model.copyOriginal(entry) }
                    version("Result", entry.best) { model.copyResult(entry) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .contextMenu { actions(entry, pending: pending) }
    }

    /// "12 minutes ago · Cleaned up again" — one line, never wraps.
    private func tags(_ entry: HistoryEntry) -> String {
        var parts = [entry.date.formatted(.relative(presentation: .named))]
        if let retry = entry.retries?.last {
            parts.append(retry.configuration.retryMode == .segmentedV1 ? "Cleaned up in sections"
                         : retry.configuration.kind == .cleanup ? "Cleaned up again" : "Preset applied")
        }
        if let operation = entry.operation { parts.append(operation.name) }
        if entry.cleaned == nil { parts.append("Not cleaned up") }
        return parts.joined(separator: " · ")
    }

    private func version(_ title: String, _ text: String, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Copy", action: copy).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Data & Privacy

struct PrivacyPage: View {
    @ObservedObject var model: HubModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            HubSection(nil) {
                HubRow("Speech recognition runs on this Mac", detail: "Your audio never leaves it. Online cleanup, if you use it, gets text only.")
                HubDivider()
                HubDisclosureRow(title: "How Parla handles your data", summary: "Passwords, clipboard, cleanup, nearby text", isExpanded: $showDetails)
                if showDetails {
                    HubDivider()
                    HubRow("Password fields are protected", detail: "Parla never types, saves or sends anything in a password field")
                    HubDivider()
                    HubRow("Your clipboard is restored", detail: "Parla pastes through the clipboard, then puts back what was there")
                    HubDivider()
                    HubRow("Cleanup sends text only", detail: "Apple Intelligence stays on this Mac. Online cleanup gets your dictation, selected text, dictionary and snippets — never audio, app names or web addresses.")
                    HubDivider()
                    HubRow("Nearby text", detail: "Online cleanup also gets about 256 characters before the cursor, only in the app you turn this on for. "
                           + (model.surroundingPolicy?.revision != nil ? "Currently on for one app." : "Currently off.")) {
                        Button("Manage") { model.requestedPage = .profiles }.buttonStyle(HubButtonStyle())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HubSection("History",
                           footer: "Dictations into password fields and canceled dictations are never saved.") {
                    HubToggleRow("Keep history", detail: "Saved on this Mac only", isOn: $model.settings.historyEnabled)
                    HubDivider()
                    HubRow("Keep the last") {
                        HStack(spacing: 6) {
                            Text("\(model.settings.historyTextCount) dictations").monospacedDigit()
                                .font(.system(size: 13)).foregroundStyle(Theme.text)
                            Stepper("History limit", value: $model.settings.historyTextCount, in: HistoryStore.countRange).labelsHidden()
                        }
                    }
                    HubDivider()
                    HubRow("Saved history",
                           detail: model.historyEntries.isEmpty && model.pendingHistory.isEmpty ? "Empty"
                               : "\(model.historyEntries.count) saved" + (model.pendingHistory.isEmpty ? "" : ", \(model.pendingHistory.count) not saved")) {
                        Button("Open History") { model.requestedPage = .history }.buttonStyle(HubButtonStyle())
                    }
                }.disabled(model.loadError != nil)
                HistoryStatus(model: model)
            }

            HubSection("Original text") {
                HubToggleRow("Keep original text briefly", detail: "Holds your last dictation’s original text in memory for 30 seconds, even with history off",
                             isOn: $model.settings.keepLastOriginalEnabled)
                if model.settings.keepLastOriginalEnabled {
                    HubDivider()
                    HubRow("Last original text", detail: model.originalCopyStatus.token == nil ? "Nothing to copy right now" : model.originalCopyStatus.message) {
                        Button("Copy") { model.copyLastOriginal() }.buttonStyle(HubButtonStyle())
                            .disabled(model.originalCopyStatus.token == nil || model.loadError != nil)
                    }
                }
            }.disabled(model.loadError != nil)

            // Release builds ship without App Intents metadata, so Shortcuts can't see Parla's actions.
            if Bundle.main.url(forResource: "Metadata", withExtension: "appintents") != nil {
                HubSection("Shortcuts app") {
                    HubToggleRow("Allow Shortcuts to dictate", detail: "Shortcuts receive the text; nothing is pasted. The last result is kept in memory for up to 5 minutes.",
                                 isOn: $model.settings.automationEnabled)
                    HubDivider()
                    HubRow("Last result") {
                        Button("Clear") { model.onClearAutomationResult() }.buttonStyle(HubButtonStyle())
                    }
                }.disabled(model.loadError != nil)
            }

            HubRecoveryView(model: model)
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
            if model.history.loadBlocked {
                HubBanner(text: error, actionTitle: "Try Again") { model.reloadHistory() }
            } else if let limit = model.history.countLimit, model.historyEntries.count > limit {
                HubBanner(text: error, actionTitle: "Apply Limit") { model.retryHistoryTrim() }
            } else {
                HubBanner(text: error)
            }
        }
    }
}


/// Backup services live in a sheet: they're set up once, and their editor
/// is too large to sit inline on the page.
private struct CleanupFailoverSheet: View {
    @ObservedObject var model: HubModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HubSheet(title: "Backup cleanup", width: 560) {
            Text("If cleanup fails, Parla tries up to two backup services in order. Each one gets your text and may charge you.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.failoverBackups.isEmpty {
                        HubSection(nil) { EmptyHint(text: "No backup services", detail: "Add one to use it when cleanup fails.") }
                    }
                    ForEach(model.failoverBackups.indices, id: \.self) { index in backup(index) }
                    if let review = model.failoverReview {
                        HubSection("Confirm these services") {
                            identity(review.primary, label: "Primary")
                            ForEach(review.policy.backups.indices, id: \.self) { index in
                                if let value = try? review.policy.backups[index].identity() {
                                    HubDivider()
                                    identity(value, label: "Backup \(index + 1)")
                                }
                            }
                        }
                    }
                    if let message = model.failoverMessage { HubNote(message) }
                }
            }
            .frame(height: 380)
        } actions: {
            Button { model.failoverBackups.append(CleanupBackup()) } label: { Label("Add Backup", systemImage: "plus") }
                .buttonStyle(HubButtonStyle())
                .disabled(model.failoverBackups.count >= 2)
            HubMoreMenu(label: "More backup actions") {
                Button("Revert to Saved", action: model.loadFailoverDraft)
                Button("Save Without Turning On", action: model.saveFailoverDraft)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(HubButtonStyle())
                .keyboardShortcut(.cancelAction)
            if model.failoverReview != nil {
                Button("Turn On Backups", action: model.confirmFailover)
                    .buttonStyle(HubButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            } else {
                Button("Review and Turn On…", action: model.reviewFailover)
                    .buttonStyle(HubButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(model.failoverBackups.isEmpty)
            }
        }
    }

    private func backup(_ index: Int) -> some View {
        HubSection("Backup \(index + 1)", accessory: {
            HStack(spacing: 2) {
                HubIconButton("arrow.up", label: "Move up") { model.moveFailoverBackup(index, by: -1) }.disabled(index == 0)
                HubIconButton("arrow.down", label: "Move down") { model.moveFailoverBackup(index, by: 1) }
                    .disabled(index + 1 == model.failoverBackups.count)
                HubIconButton("trash", label: "Remove backup") { model.failoverBackups.remove(at: index) }
            }
        }) {
            HubRow("Provider") {
                Picker("Provider", selection: $model.failoverBackups[index].provider) {
                    Text("Anthropic").tag("anthropic")
                    Text("OpenAI-compatible").tag("openai-compatible")
                }
                .hubControl()
                .onChange(of: model.failoverBackups[index].provider) { provider in
                    if provider == "anthropic" { model.failoverBackups[index].baseURL = nil }
                }
            }
            HubDivider()
            HubRow("Base URL", detail: "Leave empty for Anthropic") {
                TextField("Base URL", text: optBinding($model.failoverBackups[index].baseURL)).hubField().hubControl()
            }
            HubDivider()
            HubRow("Model") {
                TextField("Model", text: $model.failoverBackups[index].model).hubField().hubControl()
            }
            HubDivider()
            HubRow("API key") {
                Picker("API key", selection: $model.failoverBackups[index].source) {
                    Text("Environment variable").tag(CleanupBackupSource.namedEnvironment)
                    Text("Keychain").tag(CleanupBackupSource.scopedKeychain)
                    Text("No key needed").tag(CleanupBackupSource.keylessCompatible)
                }
                .hubControl()
                .onChange(of: model.failoverBackups[index].source) { source in
                    if source != .namedEnvironment { model.failoverBackups[index].environmentName = nil }
                }
            }
            if model.failoverBackups[index].source == .namedEnvironment {
                HubDivider()
                HubRow("Variable name") {
                    TextField("Variable name", text: optBinding($model.failoverBackups[index].environmentName)).hubField().hubControl()
                }
            }
            if model.failoverBackups[index].source == .scopedKeychain {
                HubDivider()
                HubRow("Key", detail: "Shared by every model on this server") {
                    HStack(spacing: 8) {
                        SecureField("Key", text: Binding(get: { model.failoverKeyDraft(index) }, set: { model.setFailoverKeyDraft(index, $0) }),
                                    prompt: Text("Paste a new key"))
                            .hubField().hubControl(160)
                        Button("Save") { model.changeFailoverKey(index) }
                            .buttonStyle(HubButtonStyle())
                            .disabled(model.failoverKeyDraft(index).isEmpty)
                        HubMoreMenu(label: "Key actions") {
                            Button("Remove Saved Key", role: .destructive) { model.changeFailoverKey(index, remove: true) }
                        }
                    }
                }
            }
        }
    }

    private func identity(_ value: CleanupChainIdentity, label: String) -> some View {
        HubRow(label + " · " + value.provider, detail: value.endpoint + "\nModel: " + value.model + " · Key: " + value.source)
    }
}
