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
            HubSection("Permissions") {
                permissionRow("Microphone", granted: model.micGranted,
                              pane: "Privacy_Microphone", detail: micDetail)
                HubDivider()
                permissionRow("Accessibility", granted: model.axGranted,
                              pane: "Privacy_Accessibility",
                              detail: "Global hotkey and typing into the frontmost app")
            }

            HubSection("Whisper model", footer: model.modelPath) {
                ForEach(ModelCatalog.all) { m in
                    if m.id != ModelCatalog.all.first?.id { HubDivider() }
                    HubRow(m.displayName, detail: "\(m.sizeLabel) · \(m.filename)") {
                        modelControl(m)
                    }
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
                    .pickerStyle(.segmented)
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
            HubSection("Shortcuts", footer: "Press Change, then the keys you want. Esc keeps the current one.") {
                shortcutRow("Push to talk", "Hold to say something short",
                            \.pushToTalk, modifierOnly: true)
                HubDivider()
                shortcutRow("Hands-free mode",
                            "Start while holding push to talk; it, Space, or Return finishes",
                            \.handsFree)
                HubDivider()
                HubRow("Command mode", detail: "Transform selected text by voice") {
                    ShortcutPill(text: "⇧ " + model.settings.hotkeys.pushToTalk.display)
                }
                HubDivider()
                shortcutRow("Paste last transcript", "Paste the last thing you dictated", \.pasteLast)
                HubDivider()
                shortcutRow("Open Scratchpad", "A safe place to dictate and edit", \.openScratchpad)
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

    /// Downloading / selected / on disk / not here — in that order, because
    /// only one download runs at a time and it owns the whole section while it
    /// does. "Installed" is file existence only: hashing three models on every
    /// render is exactly ghost-pepper #163.
    @ViewBuilder
    private func modelControl(_ m: ModelCatalog.Model) -> some View {
        if model.downloadingModel == m, let progress = model.downloadProgress {
            ProgressView(value: progress).frame(width: 160)
        } else if model.downloadingModel != nil {
            EmptyView() // one download at a time
        } else if !ModelCatalog.isInstalled(m) {
            Button("Download") { model.onDownloadModel(m) }
                .buttonStyle(HubButtonStyle(kind: model.isSelected(m) ? .primary : .normal))
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
    let path: WritableKeyPath<HotkeyBindings, KeyChord>
    /// Push to talk is *held*, so it records a bare modifier off flagsChanged;
    /// every other binding waits for a real key press.
    var modifierOnly = false
    @State private var monitor: Any?

    private var chord: KeyChord { model.settings.hotkeys[keyPath: path] }
    private var original: KeyChord { HotkeyBindings()[keyPath: path] }

    var body: some View {
        HStack(spacing: 8) {
            ShortcutPill(text: monitor == nil ? chord.display : "Press keys…")
            Button(monitor == nil ? "Change" : "Cancel") {
                if monitor == nil { start() } else { stop() }
            }
            .buttonStyle(HubButtonStyle())
            if chord != original {
                Button("Reset") {
                    stop()
                    model.setHotkey(path, to: original)
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
        model.hotkeyError = nil
        HotkeyMonitor.suspended = true
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
        model.setHotkey(path, to: chord)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyMonitor.suspended = false
    }
}

// MARK: - AI Cleanup

struct CleanupPage: View {
    @ObservedObject var model: HubModel

    private var isAnthropic: Bool { model.settings.cleanup.provider != "openai-compatible" }

    // Same validation the dictation path runs (makeCleanupClient), so this
    // warning can never disagree with what actually happens. nil = cleanup
    // will run. Keyless openai-compatible is valid (local servers) — the
    // factory allows it, so no banner there.
    private var configIssue: String? {
        do {
            _ = try makeCleanupClient(settings: model.settings,
                                      env: ProcessInfo.processInfo.environment)
            return nil
        } catch let error as CleanupError {
            if error.description.contains("required") { return "no base URL is set" }
            if error.description.contains("not a valid") { return "the base URL isn't a valid http(s) URL" }
            if error.description.contains("unknown cleanup.provider") {
                return "settings.json names an unknown provider"
            }
            return "no API key is set"
        } catch {
            return "\(error)"
        }
    }

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
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            if isAnthropic {
                HubSection("Anthropic",
                           footer: "The ANTHROPIC_API_KEY environment variable takes precedence over the key stored here (terminal launches only).") {
                    HubRow("Model") {
                        TextField("claude-sonnet-5", text: $model.settings.cleanupModel)
                            .hubField().frame(width: 260)
                    }
                    HubDivider()
                    HubRow("API key", detail: "Stored in settings.json — hover to reveal") {
                        SecretField(placeholder: "sk-ant-…",
                                    text: optBinding($model.settings.anthropicApiKey))
                            .frame(width: 260)
                    }
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
                    // cleanup.apiKeyEnvVar still works via settings.json — just
                    // not advertised here; it only functions on terminal launches.
                    HubRow("API key", detail: "Stored in settings.json — hover to reveal") {
                        SecretField(placeholder: "key…",
                                    text: optBinding($model.settings.cleanup.apiKey))
                            .frame(width: 260)
                    }
                }
            }

            // Absent until the first cleanup with usage reported — an empty card
            // saying nothing is worse than no card.
            if let est = CleanupCostEstimate.over(model.historyEntries) { costSection(est) }
        }
    }

    @ViewBuilder
    private func costSection(_ est: CleanupCostEstimate) -> some View {
        HubSection("Estimated cost",
                   footer: "An estimate from published list prices, not a bill. Parla only keeps "
                       + "the last \(HistoryStore.cap) dictations, so this covers the period shown "
                       + "and nothing before it; discounts and cached input aren't counted.") {
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
                       footer: "Names and jargon spelled exactly as they should appear, e.g. “Parla”, “whisper.cpp”.") {
                if model.words.isEmpty {
                    EmptyHint(text: "No dictionary entries yet")
                } else {
                    ForEach($model.words) { $row in
                        HStack(spacing: 8) {
                            TextField("word or phrase", text: $row.text)
                                .hubField()
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
            Button {
                model.words.append(.init())
            } label: {
                Label("Add word", systemImage: "plus")
            }
            .buttonStyle(HubButtonStyle(kind: .primary))
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

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return model.historyEntries }
        return model.historyEntries.filter {
            $0.raw.localizedCaseInsensitiveContains(query)
                || ($0.cleaned?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.appName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

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

                Button("Clear History") { confirmClear = true }
                    .buttonStyle(HubButtonStyle(kind: .danger))
                    .disabled(model.historyEntries.isEmpty)
                    .confirmationDialog("Delete all \(model.historyEntries.count) dictations?",
                                        isPresented: $confirmClear) {
                        Button("Delete All", role: .destructive) { model.clearHistory() }
                    }
            }

            if filtered.isEmpty {
                VStack(spacing: 0) {
                    EmptyHint(text: model.historyEntries.isEmpty
                        ? "No dictations yet — hold fn and speak"
                        : "No matches for “\(query)”")
                }
                .frame(maxWidth: .infinity)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, entry in
                        historyRow(entry)
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.best)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
                Button {
                    model.copy(entry.best)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Copy")
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
    @State private var confirmClearRecordings = false
    /// Read on appear rather than published: the dictation path writes this
    /// folder, and this page is the only thing that ever shows it.
    @State private var recordings = RecordingStore.Summary(count: 0, bytes: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HubSection("History",
                       footer: "Secure-field and cancelled dictations are never recorded, regardless of this setting.") {
                HubRow("Keep local history",
                       detail: "Last \(HistoryStore.cap) dictations, on this Mac only") {
                    Toggle("", isOn: $model.settings.historyEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow("Clear history",
                       detail: "\(model.historyEntries.count) dictations stored") {
                    Button("Clear…") { confirmClear = true }
                        .buttonStyle(HubButtonStyle(kind: .danger))
                        .disabled(model.historyEntries.isEmpty)
                        .confirmationDialog("Delete all \(model.historyEntries.count) dictations?",
                                            isPresented: $confirmClear) {
                            Button("Delete All", role: .destructive) { model.clearHistory() }
                        }
                }
            }

            if RecordingStore.shared.keepAll {
                HubBanner(text: "PARLA_KEEP_RECORDINGS=1 — every dictation's audio is being kept "
                    + "for \(RecordingStore.retentionDays) days, not just the failed ones.")
            }
            HubSection("Recordings",
                       footer: "Parla saves each dictation's audio just before transcribing it, so a "
                           + "crash mid-transcription can't take what you said with it, and deletes it "
                           + "the moment a transcript comes back. Only dictations that failed are left "
                           + "behind. Audio from a password field is never kept.") {
                HubRow("Deleted after \(RecordingStore.retentionDays) days",
                       detail: recordings.count == 0 ? "Nothing stored"
                           : "\(recordings.count) recording\(recordings.count == 1 ? "" : "s") · "
                               + ByteCountFormatter.string(fromByteCount: Int64(recordings.bytes),
                                                           countStyle: .file)) {
                    Button("Show in Finder") {
                        // The folder may not exist yet — nothing has ever failed.
                        try? FileManager.default.createDirectory(
                            at: RecordingStore.shared.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(RecordingStore.shared.directory)
                    }
                    .buttonStyle(HubButtonStyle())
                }
                HubDivider()
                HubRow("Delete recordings",
                       detail: "16 kHz mono WAV — the format eval/cases uses") {
                    Button("Delete…") { confirmClearRecordings = true }
                        .buttonStyle(HubButtonStyle(kind: .danger))
                        .disabled(recordings.count == 0)
                        .confirmationDialog("Delete all \(recordings.count) recordings?",
                                            isPresented: $confirmClearRecordings) {
                            Button("Delete All", role: .destructive) {
                                RecordingStore.shared.clear()
                                recordings = RecordingStore.shared.summary()
                            }
                        }
                }
            }

            HubSection("How Parla handles your data") {
                HubRow("Transcription is on-device",
                       detail: "Audio never leaves this Mac — whisper.cpp runs locally") { EmptyView() }
                HubDivider()
                HubRow("Clipboard is never touched",
                       detail: "Text is typed in directly and stored only in history — nothing reaches the clipboard unless you press Copy") { EmptyView() }
                HubDivider()
                HubRow("Password fields are protected",
                       detail: "Dictation is refused in secure fields — nothing is typed, stored, or sent to the cleanup model") { EmptyView() }
                HubDivider()
                HubRow("Cleanup sends text only",
                       detail: "The transcript, the selected text for voice commands, your dictionary, snippets, and the frontmost app's name — never audio") { EmptyView() }
            }
        }
        // Prune before summarising, not just for tidiness: the sweep otherwise
        // only runs when the next dictation is stashed, so this page could list
        // — and total up — files it is simultaneously claiming are deleted.
        .onAppear {
            RecordingStore.shared.prune()
            recordings = RecordingStore.shared.summary()
        }
    }
}
