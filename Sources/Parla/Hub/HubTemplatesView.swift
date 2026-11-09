import SwiftUI
import ParlaCore

/// Local controls only: no spoken commands, global hooks or automatic next take.
struct HubTemplatesView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: GuidedTemplateOwner
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uses your original words, without cleanup or snippets.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.templateMessage { Text(message).foregroundStyle(.red) }
            if let message = owner.message { Text(message).textSelection(.enabled) }
            if owner.ownsSession { sessionView }
            else if model.templateEditor != nil { editor }
            else {
                if model.templateDocument.definitions.isEmpty { Text("Create a template to get started.") }
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
                    Button("New template") { model.editTemplate(nil) }
                    Button("Start") { model.beginTemplate() }.disabled(model.selectedTemplateID == nil)
                    Button("Refresh") { model.refreshTemplates() }
                }
                Button("Allow microphone") { model.requestMicrophone() }
            }
        }
        .onExitCommand { if model.templateEditor != nil { model.cancelTemplateEditor() } else { owner.cancel() } }
    }
    @ViewBuilder private var sessionView: some View {
        if let state = owner.session {
            Text(state.definition.name).font(.headline)
            if let recognition = owner.recognitionSummary { Text(recognition).font(.caption) }
            Text("\(state.index + 1) of \(state.definition.fields.count): \(state.field.label) · \(state.field.required ? "Required" : "Optional")")
            if let completion = state.completion {
                Text("Finished").font(.headline)
                Text(completion.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Copy") { model.copyTemplate() }
                    Button(state.saved ? "Saved" : "Save to history") { model.saveCompletedTemplate() }.disabled(state.saved)
                    Button("Done") { owner.cancel() }
                }
            } else if let preview = state.preview {
                Text("Review").font(.headline)
                Text(preview.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Finish") { owner.approve(preview.id) }
                    Button("Back to fields") { owner.back() }
                    Button("Re-record field") { owner.start() }
                }.disabled(owner.busy || owner.recording)
            } else {
                if let candidate = state.candidate {
                    TextEditor(text: Binding(get: { owner.session?.candidate ?? candidate }, set: owner.editCandidate))
                        .frame(minHeight: 130)
                    Button("Accept field") { owner.accept() }.disabled(owner.busy || owner.recording)
                }
                if let route = owner.route.name { Text("Microphone: \(route)\(owner.route.fallback == true ? " (system default)" : "")") }
                HStack {
                    Button(owner.recording ? "Stop" : (state.candidate == nil ? "Record" : "Re-record")) { if owner.recording { owner.stop() } else { owner.start() } }
                        .disabled(owner.busy)
                    Button("Discard") { owner.discardTake() }
                    Button("Back") { owner.back() }.disabled(owner.busy || owner.recording)
                    Button("Skip") { owner.skip() }.disabled(state.field.required || owner.busy || owner.recording)
                }
                Button("Review") { owner.review() }.disabled(!state.allAnswered || owner.busy || owner.recording)
            }
        } else { Text("Stopping…") }
        Button("Cancel form") { owner.cancel() }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Template name", text: draft(\.name))
            Text("You'll fill in fields in this order. Keys use lowercase letters, digits or _.").font(.caption)
            if let definition = model.templateEditor {
                ForEach(Array(definition.fields.enumerated()), id: \.element.id) { index, field in
                    HStack {
                        TextField("Key", text: fieldBinding(index, \.key))
                        TextField("Label", text: fieldBinding(index, \.label))
                        Toggle("Required", isOn: fieldBinding(index, \.required))
                        Button("↑") { guard index > 0 else { return }; model.templateEditor?.fields.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Remove") { model.templateEditor?.fields.remove(at: index) }
                    }
                }
                Button("Add field") { model.templateEditor?.fields.append(GuidedTemplateField(key: "", label: "")) }.disabled(definition.fields.count >= 12)
            }
            Text("Write the text below. Put {{key}} where each field goes.").font(.caption)
            TextEditor(text: draft(\.body)).frame(minHeight: 180)
            HStack {
                Button("Save template") { model.saveTemplateDefinition() }
                Button("Cancel") { model.cancelTemplateEditor() }
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
