import ParlaCore
import SwiftUI

struct HubMicrophoneTestView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var test: MicrophoneTestController

    var body: some View {
        HubSection("Microphone test",
                   footer: "Records up to 10 seconds. Nothing is saved or transcribed. Dictation is paused until you clear the test or leave this page.") {
            HubRow(message(test.state), detail: detail) {
                if test.capturing {
                    Button("Stop") { model.stopMicrophoneTest() }.buttonStyle(HubButtonStyle(kind: .primary))
                } else {
                    Button(test.hasReview ? "Test Again" : "Start Test") { model.startMicrophoneTest() }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                }
            }
            LevelMeter(level: test.level)
                .padding(.horizontal, HubLayout.rowInset)
                .padding(.bottom, 14)
            HubDivider()
            HubRow("Microphone", detail: test.route.name.map { "Recording from \($0)" } ?? MicrophonePicker.detail(for: model.settings.inputDeviceUID)) {
                MicrophonePicker(selection: $model.settings.inputDeviceUID).disabled(test.capturing || model.loadError != nil)
            }
            if test.hasReview || test.ownsSession {
                HubDivider()
                HubRow("Recording", detail: "Use headphones when you listen back") {
                    HStack(spacing: 8) {
                        Button("Clear") { model.clearMicrophoneTest() }.buttonStyle(HubButtonStyle())
                        Button(test.playerActive ? "Stop Listening" : "Listen") {
                            if test.playerActive { model.stopListeningMicrophoneTest() } else { model.listenMicrophoneTest() }
                        }
                        .buttonStyle(HubButtonStyle())
                        .disabled(test.capturing || !test.hasReview)
                    }
                }
            }
        }
    }

    private var detail: String? {
        var notes: [String] = []
        if test.state == .stopped || test.state == .listening { notes.append(message(test.captureStatus)) }
        if test.route.fallback == true { notes.append("Your chosen microphone isn’t available, so the system default is used.") }
        if test.routeChanged { notes.append("The microphone changed during the test.") }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private func message(_ state: MicrophoneTestController.State) -> String {
        switch state {
        case .idle: return "Click Start Test and say something"
        case .starting: return "Starting…"
        case .signal: return "Your microphone is working"
        case .silentPCM: return "No sound detected. Speak up or check your microphone."
        case .conversionFailure: return "Some audio couldn’t be read. Try again."
        case .noPCM: return "No audio received. Check your microphone and access."
        case .stoppedBeforePCM: return "Stopped before any audio arrived."
        case .routeLost: return "The microphone disconnected."
        case .stopped: return "Stopped. Click Listen to hear it."
        case .listening: return "Playing…"
        case .refused(let reason), .failed(let reason): return reason
        }
    }
}
