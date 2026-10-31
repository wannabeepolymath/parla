import ParlaCore
import SwiftUI

struct HubMicrophoneTestView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var test: MicrophoneTestController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HubSection("Test your input", footer: "No speech model or cleanup provider is needed. Audio stays in memory and is never transcribed, saved or inserted.") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message(test.state)).foregroundStyle(Theme.text)
                    if test.state == .stopped || test.state == .listening {
                        Text("Capture: \(message(test.captureStatus))").foregroundStyle(Theme.muted)
                    }
                    Text(test.route.name.map { "Routed input: \($0)" } ?? "Routed input: Unknown (no native device evidence)")
                        .font(.system(size: 13))
                    if test.route.fallback == true {
                        Text("The audio unit is using a fallback input instead of the requested microphone.").foregroundStyle(Theme.muted)
                    }
                    if test.route.name != nil && test.route.fallback == nil {
                        Text("Requested-route match: Unknown").foregroundStyle(Theme.muted)
                    }
                    if test.routeChanged { Text("The routed input changed during this test.").foregroundStyle(Theme.muted) }
                    ProgressView(value: Double(test.level), total: 1)
                    Text("Latest RMS (display capped at 1): \(test.level, specifier: "%.4f") · \(test.sampleCount) / 160,000 samples")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    HStack {
                        Button("Start test") { model.startMicrophoneTest() }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                        Button("Stop") { model.stopMicrophoneTest() }.disabled(!test.capturing)
                            .buttonStyle(HubButtonStyle())
                        Button(test.playerActive ? "Stop Listening" : "Listen") {
                            if test.playerActive { model.stopListeningMicrophoneTest() } else { model.listenMicrophoneTest() }
                        }
                        .disabled(test.capturing || !test.hasReview).buttonStyle(HubButtonStyle())
                        Button("Clear") { model.clearMicrophoneTest() }.buttonStyle(HubButtonStyle())
                    }
                }.padding(14)
            }
            Text("Capture stops after 10 seconds. After Stop, the bounded review buffer remains for Listen. Clear, a new test, leaving this page, closing the window, switching away or quitting releases it. Clear to return to dictation and shortcut recording.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text("Stop recovery playback before starting or listening to a test. Listen plays only after Stop. Use headphones to avoid speaker feedback. Silence does not prove permission was denied. RMS shows amplitude, not microphone quality, clipping, SNR or a device ranking.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text("Warm microphone is temporarily suspended during the test. Your saved preference stays unchanged; it resumes on the next explicit setup or dictation entry.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
    }
    private func message(_ state: MicrophoneTestController.State) -> String {
        switch state {
        case .idle: return "Ready. Start a short microphone test."
        case .starting: return "Starting — waiting for input PCM."
        case .signal: return "PCM received; signal detected during this test."
        case .silentPCM: return "PCM received; no signal detected during this test."
        case .conversionFailure: return "Input conversion failed for one or more buffers."
        case .noPCM: return "No input PCM callback within 2 seconds. Check the route and setup."
        case .stoppedBeforePCM: return "Stopped before any input PCM callback. Permission and signal are unknown."
        case .routeLost: return "Input route was lost. Capture is closed."
        case .stopped: return "Capture stopped. Listen to review, or Clear to release the audio."
        case .listening: return "Playing the stopped test locally."
        case .refused(let reason), .failed(let reason): return reason
        }
    }
}
