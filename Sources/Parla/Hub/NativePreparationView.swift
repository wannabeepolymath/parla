import ParlaCore
import SwiftUI

struct NativePreparationView: View {
    @ObservedObject var model: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Speech engine", selection: $model.settings.recognitionEngine) {
                Text("Whisper").tag(RecognitionEngine.whisper)
                Text("Apple Speech").tag(RecognitionEngine.appleSpeech)
                if model.settings.recognitionEngine == .parakeet || model.parakeetChoiceRefusal == nil {
                    Text("Parakeet").tag(RecognitionEngine.parakeet)
                }
                if model.settings.recognitionEngine == .invalid { Text("Choose an engine").tag(RecognitionEngine.invalid) }
            }
            if model.settings.recognitionEngine == .parakeet {
                if !model.recognitionCapabilityDetail.isEmpty { Text(model.recognitionCapabilityDetail) }
                ParakeetGlobalControls(model: model)
            } else {
                TextField("Apple Speech language, e.g. en-US", text: optBinding($model.settings.appleSpeechLocale))
                AppleSpeechControls(model: model)
            }
            if model.settings.recognitionEngine != .parakeet {
            if model.parakeetChoiceRefusal == nil {
                DisclosureGroup("Parakeet model") { ParakeetControls(model: model) }
            }
            Divider()
            Text("Safe Start").font(.headline)
            Text("If a Whisper model crashes Parla twice while loading, Safe Start stops loading it so Parla stays usable.")
            Toggle("Turn on Safe Start", isOn: Binding(
                get: { model.settings.nativePreparationSafeStartEnabled }, set: { model.setPreparationEnabled($0) }))
            Text(model.preparationSnapshot.message).font(.callout)
            if model.settings.nativePreparationSafeStartEnabled || model.preparationSnapshot.status != .off {
                let token = model.preparationSnapshot.token
                HStack {
                    ForEach(NativePreparation.Action.allCases, id: \.self) { action in
                        Button(action.rawValue) { model.onPreparationAction(action, token) }
                    }
                }
            }
            if !model.settings.nativePreparationSafeStartEnabled, model.preparationSnapshot.status != .off {
                Button("Save and turn off") { model.savePreparationDraft() }
            }
            }
        }
    }
}
