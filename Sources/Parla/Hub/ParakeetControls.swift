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
            if target == nil { Text("Save valid settings/profile and reload before acting.").font(.caption) }
            HStack {
                Button("Install") { if let target { model.parakeetAction(.install, target: target) } }.disabled(target == nil || !state.canInstall)
                Button("Prepare") { if let target { model.parakeetAction(.prepare, target: target) } }.disabled(target == nil || !state.canPrepare)
                Button("Recheck") { if let target { model.parakeetAction(.recheck, target: target) } }.disabled(target == nil || !state.canRecheck)
                Button("Retry") { if let target { model.parakeetAction(.retry, target: target) } }.disabled(target == nil || !state.canRetry)
                Button("Cancel") { model.onParakeetCancel(state.token) }.disabled(!state.canCancel)
                Button("Delete") { if let target { model.parakeetAction(.delete, target: target) } }.disabled(target == nil || !state.canDelete)
            }
            Text("Fixed pinned 21-file INT4 release. Install never selects or prepares it. Retry revalidates completed files and re-fetches the interrupted file; no byte-offset resume. Recheck is read-only. Delete protects saved global/profile references and live leases.")
                .font(.caption).foregroundStyle(Theme.muted)
            Text("Source enabler only. Reviewed full release hashes, selected-artifact terms and independently trusted G3 production identity are still required. Production packaging and native qualification remain separate.")
                .font(.caption).foregroundStyle(Theme.muted)
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
            if inherits { Text("Inherit global").tag(Optional<String>.none) }
            Text(ParakeetWire.model).tag(Optional(ParakeetWire.model))
            if let modelID, modelID != ParakeetWire.model { Text("Invalid saved model").tag(Optional(modelID)) }
        }
        Picker("Script filter", selection: $filter) {
            Text(inherits ? "Inherit global" : "Unfiltered multilingual").tag(Optional<String>.none)
            if inherits { Text("None · unfiltered multilingual").tag(Optional("none")) }
            ForEach(ParakeetWire.filters.sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            if let filter, !ParakeetWire.filters.contains(filter), !(inherits && filter == "none") {
                Text("Invalid saved filter").tag(Optional(filter))
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
