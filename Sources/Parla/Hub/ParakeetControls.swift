import ParlaCore
import SwiftUI

/// Cached scalar controls for an already-saved Parakeet choice. Rendering has no
/// IO, provider, helper or settings-write port. Actions require saved authority.
struct ParakeetControls: View {
    @ObservedObject var model: HubModel
    var targetID: ParakeetPreparation.TargetID = .global
    var body: some View {
        let state = model.parakeetControlSnapshot(targetID)
        let target = model.parakeetTarget(targetID)
        VStack(alignment: .leading, spacing: 10) {
            Text(state.message).font(.callout)
            if let bytes = state.bytes, let total = state.total {
                ProgressView(value: Double(bytes), total: Double(total))
            }
            if target == nil { Text("Save your settings first.").font(.caption) }
            HStack {
                Button("Install") { if let target { model.parakeetAction(.install, target: target) } }.disabled(target == nil || !state.canInstall)
                Button("Prepare") { if let target { model.parakeetAction(.prepare, target: target) } }.disabled(target == nil || !state.canPrepare)
                Button("Check") { if let target { model.parakeetAction(.recheck, target: target) } }.disabled(target == nil || !state.canRecheck)
                Button("Retry") { if let target { model.parakeetAction(.retry, target: target) } }.disabled(target == nil || !state.canRetry)
                Button("Cancel") { model.onParakeetCancel(state.token) }.disabled(!state.canCancel)
                Button("Delete") { if let target { model.parakeetAction(.delete, target: target) } }.disabled(target == nil || !state.canDelete)
            }
        }
    }
}

/// Fixed public domain only. Unknown saved strings stay visible until explicitly edited.
struct ParakeetSettingsFields: View {
    @Binding var modelID: String?
    @Binding var filter: String?
    var inherits = false
    var body: some View {
        Picker("Parakeet model", selection: $modelID) {
            if inherits { Text("Same as global").tag(Optional<String>.none) }
            Text(ParakeetWire.model).tag(Optional(ParakeetWire.model))
            if let modelID, modelID != ParakeetWire.model { Text("Unknown model").tag(Optional(modelID)) }
        }
        Picker("Languages", selection: $filter) {
            Text(inherits ? "Same as global" : "All languages").tag(Optional<String>.none)
            if inherits { Text("All languages").tag(Optional("none")) }
            ForEach(ParakeetWire.filters.sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            if let filter, !ParakeetWire.filters.contains(filter), !(inherits && filter == "none") {
                Text("Unknown filter").tag(Optional(filter))
            }
        }
    }
}
struct ParakeetGlobalControls: View {
    @ObservedObject var model: HubModel
    var body: some View {
        ParakeetSettingsFields(modelID: Binding(get: { model.settings.parakeetModelID },
            set: { if let value = $0 { model.settings.parakeetModelID = value } }), filter: $model.settings.parakeetLanguageFilter)
        ParakeetControls(model: model)
    }
}
