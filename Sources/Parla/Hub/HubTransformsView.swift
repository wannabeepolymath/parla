import SwiftUI
import ParlaCore

struct HubTransformsView: View {
    @ObservedObject var model: HubModel
    @State private var draft: TransformPreset?
    @State private var editing = false

    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            HubSection("Highlighted text", footer: "Select text in any app and press the shortcut to rewrite it with the preset.") {
                HubRow("Preset") {
                    Picker("Preset for highlighted text", selection: Binding(get: { model.settings.selectedPresetID }, set: { model.selectPreset($0) })) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(model.settings.transformPresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                        if let id = model.settings.selectedPresetID,
                           !model.settings.transformPresets.contains(where: { $0.id == id }) {
                            Text("Missing preset — choose another").tag(Optional(id))
                        }
                    }
                    .hubControl()
                }
                HubDivider()
                HubRow("Shortcut") {
                    ShortcutRecorder(model: model, optionalPath: \.runSelectedPreset)
                }
            }
            if let error = model.selectedPresetError { HubBanner(text: error, kind: .warning) }

            // Every-dictation use is set by Dictation output in AI Cleanup; shown here, not duplicated.
            HubSection(nil) {
                HubRow("Every dictation", detail: model.settings.outputMode == .selectedPreset
                       ? "Rewritten with the preset above. Change this in AI Cleanup."
                       : "Not rewritten. To use a preset for every dictation, change Dictation output in AI Cleanup.") {
                    Button("Go to AI Cleanup") { model.requestedPage = .cleanup }.buttonStyle(HubButtonStyle())
                }
            }

            HubSection("Presets", footer: "Presets rewrite or translate text using your cleanup service. Click one to edit it.", accessory: {
                HubAddButton("Add Preset") { editing = false; draft = TransformPreset(); model.presetError = nil }
            }) {
                if model.settings.transformPresets.isEmpty {
                    EmptyHint(text: "No presets yet", detail: "A preset rewrites text, like “Make it friendlier”, or translates it.")
                }
                ForEach(model.settings.transformPresets) { preset in
                    if preset.id != model.settings.transformPresets.first?.id { HubDivider() }
                    let edit = { editing = true; draft = preset; model.presetError = nil }
                    HubRow(preset.name, detail: preset.kind == .translation ? "Translate into \(preset.targetLanguage)" : preset.instruction) {
                        HStack(spacing: 4) {
                            HubIconButton("trash", label: "Delete preset") { model.deletePreset(preset.id) }
                                .modifier(HoverReveal(hovering: hovered == preset.id))
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.muted).accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: edit)
                    .onHover { hovered = $0 ? preset.id : (hovered == preset.id ? nil : hovered) }
                    .contextMenu {
                        Button("Edit…", action: edit)
                        Divider()
                        Button("Delete", role: .destructive) { model.deletePreset(preset.id) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: "Edit", edit)
                }
            }
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
        HubSheet(title: editing ? "Edit Preset" : "New Preset") {
            HubSection(nil) {
                HubRow("Name") {
                    TextField("Name", text: $preset.name, prompt: Text("Make it friendlier")).hubField().hubControl(260)
                }
                HubDivider()
                HubRow("Type") {
                    Picker("Type", selection: $preset.kind) {
                        Text("Rewrite").tag(TransformPreset.Kind.rewrite)
                        Text("Translate").tag(TransformPreset.Kind.translation)
                    }
                    .pickerStyle(.segmented).hubControl(260)
                }
                HubDivider()
                if preset.kind == .translation {
                    HubRow("Translate into") {
                        TextField("Target language", text: $preset.targetLanguage, prompt: Text("Hindi")).hubField().hubControl(260)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instruction").font(.system(size: 13)).foregroundStyle(Theme.text)
                        TextEditor(text: $preset.instruction).hubEditor().frame(height: 120)
                    }
                    .hubInset()
                    HubDivider()
                    HubToggleRow("Keep the same language", detail: "Needed for Apple Intelligence",
                                 isOn: Binding(get: { preset.localPreserveSourceLanguage == true }, set: { preset.localPreserveSourceLanguage = $0 }))
                }
            }
            if let error = model.presetError { HubBanner(text: error) }
        } actions: {
            Button("Cancel") { dismiss() }.buttonStyle(HubButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Save Preset") {
                if model.savePreset(preset, replacing: editing ? preset.id : nil) { dismiss() }
            }
            .buttonStyle(HubButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        }
    }
}
