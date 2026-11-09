import SwiftUI
import ParlaCore

struct HubTransformsView: View {
    @ObservedObject var model: HubModel
    @State private var draft: TransformPreset?
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubSection("Dictation output") {
                Picker("Output", selection: $model.settings.outputMode) {
                    Text("Cleaned up").tag(DictationOutputMode.cleanup)
                    Text("Original text").tag(DictationOutputMode.raw)
                    Text("Selected preset").tag(DictationOutputMode.selectedPreset)
                }.padding(12)
                Text("Original text skips cleanup, snippets and replacements.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(12)
            }
            HubSection("Selected preset", footer: "To apply it to highlighted text, set the Run selected preset shortcut in General.") {
                Picker("Preset", selection: Binding(get: { model.settings.selectedPresetID }, set: { model.selectPreset($0) })) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(model.settings.transformPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                    if let id = model.settings.selectedPresetID,
                       !model.settings.transformPresets.contains(where: { $0.id == id }) {
                        Text("Missing preset — choose another").tag(Optional(id))
                    }
                }.padding(12)
                if let error = model.selectedPresetError { HubBanner(text: error).padding(12) }
            }
            HubSection("Presets", footer: "Presets rewrite or translate text using your cleanup provider.") {
                ForEach(model.settings.transformPresets) { preset in
                    HubRow(preset.name, detail: preset.kind == .translation ? "Translate into \(preset.targetLanguage)" : preset.instruction) {
                        Button("Edit") { editing = true; draft = preset; model.presetError = nil }
                        Button { model.deletePreset(preset.id) } label: { Image(systemName: "trash") }
                    }
                    HubDivider()
                }
                if model.settings.transformPresets.isEmpty { EmptyHint(text: "No presets yet") }
            }
            Button("Add preset") { editing = false; draft = TransformPreset(); model.presetError = nil }
                .buttonStyle(HubButtonStyle())
            if let error = model.presetError { HubBanner(text: error) }
        }
        .sheet(item: $draft) { preset in PresetEditor(model: model, initial: preset, editing: editing) }
    }
}

private struct PresetEditor: View {
    @ObservedObject var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: TransformPreset
    let editing: Bool

    init(model: HubModel, initial: TransformPreset, editing: Bool) {
        self.model = model; _preset = State(initialValue: initial); self.editing = editing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing ? "Edit preset" : "Add preset").font(.title2)
            TextField("Name", text: $preset.name).hubField()
            Picker("Type", selection: $preset.kind) {
                Text("Rewrite").tag(TransformPreset.Kind.rewrite)
                Text("Translate").tag(TransformPreset.Kind.translation)
            }
            if preset.kind == .translation {
                TextField("Target language, e.g. Hindi", text: $preset.targetLanguage).hubField()
            } else {
                Text("Instruction, e.g. Make this more concise").font(.caption).foregroundStyle(Theme.muted)
                TextEditor(text: $preset.instruction).font(.system(size: 13)).frame(height: 140)
                Toggle("Keeps the same language (needed for Apple Intelligence)", isOn: Binding(get: { preset.localPreserveSourceLanguage == true }, set: { preset.localPreserveSourceLanguage = $0 }))
            }
            if let error = model.presetError { HubBanner(text: error) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save preset") {
                    if model.savePreset(preset, replacing: editing ? preset.id : nil) { dismiss() }
                }.buttonStyle(HubButtonStyle(kind: .primary))
            }
        }.padding(24).frame(width: 520).background(Theme.bg)
    }
}
