import SwiftUI
import ParlaCore

struct HubTransformsView: View {
    @ObservedObject var model: HubModel
    @State private var draft: TransformPreset?
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubSection("Dictation output", footer: "Frozen when capture starts. App/site output profiles still decide cleanup permission, provider model and vocabulary at landing. Provider credentials stay global.") {
                Picker("Output", selection: $model.settings.outputMode) {
                    Text("Normal cleanup").tag(DictationOutputMode.cleanup)
                    Text("Raw ASR — no rewrites").tag(DictationOutputMode.raw)
                    Text("Selected preset").tag(DictationOutputMode.selectedPreset)
                }.padding(12)
                Text("Raw ASR bypasses AI, snippets and replacements. Cleanup off keeps local rules in Normal cleanup, and refuses intentional transforms.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(12)
            }
            HubSection("Selected preset", footer: "The optional Run selected preset shortcut captures text in the destination app. It needs no recording or speech model. Shift + push to talk still accepts a spoken instruction. Set or clear the shortcut in General.") {
                Picker("Preset", selection: Binding(get: { model.settings.selectedPresetID }, set: { model.selectPreset($0) })) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(model.settings.transformPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                    if let id = model.settings.selectedPresetID,
                       !model.settings.transformPresets.contains(where: { $0.id == id }) {
                        Text("Missing preset — choose explicitly").tag(Optional(id))
                    }
                }.padding(12)
                if let error = model.selectedPresetError { HubBanner(text: error).padding(12) }
            }
            HubSection("Saved intentional transforms", footer: "No presets are installed by default. Source text is data; only your saved instruction or translation target expresses intent. Results never run through snippets or replacements.") {
                ForEach(model.settings.transformPresets) { preset in
                    HubRow(preset.name, detail: preset.kind == .translation ? "Translate into \(preset.targetLanguage)" : preset.instruction) {
                        Button("Edit") { editing = true; draft = preset; model.presetError = nil }
                        Button { model.deletePreset(preset.id) } label: { Image(systemName: "trash") }
                    }
                    HubDivider()
                }
                if model.settings.transformPresets.isEmpty { EmptyHint(text: "No saved presets") }
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
            Picker("Intent", selection: $preset.kind) {
                Text("Rewrite instruction").tag(TransformPreset.Kind.rewrite)
                Text("Translate into a target language").tag(TransformPreset.Kind.translation)
            }
            if preset.kind == .translation {
                TextField("Target language, e.g. Hindi", text: $preset.targetLanguage).hubField()
            } else {
                Text("Instruction, e.g. Make this more concise").font(.caption).foregroundStyle(Theme.muted)
                TextEditor(text: $preset.instruction).font(.system(size: 13)).frame(height: 140)
                Toggle("I confirm this saved rewrite preserves the source language for local cleanup", isOn: Binding(get: { preset.localPreserveSourceLanguage == true }, set: { preset.localPreserveSourceLanguage = $0 }))
                Text("Apple Intelligence refuses translations, unconstrained spoken commands and unconfirmed rewrites. This declaration does not prove text language; every request is checked.").font(.caption).foregroundStyle(Theme.muted)
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
