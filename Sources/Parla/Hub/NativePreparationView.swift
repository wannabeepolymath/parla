import ParlaCore
import SwiftUI

/// Troubleshooting: microphone check, Safe Start and diagnostics in one place.
/// Both `.microphone` and `.safeStart` deep links land here (the menu's
/// "Safe Start…" opens it alone, before the model loads).
struct TroubleshootingPage: View {
    @ObservedObject var model: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            HubMicrophoneTestView(model: model, test: model.microphoneTest)
            NativePreparationView(model: model)
            HubDiagnosticsView(model: model)
        }
    }
}

/// Safe Start. Switching engines — the way out of a crashing model — is one
/// click away in General rather than duplicated here.
struct NativePreparationView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        let snapshot = model.preparationSnapshot
        HubSection("Safe Start", footer: "If a model keeps crashing, switch to another speech engine.") {
            if model.settings.recognitionEngine == .parakeet {
                HubRow("Not used with Parakeet", detail: "Safe Start protects Whisper models while they load")
            } else {
                HubToggleRow("Skip a model that crashes while loading",
                             detail: "Parla watches Whisper models as they load. If one crashes Parla twice, it’s skipped on the next launch so the app stays usable.",
                             isOn: Binding(get: { model.settings.nativePreparationSafeStartEnabled },
                                           set: { model.setPreparationEnabled($0) }))
                if model.settings.nativePreparationSafeStartEnabled || snapshot.status != .off {
                    HubDivider()
                    HubRow("Status", detail: snapshot.message) {
                        HStack(spacing: 8) {
                            ForEach(NativePreparation.Action.allCases, id: \.self) { action in
                                Button(action.rawValue) { model.onPreparationAction(action, snapshot.token) }
                                    .buttonStyle(HubButtonStyle())
                            }
                        }
                    }
                }
                if !model.settings.nativePreparationSafeStartEnabled, snapshot.status != .off {
                    HubDivider()
                    HubRow("Turning Safe Start off", detail: "Save to stop tracking crashes") {
                        Button("Save and Turn Off") { model.savePreparationDraft() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
            HubDivider()
            HubRow("Speech engine", detail: engineName) {
                Button("Go to General") { model.requestedPage = .general }.buttonStyle(HubButtonStyle())
            }
        }
        .disabled(model.loadError != nil)
    }

    private var engineName: String {
        switch model.settings.recognitionEngine {
        case .whisper: return "Whisper"
        case .appleSpeech: return "Apple Speech"
        case .parakeet: return "Parakeet"
        default: return "Not chosen"
        }
    }
}
