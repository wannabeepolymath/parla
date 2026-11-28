import AppKit
import ParlaCore
import SwiftUI

/// First run: permissions, a model, and one dictation that goes nowhere but
/// Parla's own window. Shown in place of the Hub's normal UI while
/// `Settings.onboardingCompleted` is false — before this, a fresh user got a ⚠️
/// in the menu bar and had to go find the menu to learn why.
struct OnboardingView: View {
    @ObservedObject var model: HubModel
    @State private var step = 0
    @State private var recording = false
    @State private var transcribing = false
    @State private var transcript: String?
    @State private var tryoutError: String?
    // Same 2 s poll the General page uses: permissions are granted in another
    // process and there is no notification for it.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let titles = ["Give Parla permission", "Download a speech model", "Try it out"]
    private static let subtitles = [
        // The mic is opened per dictation by default (warm mic is opt-in).
        "Parla listens while you dictate and types what you say into the app you’re using.",
        // Scoped to audio on purpose: online cleanup does send text.
        "Speech recognition runs on this Mac. Your audio never leaves it.",
        "" // step 3 names the configured key, see subtitle
    ]
    /// One centered column for header, steps and footer controls.
    private static let column: CGFloat = 600

    private var key: String { keycapText(model.shortcutDisplay(model.settings.hotkeys.pushToTalk)) }
    private var subtitle: String {
        step == 2 ? "First, check that Parla can hear you. After setup, hold \(key) to dictate in another app." : Self.subtitles[step]
    }

