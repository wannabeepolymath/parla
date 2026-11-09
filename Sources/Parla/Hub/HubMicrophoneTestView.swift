import ParlaCore
import SwiftUI

struct HubMicrophoneTestView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var test: MicrophoneTestController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HubSection("Test your microphone", footer: "Records up to 10 seconds. The audio isn’t saved or transcribed. Use headphones when you listen back.") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message(test.state)).foregroundStyle(Theme.text)
                    if test.state == .stopped || test.state == .listening {
                        Text(message(test.captureStatus)).foregroundStyle(Theme.muted)
                    }
                    if let name = test.route.name { Text("Microphone: \(name)").font(.system(size: 13)) }
                    if test.route.fallback == true {
                        Text("Your chosen microphone isn’t available, so the system default is used.").foregroundStyle(Theme.muted)
                    }
                    if test.routeChanged { Text("The microphone changed during the test.").foregroundStyle(Theme.muted) }
                    ProgressView(value: Double(test.level), total: 1)
                    HStack {
                        Button("Start test") { model.startMicrophoneTest() }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                        Button("Stop") { model.stopMicrophoneTest() }.disabled(!test.capturing)
                            .buttonStyle(HubButtonStyle())
                        Button(test.playerActive ? "Stop listening" : "Listen") {
                            if test.playerActive { model.stopListeningMicrophoneTest() } else { model.listenMicrophoneTest() }
                        }
                        .disabled(test.capturing || !test.hasReview).buttonStyle(HubButtonStyle())
                        Button("Clear") { model.clearMicrophoneTest() }.buttonStyle(HubButtonStyle())
                    }
                }.padding(14)
            }
            Text("Click Clear when you’re done to use dictation again.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
    }
    private func message(_ state: MicrophoneTestController.State) -> String {
        switch state {
        case .idle: return "Click Start test and say something."
        case .starting: return "Starting…"
        case .signal: return "Your microphone is working."
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
