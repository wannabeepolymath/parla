import ParlaCore
import SwiftUI

struct NativePreparationView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Recognition engine", selection: $model.settings.recognitionEngine) {
                Text("Whisper").tag(RecognitionEngine.whisper)
                Text("Apple Speech · batch").tag(RecognitionEngine.appleSpeech)
                if model.settings.recognitionEngine == .parakeet || model.parakeetChoiceRefusal == nil {
                    Text("Parakeet · local batch").tag(RecognitionEngine.parakeet)
                }
                if model.settings.recognitionEngine == .invalid { Text("Invalid configuration").tag(RecognitionEngine.invalid) }
            }
            if model.settings.recognitionEngine == .parakeet {
                Text(model.recognitionCapabilityDetail)
                ParakeetGlobalControls(model: model)
            } else {
                TextField("Exact Apple locale, for example en-US", text: optBinding($model.settings.appleSpeechLocale))
                AppleSpeechControls(model: model)
            }
            if model.settings.recognitionEngine != .parakeet {
            DisclosureGroup("Parakeet installation") { ParakeetControls(model: model) }
            Divider()
            Text("Optional Safe Start").font(.headline)
            Text("Default off. For verified catalog Whisper models, tracks construction, explicit synthetic warmup, and the first real-audio recognition request on each native instance. A request can include several native calls. This does not isolate hidden preparation or diagnose GPU faults.")
            Toggle("Enable Safe Start with new consent", isOn: Binding(
                get: { model.settings.nativePreparationSafeStartEnabled }, set: { model.setPreparationEnabled($0) }))
            Text(model.preparationSnapshot.message).font(.callout)
            Text("Tiny private, content-free local records hold preparation after two unresolved records for the same model, loaded build and phase. Unknown records can include a completed return whose later writes all failed before process death. They are not confirmed crashes, forced kills, or evidence of GPU faults.")
                .font(.caption).foregroundStyle(Theme.muted)
            if model.settings.nativePreparationSafeStartEnabled || model.preparationSnapshot.status != .off {
                let token = model.preparationSnapshot.token
                HStack {
                    ForEach(NativePreparation.Action.allCases, id: \.self) { action in
                        Button(action.rawValue) { model.onPreparationAction(action, token) }
                    }
                }
                Text("Retry performs construction and synthetic warmup only. It cannot clear a first-real-request hold. After native work exits, Reset recovery state, then start a new action. A failed or canceled first stream request also refuses later final recognition on that instance. Reset does not replay audio.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if !model.settings.nativePreparationSafeStartEnabled, model.preparationSnapshot.status != .off {
                Button("Save opt-out after preparation exits") { model.savePreparationDraft() }
            }
            Text("While enabled, canceled-capture Undo requires the same resident to have completed both synthetic warmup and a real recognition request. Undo never prepares a model, waits for recovery, or writes Safe Start records.")
                .font(.caption).foregroundStyle(Theme.muted)
            Text("Earlier saved consent does not cover this expanded scope. Turn Safe Start off, save, and explicitly enable it again. Records are finite: at most 12 entries; capacity refuses without evicting unresolved history.")
                .font(.caption).foregroundStyle(Theme.muted)
            Text("A linker UUID identifies a loaded build; it is not signed attestation or driver/GPU evidence. File metadata is freshness evidence, not a hash of current model bytes. Force quit, failed storage and power loss have limits.")
                .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}