    /// The primary button's gate. Skip is always there, so nobody is trapped.
    private var ready: Bool {
        switch step {
        case 0: return model.micGranted && model.axGranted
        // A running download keeps going after this step, so it doesn't block Continue.
        case 1: return model.modelInstalled || model.downloadProgress != nil
        default: return transcript != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        stepView
                    }
                    .padding(.horizontal, 32)
                    // A fixed, lower anchor balances the window without the header
                    // jumping between steps or when a result appears.
                    .padding(.top, 88)
                    .padding(.bottom, 24)
                    .frame(maxWidth: Self.column + 64, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(Theme.bg)
        .tint(Theme.accent)
        .onReceive(tick) { _ in model.refreshPermissions() }
        .onDisappear(perform: endTryout)
        // onDisappear cannot cover a window close: HubWindowController keeps the
        // window (isReleasedWhenClosed = false), so the view is never torn down
        // and the tryout would hold the mic and a suspended hotkey tap forever.
        // Not filtered to the Hub's own window on purpose — endTryout's
        // `recording` guard is what keeps this off a real dictation, and a stray
        // stop of the tryout is harmless where a missed one leaks.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            endTryout()
        }
        // Minimising or switching apps closes nothing, and left the mic open
        // and the hotkey suspended behind a window nobody was looking at.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            endTryout()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if step == 0 {
                // First screen only: who this is and what it does.
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome to Parla").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("Hold a key, speak, and your words appear.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.bottom, 20)
            }
            HStack(spacing: 6) {
                ForEach(0..<Self.titles.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Theme.accent : Theme.muted.opacity(0.45))
                        .frame(width: i == step ? 22 : 10, height: 4)
                }
            }
            .padding(.bottom, 12)
            .accessibilityElement()
            .accessibilityLabel("Step \(step + 1) of \(Self.titles.count)")
            Text(step == 0 && ready ? "Permissions granted" : Self.titles[step])
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step > 0 {
                // Leaving the tryout step backwards releases the mic and the
                // hotkey too — only advance() used to.
                Button("Back") { endTryout(); step -= 1 }.buttonStyle(HubButtonStyle())
            }
            Menu("Having Trouble?") {
                Button("Test Microphone") { model.requestedPage = .microphone }
                Button("Safe Start…") { model.requestedPage = .safeStart }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .padding(.leading, step == 0 ? -3 : 0) // the menu's own inset; align its text to the column
            Spacer()
            if !ready {
                Button("Skip") { advance() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.trailing, 8)
            }
            Button(step == Self.titles.count - 1 ? "Start Using Parla"
                   : step == 1 && !model.modelInstalled && model.downloadProgress != nil ? "Continue While Downloading" : "Continue") { advance() }
                .buttonStyle(HubButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: Self.column + 64)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var stepView: some View {
        switch step {
        case 0: permissions
        case 1: modelStep
        default: tryout
        }
    }

    // MARK: - 1. Permissions

    private var permissions: some View {
        HubSection(nil) {
            HubRow("Microphone", detail: "Used only while you dictate") {
                if model.micGranted {
                    StatusChip(text: "Granted")
                } else {
                    Button("Allow") { model.requestMicrophone() }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                }
            }
            HubDivider()
            HubRow("Accessibility", detail: "Lets Parla hear shortcuts and type into apps") {
                if model.axGranted {
                    StatusChip(text: "Granted")
                } else {
                    Button("Open System Settings") { model.openPrivacyPane("Privacy_Accessibility") }
                        .buttonStyle(HubButtonStyle(kind: model.micGranted ? .primary : .normal))
                }
            }
            if !model.axGranted {
                HubDivider()
                dragTile
            }
        }
    }

    /// The Accessibility list accepts a dropped app, so dragging Parla into it
    /// adds it outright. "Open System Settings" alone leaves the user hunting for
    /// a `+` button and a file picker.
    private var dragTile: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag this icon into the Accessibility list")
                    .font(.system(size: 13)).foregroundStyle(Theme.text)
                Text("Then turn Parla on in System Settings.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Label("Drag", systemImage: "arrow.up.right")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, HubLayout.rowInset)
        .padding(.vertical, 10)
        .background(Theme.accentFill.opacity(0.25))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
        .help("Drag Parla into the list in System Settings › Privacy & Security › Accessibility")
    }

    // MARK: - 2. Model

    /// The model this step downloads: the one selected, if it's a catalog model.
    private var stepModel: ModelCatalog.Model {
        ModelCatalog.all.first { model.isSelected($0) } ?? ModelCatalog.default
    }

    private var modelStep: some View {
        let m = stepModel
        let multilingual = ModelCatalog.all.last
        return HubSection(nil, footer: model.downloadProgress != nil && !model.modelInstalled
                          ? "The download keeps going if you continue. You can switch models later in General."
                          : "You can switch models later in General. Larger models are more accurate but slower.") {
            HubRow(m.hubName,
                   detail: (m.englishOnly ? "English only · " : "About 100 languages · ") + m.sizeLabel + (model.modelInstalled ? " · Ready to use" : " · Runs offline")) {
                if model.modelInstalled {
                    StatusChip(text: "Downloaded")
                } else if let row = model.catalogDownloads[m.id], row.phase != .installed {
                    ModelDownloadProgress(model: model, catalogModel: m, row: row)
                } else if let progress = model.downloadProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress).frame(width: 120)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                            .frame(width: 34, alignment: .trailing)
                    }
                } else {
                    Button("Download") { model.onDownloadModel(m) }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                }
            }
            // Before anything downloads, offer the other language option.
            if !model.modelInstalled, model.downloadProgress == nil, let multilingual {
                HubDivider()
                if m.id == ModelCatalog.default.id {
                    HubRow("Dictating in another language?", detail: "\(multilingual.hubName) understands about 100 languages · \(multilingual.sizeLabel)") {
                        Button("Use This Instead") { model.selectModel(multilingual) }.buttonStyle(HubButtonStyle())
                    }
                } else {
                    HubRow("Only dictating in English?", detail: "\(ModelCatalog.default.hubName) is smaller and faster · \(ModelCatalog.default.sizeLabel)") {
                        Button("Use This Instead") { model.selectModel(ModelCatalog.default) }.buttonStyle(HubButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - 3. Sandboxed tryout

    /// What has to be fixed before a test dictation can work, if anything.
    private var missingPrerequisite: (text: String, action: String?, fix: () -> Void)? {
        if !model.micGranted {
            return ("Parla needs microphone access to try dictation.", "Allow Microphone", { model.requestMicrophone() })
        }
        if model.settings.recognitionEngine == .whisper && !model.modelInstalled {
            if model.downloadProgress != nil {
                return ("The speech model is still downloading. You can test once it finishes.", nil, {})
            }
            return ("Download a speech model to try dictation.", "Download Model", { endTryout(); step = 1 })
        }
        return nil
    }

    private var tryoutTitle: String {
        if recording { return "Listening…" }
        if transcribing { return "Transcribing…" }
        if let transcript { return transcript.isEmpty ? "Nothing was heard" : "Speech recognition works" }
        if missingPrerequisite != nil { return "Not ready yet" }
        return "Click Test and say a sentence"
    }

    private var tryoutDetail: String {
        if recording { return "Say a sentence, then click Stop" }
        if transcribing { return "Turning your speech into text" }
        if let transcript {
            return transcript.isEmpty ? "Try again a little louder."
                : "Click Start Using Parla, then try dictating in a text field in another app."
        }
        if missingPrerequisite != nil { return "Test becomes available once that’s done." }
        return "Parla shows the text here. Nothing is typed into other apps."
    }

    private var tryout: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            if let missing = missingPrerequisite {
                HubBanner(text: missing.text, kind: .warning, actionTitle: missing.action, actionKind: .primary, action: missing.fix)
            } else if let tryoutError {
                HubBanner(text: tryoutError)
            }
            HubSection("Check speech recognition") {
                HubRow(tryoutTitle, detail: tryoutDetail) {
                    HStack(spacing: 10) {
                        if recording { ListeningIndicator() }
                        if transcribing {
                            ProgressView().controlSize(.small).frame(height: 24)
                        } else {
                            Button(recording ? "Stop" : transcript == nil ? "Test" : "Test Again") {
                                if recording { stopTryout() } else { startTryout() }
                            }
                            .buttonStyle(HubButtonStyle(kind: transcript == nil ? .primary : .normal))
                            .disabled(missingPrerequisite != nil && !recording)
                        }
                    }
                }
                if let transcript, !transcript.isEmpty {
                    HubDivider()
                    Text(transcript)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .hubInset()
                }
            }
            // The everyday gesture, kept apart from the test: the test can't type
            // into other apps, the shortcut does once setup is finished.
            HubSection("After setup: dictate in any app", footer: "Parla stays in your menu bar. You can change the key later in General.") {
                HStack(spacing: 16) {
                    Text(key)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 56, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.control))
                        .shadow(color: .black.opacity(0.08), radius: 0, y: 2)
                        .accessibilityLabel("Key: \(key)")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hold \(key), speak, then let go")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("Your words are typed where your cursor is. While you speak, the dictation pill shows at the bottom of the screen.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, HubLayout.rowInset).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func startTryout() {
        transcript = nil
        tryoutError = model.onTryoutStart()
        recording = tryoutError == nil
    }

    private func stopTryout() {
        recording = false
        transcribing = true
        model.onTryoutStop { text in
            transcribing = false
            transcript = text
        }
    }

    /// The window can close mid-recording; the mic must not stay open for it.
    private func endTryout() {
        guard recording || transcribing else { return }
        recording = false; transcribing = false
        model.onTryoutCancel()
    }

    private func advance() {
        endTryout()
        if step < Self.titles.count - 1 {
            step += 1
        } else {
            model.settings.onboardingCompleted = true // debounced save, then the Hub proper
        }
    }
}

/// The tryout's engine. Deliberately not the dictation machine: this path has no
/// `Inserter` call anywhere in it, which is what makes "it can't type into your
/// app" a property of the code rather than a promise.
extension AppDelegate {
    func tryoutStart() -> String? {
        guard MainActor.assumeIsolated({ invocation.beginTryout() }) else { return "Finish the current dictation first." }
        let request = RecognitionRequest(settings: store.load())
        let refusal: String? = MainActor.assumeIsolated {
            guard store.lastError == nil, !invocation.secureEvidence() else { return "Can't start right now. Check your settings and try again." }
            return ParakeetAudioEntry.tryout(request, owner: parakeetPreparation, otherEngine: {
                appleSpeechPreparation.deliberateEntry()
                if request.selection.engine == .invalid { return "Choose a speech engine in General." }
                if let reason = appleSpeechPreparation.cachedRefusal(for: request) { return reason.message }
                if let reason = nativePreparation.cachedRefusal { return reason.description }
                if request.selection.engine == .whisper, !FileManager.default.fileExists(atPath: request.modelPath) { return "Download a speech model first." }
                return nil
            })
        }
        if let refusal { MainActor.assumeIsolated { invocation.endTryout() }; return refusal }
        MainActor.assumeIsolated { startup.enterDictation() }
        tryoutRecognition = request
        tryoutOperation = PendingOperation(name: "Speech tryout")
        do { try recorder.start() }
        catch {
            tryoutRecognition = nil; tryoutOperation?.revoke(); tryoutOperation?.finish(); tryoutOperation = nil
            MainActor.assumeIsolated { invocation.endTryout() }
            return "Couldn't start the microphone."
        }
        hud.show(.listening(command: false))
        return nil
    }

    func tryoutStop(_ done: @escaping (String) -> Void) {
        guard let request = tryoutRecognition, let operation = tryoutOperation else { done(""); return }
        let samples = recorder.stop()
        tryoutRecognition = nil
        hud.show(.transcribing)
        let preparationEpoch: UUID? = request.selection.engine == .whisper ? nativePreparation.core.admissionEpoch : nil
        let selectionEpoch = preparationSelectionEpoch, factory = recognitionFactory(for: request)
        processTask = RecognitionAcquisition.enqueueTryout(previous: processTask, operation: operation, work: {
            let resident = await MainActor.run { self.residentRecognition }
            var refusal: PreparationRefusal?
            let text = await RecognitionAcquisition.tryout(samples: samples, request: request,
                resident: resident, factory: factory, operation: operation,
                selectionEpoch: selectionEpoch, preparationEpoch: preparationEpoch, refused: { refusal = $0 })
            let safeStartRefusal = refusal
            await MainActor.run {
                guard request.selection.engine == .whisper else { return }
                if let safeStartRefusal { self.nativePreparation.notice(safeStartRefusal) }
                else { self.nativePreparation.refresh() }
            }
            return text
        }, current: { self.tryoutOperation == operation }, done: { done($0) }, finished: {
            guard self.tryoutOperation == operation else { return }
            self.tryoutOperation = nil
            self.invocation.endTryout(); self.hud.hide()
        })
    }
    func cancelTryout() {
        tryoutOperation?.revoke(); tryoutOperation?.requestAbort()
        if tryoutRecognition != nil { tryoutStop { _ in } }
    }
}

/// Animated waveform while the test listens (static on macOS 13).
private struct ListeningIndicator: View {
    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
            } else {
                Image(systemName: "waveform")
            }
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(Theme.accent)
        .accessibilityLabel("Listening")
    }
}
