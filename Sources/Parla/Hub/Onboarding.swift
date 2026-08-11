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
        // Says "keeps the mic open", not "listens only while you hold": since
        // AudioRecorder.prepare() the input unit runs from launch, so the old
        // copy promised a closed mic the app does not have.
        "Parla keeps the mic open so dictation starts instantly, transcribes only while you hold a key, and types the result into whatever you're using.",
        "Speech recognition runs on this Mac. Nothing you say leaves it.",
        "One dictation, straight into this window — nothing is typed anywhere else."
    ]

    /// The primary button's gate. Skip is always there, so nobody is trapped.
    private var ready: Bool {
        switch step {
        case 0: return model.micGranted && model.axGranted
        case 1: return model.modelLoaded
        default: return transcript != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { stepView }
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
                       detail: "Stays open so dictation starts instantly; transcribes only "
                           + "while you hold the push-to-talk key") {
                    if model.micGranted {
                        StatusChip(text: "Granted")
                    } else {
                        Button("Allow") { model.requestMicrophone() }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                    }
                }
                HubDivider()
                HubRow("Accessibility", detail: "The global hotkey, and typing into the app you're in") {
                    if model.axGranted {
                        StatusChip(text: "Granted")
                    } else {
                        Button("Open System Settings") { model.openPrivacyPane("Privacy_Accessibility") }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                    }
                }
            }
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
            Text("Open the list above, then drop it in and switch it on.")
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
                   footer: "You can switch models later in General. Larger ones are more accurate and slower.") {
            HubRow(ModelCatalog.default.displayName,
                   detail: "\(ModelCatalog.default.sizeLabel) · downloaded once, then used offline") {
                if model.modelLoaded {
                    StatusChip(text: "Ready")
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
                       footer: "This one goes nowhere else: the transcript appears here, and is never "
                           + "typed into another app. Every other dictation lands wherever your "
                           + "cursor is.") {
                HubRow(recording ? "Listening…" : transcribing ? "Transcribing…" : "Say a sentence",
                       detail: recording ? "Press Stop when you're done"
                           : "Parla records, transcribes on this Mac, and shows you what it heard") {
                    Button(recording ? "Stop" : transcript == nil ? "Start" : "Try again") {
                        if recording { stopTryout() } else { startTryout() }
                    }
                    .buttonStyle(HubButtonStyle(kind: .primary))
                    .disabled(transcribing)
                }
                if let transcript {
                    HubDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transcript.isEmpty ? "Nothing was heard — try again, a little louder."
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
        guard recording else { return }
        recording = false
        model.onTryoutStop { _ in }
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
        guard !session.isCapturing else { return "Finish the dictation that's already running first." }
        guard activeTranscriber() != nil else { return "No speech model is loaded yet." }
        // The push-to-talk key must not start a real dictation on top of this
        // one — it would type into whatever is behind the Hub window.
        HotkeyMonitor.suspended = true
        do {
            try recorder.start()
        } catch {
            HotkeyMonitor.suspended = false
            return "Couldn't start the microphone: \(error)"
        }
        hud.show(.listening(command: false))
        return nil
    }

    func tryoutStop(_ done: @escaping (String) -> Void) {
        HotkeyMonitor.suspended = false
        let samples = recorder.stop()
        guard let transcriber else { done(""); hud.hide(); return }
        hud.show(.transcribing)
        // On the same chain as every other whisper pass: the ctx isn't reentrant.
        processTask = Task { [prev = processTask] in
            await prev?.value
            // Same floor the real pipeline uses — below it whisper hallucinates a
            // sentence out of silence, which is the worst possible first impression.
            let text = TextRules.audioWorthTranscribing(sampleCount: samples.count,
                                                        rms: AudioRecorder.rms(samples))
                ? transcriber.transcribe(samples, initialPrompt: nil) : ""
            await MainActor.run {
                // Back to idle on every exit. `.preview` is a mid-recording state
                // in the real pipeline — a terminal state always follows it and
                // schedules the hide. Nothing follows the tryout, so showing it
                // here stranded the pill on screen, recording dot lit, until the
                // next dictation. The transcript is in the Hub window anyway.
                self.hud.hide()
                done(text)
            }
        }
    }
}
