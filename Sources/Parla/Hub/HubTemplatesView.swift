import SwiftUI
import ParlaCore

/// Local controls only: no spoken commands, global hooks or automatic next take.
struct HubTemplatesView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: GuidedTemplateOwner
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved global recognition · raw only. Profiles, cleanup, presets, replacements and snippets do not apply. Only definitions persist unless you explicitly save the completed document to History.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.templateMessage { Text(message).foregroundStyle(.red) }
            if let message = owner.message { Text(message).textSelection(.enabled) }
            if owner.ownsSession { sessionView }
            else if model.templateEditor != nil { editor }
            else {
                if model.templateDocument.definitions.isEmpty { Text("Create a definition with named fields to begin. No templates are installed by default.") }
                ForEach(model.templateDocument.definitions) { definition in
                    HStack {
                        Button(definition.name) { model.selectTemplate(definition.id) }
                        if model.selectedTemplateID == definition.id { Image(systemName: "checkmark") }
                        Spacer()
                        Button("Edit") { model.editTemplate(definition.id) }
                        Button("Delete") { model.deleteTemplateDefinition(definition) }
                    }
                }
                HStack {
                    Button("New definition") { model.editTemplate(nil) }
                    Button("Begin form") { model.beginTemplate() }.disabled(model.selectedTemplateID == nil)
                    Button("Refresh definitions") { model.refreshTemplates() }
                }
                Button("Allow Microphone") { model.requestMicrophone() }
            }
        }
        .onExitCommand { if model.templateEditor != nil { model.cancelTemplateEditor() } else { owner.cancel() } }
    }
    @ViewBuilder private var sessionView: some View {
        if let state = owner.session {
            Text(state.definition.name).font(.headline)
            if let recognition = owner.recognitionSummary { Text("Saved global: " + recognition + " · raw only").font(.caption) }
            Text("\(state.index + 1) of \(state.definition.fields.count): \(state.field.label) · \(state.field.required ? "Required" : "Optional")")
            if let completion = state.completion {
                Text("Approved completion").font(.headline)
                Text(completion.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Copy") { model.copyTemplate() }
                    Button(state.saved ? "Saved" : "Save completed result / Retry Save") { model.saveCompletedTemplate() }.disabled(state.saved)
                    Button("Done") { owner.cancel() }
                }
            } else if let preview = state.preview {
                Text("Review the full literal document").font(.headline)
                Text(preview.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Approve completion") { owner.approve(preview.id) }
                    Button("Back to fields") { owner.back() }
                    Button("Re-record this field") { owner.start() }
                }.disabled(owner.busy || owner.recording)
            } else {
                if let candidate = state.candidate {
                    TextEditor(text: Binding(get: { owner.session?.candidate ?? candidate }, set: owner.editCandidate))
                        .frame(minHeight: 130)
                    Button("Accept field") { owner.accept() }.disabled(owner.busy || owner.recording)
                }
                if let route = owner.route.name { Text("Input: \(route)\(owner.route.fallback == true ? " (system fallback)" : "")") }
                else { Text("Input route: unknown until capture") }
                HStack {
                    Button(owner.recording ? "Stop" : "Start recording / Re-record") { if owner.recording { owner.stop() } else { owner.start() } }
                        .disabled(owner.busy)
                    Button("Discard take") { owner.discardTake() }
                    Button("Back") { owner.back() }.disabled(owner.busy || owner.recording)
                    Button("Skip optional field") { owner.skip() }.disabled(state.field.required || owner.busy || owner.recording)
                }
                Button("Review completed form") { owner.review() }.disabled(!state.allAnswered || owner.busy || owner.recording)
            }
        } else { Text("Stopping. Waiting for actual recorder and recognition exit.") }
        Button("Cancel form") { owner.cancel() }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Definition name", text: draft(\.name))
            Text("Fields are recorded in this order. Keys use a–z, then a–z, 0–9 or _. Every key must appear in the body.").font(.caption)
            if let definition = model.templateEditor {
                ForEach(Array(definition.fields.enumerated()), id: \.element.id) { index, field in
                    HStack {
                        TextField("key", text: fieldBinding(index, \.key))
                        TextField("Label", text: fieldBinding(index, \.label))
                        Toggle("Required", isOn: fieldBinding(index, \.required))
                        Button("↑") { guard index > 0 else { return }; model.templateEditor?.fields.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Remove") { model.templateEditor?.fields.remove(at: index) }
                    }
                }
                Button("Add field") { model.templateEditor?.fields.append(GuidedTemplateField(key: "", label: "")) }.disabled(definition.fields.count >= 12)
            }
            Text("Use {{key}}. {{{{key}}}} prints literal {{key}} and does not reference a field. Single JSON braces stay literal. No backslash escape or expressions.").font(.caption)
            TextEditor(text: draft(\.body)).frame(minHeight: 180)
            HStack {
                Button("Save definition") { model.saveTemplateDefinition() }
                Button("Cancel editor") { model.cancelTemplateEditor() }
            }
        }
    }
    private func draft(_ key: WritableKeyPath<GuidedTemplateDefinition, String>) -> Binding<String> {
        Binding(get: { model.templateEditor?[keyPath: key] ?? "" }, set: { model.templateEditor?[keyPath: key] = $0 })
    }
    private func fieldBinding<Value>(_ index: Int, _ key: WritableKeyPath<GuidedTemplateField, Value>) -> Binding<Value> {
        Binding(get: { model.templateEditor!.fields[index][keyPath: key] }, set: { model.templateEditor?.fields[index][keyPath: key] = $0 })
    }
}
