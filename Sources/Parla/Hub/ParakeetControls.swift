import ParlaCore
import SwiftUI

/// Cached scalar controls for an already-saved Parakeet choice. Rendering has no
/// IO, provider, helper or settings-write port. Actions require saved authority.
/// Only the actions that apply right now are shown.
struct ParakeetControls: View {
    @ObservedObject var model: HubModel
    var targetID: ParakeetPreparation.TargetID = .global
    var body: some View {
        let state = model.parakeetControlSnapshot(targetID)
        let target = model.parakeetTarget(targetID)
        let actions: [(String, ParakeetPreparation.Action, Bool)] = [
            ("Install", .install, state.canInstall), ("Prepare", .prepare, state.canPrepare),
            ("Check", .recheck, state.canRecheck), ("Retry", .retry, state.canRetry),
        ]
        VStack(alignment: .leading, spacing: 8) {
            Text(target == nil ? state.message + " Save your settings first." : state.message)
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let bytes = state.bytes, let total = state.total {
                ProgressView(value: Double(bytes), total: Double(total))
            }
            HStack(spacing: 8) {
                ForEach(actions.filter { $0.2 && target != nil }, id: \.0) { title, action, _ in
                    Button(title) { if let target { model.parakeetAction(action, target: target) } }
                        .buttonStyle(HubButtonStyle())
                }
                if state.canCancel {
                    Button("Cancel") { model.onParakeetCancel(state.token) }.buttonStyle(HubButtonStyle())
                }
                Spacer(minLength: 0)
                if state.canDelete, let target {
                    Button("Delete") { model.parakeetAction(.delete, target: target) }
                        .buttonStyle(HubButtonStyle(kind: .danger))
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Fixed public domain only. Unknown saved strings stay visible until explicitly edited.
struct ParakeetSettingsFields: View {
    @Binding var modelID: String?
    @Binding var filter: String?
    var inherits = false
    var body: some View {
        HubRow("Parakeet model") {
            Picker("Parakeet model", selection: $modelID) {
                if inherits { Text("Same as global").tag(Optional<String>.none) }
                Text(ParakeetWire.model).tag(Optional(ParakeetWire.model))
                if let modelID, modelID != ParakeetWire.model { Text("Unknown model").tag(Optional(modelID)) }
            }
            .hubControl()
        }
        HubDivider()
        HubRow("Languages") {
            Picker("Languages", selection: $filter) {
                Text(inherits ? "Same as global" : "All languages").tag(Optional<String>.none)
                if inherits { Text("All languages").tag(Optional("none")) }
                ForEach(ParakeetWire.filters.sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                if let filter, !ParakeetWire.filters.contains(filter), !(inherits && filter == "none") {
                    Text("Unknown filter").tag(Optional(filter))
                }
            }
            .hubControl()
        }
    }
}

struct ParakeetGlobalControls: View {
    @ObservedObject var model: HubModel
    var body: some View {
        ParakeetSettingsFields(modelID: Binding(get: { model.settings.parakeetModelID },
            set: { if let value = $0 { model.settings.parakeetModelID = value } }), filter: $model.settings.parakeetLanguageFilter)
        HubDivider()
        ParakeetControls(model: model).hubInset()
    }
}
