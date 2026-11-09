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

    private static let titles = ["Give Parla permission", "Pick a speech model", "Try it out"]
    private static let subtitles = [
        // The mic is opened per dictation by default (warm mic is opt-in).
        "Parla uses the mic while you dictate and types what you say into the app you're using.",
        // Scoped to audio on purpose: online cleanup does send text.
        "Speech recognition runs on this Mac. Your audio never leaves it.",
        "Try one dictation. The text appears here, not in another app."
    ]

    /// The primary button's gate. Skip is always there, so nobody is trapped.
    private var ready: Bool {
        switch step {
        case 0: return model.micGranted && model.axGranted
        case 1: return model.modelInstalled
        default: return transcript != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepView
                }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
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
            HStack(spacing: 6) {
                ForEach(0..<Self.titles.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Theme.accent : Theme.border)
                        .frame(width: i == step ? 22 : 10, height: 4)
                }
            }
            .padding(.bottom, 10)
            Text(Self.titles[step])
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(Self.subtitles[step])
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.top, 48) // room for the traffic lights
        .padding(.bottom, 22)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 {
                // Leaving the tryout step backwards releases the mic and the
                // hotkey too — only advance() used to.
                Button("Back") { endTryout(); step -= 1 }.buttonStyle(HubButtonStyle())
            }
            Spacer()
            Button(step == Self.titles.count - 1 ? "Skip" : "Skip this step") { advance() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
            Button(step == Self.titles.count - 1 ? "Start using Parla" : "Continue") { advance() }
                .buttonStyle(HubButtonStyle(kind: .primary))
                .disabled(!ready)
                .opacity(ready ? 1 : 0.5)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
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
        VStack(alignment: .leading, spacing: 18) {
            HubSection("Permissions") {
                HubRow("Microphone",
                       detail: "Used only while you dictate") {
                    if model.micGranted {
                        StatusChip(text: "Granted")
                    } else {
                        Button("Allow") { model.requestMicrophone() }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                    }
                }
                HubDivider()
                HubRow("Accessibility", detail: "Needed for shortcuts and typing into apps") {
                    if model.axGranted {
                        StatusChip(text: "Granted")
                    } else {
                        Button("Open System Settings") { model.openPrivacyPane("Privacy_Accessibility") }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                    }
                }
            }
            Button("Test your microphone") { model.requestedPage = .microphone }
                .buttonStyle(HubButtonStyle())
            if !model.axGranted { dragTile }
        }
    }

    /// The Accessibility list accepts a dropped app, so dragging Parla into it
    /// adds it outright. "Open System Settings" alone leaves the user hunting for
    /// a `+` button and a file picker.
    private var dragTile: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
            Text("Drag Parla into the Accessibility list")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Open System Settings, drop Parla into the list and turn it on.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(Theme.border))
        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
    }

    // MARK: - 2. Model

    private var modelStep: some View {
        HubSection("Speech model",
                   footer: "You can change models later in General. Larger models are more accurate but slower.") {
            HubRow(ModelCatalog.default.displayName,
                   detail: "\(ModelCatalog.default.sizeLabel) · works offline once downloaded") {
                if model.modelInstalled {
                    StatusChip(text: "Downloaded")
                } else if let progress = model.downloadProgress {
                    ProgressView(value: progress).frame(width: 160)
                } else {
                    Button("Download") { model.onDownloadModel(ModelCatalog.default) }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                }
            }
        }
    }

    // MARK: - 3. Sandboxed tryout

    private var tryout: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let tryoutError { HubBanner(text: tryoutError) }
            HubSection("Dictation test",
                       footer: "After setup, dictation types wherever your cursor is.") {
                HubRow(recording ? "Listening…" : transcribing ? "Transcribing…" : "Say a sentence",
                       detail: recording ? "Click Stop when you're done"
                           : "Parla shows you what it heard") {
                    Button(recording ? "Stop" : transcript == nil ? "Start" : "Try again") {
                        if recording { stopTryout() } else { startTryout() }
                    }
                    .buttonStyle(HubButtonStyle(kind: .primary))
                    .disabled(transcribing)
                }
                if let transcript {
                    HubDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transcript.isEmpty ? "Nothing was heard. Try again a little louder."
                                                : transcript)
                            .font(.system(size: 13))
                            .foregroundStyle(transcript.isEmpty ? Theme.muted : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
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
