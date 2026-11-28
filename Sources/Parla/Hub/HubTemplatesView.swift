import SwiftUI
import ParlaCore

/// Local controls only: no spoken commands, global hooks or automatic next take.
struct HubTemplatesView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var owner: GuidedTemplateOwner
    @State private var hoveredTemplate: UUID?
    @State private var showKeys = false
    @State private var hoveredField: UUID?

    private var selected: GuidedTemplateDefinition? {
        model.templateDocument.definitions.first { $0.id == model.selectedTemplateID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            if let message = model.templateMessage { HubBanner(text: message) }
            if owner.ownsSession { sessionView }
            else if model.templateEditor != nil { editor }
            else { list }
            if let message = owner.message { HubNote(message) }
        }
        .onExitCommand { if model.templateEditor != nil { model.cancelTemplateEditor() } else { owner.cancel() } }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        if !model.micGranted {
            HubBanner(text: "Voice Templates need microphone access.", kind: .warning, actionTitle: "Allow…") { model.requestMicrophone() }
        }
        HubSection("Templates",
                   footer: "Select a template and click Start. Templates use your original words, without cleanup or snippets.",
                   accessory: { HubAddButton("Add Template") { model.editTemplate(nil) } }) {
            if model.templateDocument.definitions.isEmpty {
                EmptyHint(text: "No templates yet", detail: "A template asks for each field in turn, then fills in your text.")
            }
            ForEach(model.templateDocument.definitions) { definition in
                if definition.id != model.templateDocument.definitions.first?.id { HubDivider() }
                templateRow(definition)
            }
        }
    }

    private func templateRow(_ definition: GuidedTemplateDefinition) -> some View {
        let isSelected = model.selectedTemplateID == definition.id
        let edit = { model.editTemplate(definition.id) }
        let delete = { model.deleteTemplateDefinition(definition) }
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
                .accessibilityHidden(true)
            HubRow(definition.name, detail: "\(definition.fields.count) field\(definition.fields.count == 1 ? "" : "s")") {
                HStack(spacing: 6) {
                    HubMoreMenu(label: "More actions for \(definition.name)") {
                        Button("Edit…", action: edit)
                        Divider()
                        Button("Delete", role: .destructive, action: delete)
                    }
                    .modifier(HoverReveal(hovering: hoveredTemplate == definition.id || isSelected))
                    if isSelected {
                        Button("Start") { model.beginTemplate() }.buttonStyle(HubButtonStyle(kind: .primary))
                    }
                }
            }
            .padding(.leading, -HubLayout.rowInset)
        }
        .padding(.leading, HubLayout.rowInset)
        .background(isSelected ? Theme.accentFill.opacity(0.35) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .onTapGesture { model.selectTemplate(definition.id) }
        .onHover { hoveredTemplate = $0 ? definition.id : (hoveredTemplate == definition.id ? nil : hoveredTemplate) }
        .contextMenu {
            Button("Start") { model.selectTemplate(definition.id); model.beginTemplate() }
            Button("Edit…", action: edit)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { model.selectTemplate(definition.id) }
    }

    // MARK: Session

    @ViewBuilder private var sessionView: some View {
        if let state = owner.session {
            let title = state.completion != nil ? "Finished" : state.preview != nil ? "Review"
                : "\(state.index + 1) of \(state.definition.fields.count): \(state.field.label)"
            HubSection(state.definition.name, footer: owner.recognitionSummary) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        if state.completion == nil, state.preview == nil {
                            Text(state.field.required ? "Required" : "Optional")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if state.completion == nil, state.preview == nil, let route = owner.route.name {
                            Label(route + (owner.route.fallback == true ? " (system default)" : ""), systemImage: "mic")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    if let completion = state.completion {
                        bodyText(completion.body)
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Copy") { model.copyTemplate() }.buttonStyle(HubButtonStyle())
                            Button(state.saved ? "Saved" : "Save to History") { model.saveCompletedTemplate() }
                                .buttonStyle(HubButtonStyle()).disabled(state.saved)
                            Button("Done") { owner.cancel() }.buttonStyle(HubButtonStyle(kind: .primary))
                        }
                    } else if let preview = state.preview {
                        bodyText(preview.body)
                        HStack(spacing: 8) {
                            Button("Back to Fields") { owner.back() }.buttonStyle(HubButtonStyle())
                            Spacer()
                            Button("Re-record Field") { owner.start() }.buttonStyle(HubButtonStyle())
                            Button("Finish") { owner.approve(preview.id) }.buttonStyle(HubButtonStyle(kind: .primary))
                        }
                        .disabled(owner.busy || owner.recording)
                    } else {
                        if let candidate = state.candidate {
                            TextEditor(text: Binding(get: { owner.session?.candidate ?? candidate }, set: owner.editCandidate))
                                .hubEditor().frame(minHeight: 110)
                        } else {
                            Text(owner.recording ? "Listening… click Stop when you’re done." : "Click Record and say the \(state.field.label.lowercased()).")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            Button("Back") { owner.back() }.buttonStyle(HubButtonStyle()).disabled(owner.busy || owner.recording)
                            Button("Skip") { owner.skip() }.buttonStyle(HubButtonStyle())
                                .disabled(state.field.required || owner.busy || owner.recording)
                            Spacer()
                            if state.candidate != nil {
                                Button("Discard") { owner.discardTake() }.buttonStyle(HubButtonStyle())
                            }
                            Button(owner.recording ? "Stop" : (state.candidate == nil ? "Record" : "Re-record")) {
                                if owner.recording { owner.stop() } else { owner.start() }
                            }
                            .buttonStyle(HubButtonStyle(kind: state.candidate == nil ? .primary : .normal))
                            .disabled(owner.busy)
                            if state.candidate != nil {
                                Button("Accept Field") { owner.accept() }
                                    .buttonStyle(HubButtonStyle(kind: .primary))
                                    .disabled(owner.busy || owner.recording)
                            }
                        }
                    }
                }
                .hubInset()
            }
            if state.completion == nil, state.preview == nil {
                HStack {
                    Button("Cancel Form") { owner.cancel() }.buttonStyle(HubButtonStyle())
                    Spacer()
                    Button("Review…") { owner.review() }.buttonStyle(HubButtonStyle())
                        .disabled(!state.allAnswered || owner.busy || owner.recording)
                }
            }
        } else {
            HubSection(nil) {
                EmptyHint(text: "Stopping…")
            }
            Button("Cancel Form") { owner.cancel() }.buttonStyle(HubButtonStyle())
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
            HubSection(model.templateEditorBase == nil ? "New template" : "Edit template") {
                HubRow("Name") {
                    TextField("Template name", text: draft(\.name), prompt: Text("Bug report")).hubField().hubControl(260)
                }
            }
            if let definition = model.templateEditor {
                HubSection("Fields", caption: "Parla asks for each field in this order. Drag to reorder.", accessory: {
                    HubAddButton("Add Field") { model.templateEditor?.fields.append(GuidedTemplateField(key: "", label: "")) }
                        .disabled(definition.fields.count >= 12)
                }) {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 16, height: 1)
                        if showKeys { columnHeader("Marker").frame(width: 130, alignment: .leading) }
                        columnHeader("Question Parla asks").frame(maxWidth: .infinity, alignment: .leading)
                        columnHeader("Required").frame(width: 60)
                    }
                    .padding(.horizontal, HubLayout.rowInset).padding(.top, 10).padding(.bottom, 6)
                    if definition.fields.isEmpty {
                        HubDivider()
                        EmptyHint(text: "No fields yet")
                    }
                    ForEach(Array(definition.fields.enumerated()), id: \.element.id) { index, field in
                        HubDivider()
                        fieldRow(index, field, count: definition.fields.count)
                    }
                }
                HubSection("Output", caption: "Answers replace markers such as {{title}}. Use Insert Field to add one.", accessory: {
                    HStack(spacing: 8) {
                    Toggle("Show markers", isOn: $showKeys).toggleStyle(.checkbox).font(.system(size: 12))
                        .help("Show each field’s marker name in the list above")
                    Menu("Insert Field") {
                        ForEach(definition.fields.filter { !$0.key.isEmpty }) { field in
                            Button(field.label.isEmpty ? field.key : field.label) {
                                model.templateEditor?.body += "{{\(field.key)}}"
                            }
                        }
                    }
                    .menuStyle(.borderedButton).fixedSize()
                    .disabled(definition.fields.allSatisfy { $0.key.isEmpty })
                    }
                }) {
                    TextEditor(text: draft(\.body)).hubEditor().frame(minHeight: 160).hubInset()
                }
            }
        }
    }

    /// Same list editing as Dictionary: drag handle, hover delete, Move Up/Down in the context menu.
    private func fieldRow(_ index: Int, _ field: GuidedTemplateField, count: Int) -> some View {
        let id = field.id
        let move = { (offset: Int) in
            guard var editor = model.templateEditor, editor.fields.indices.contains(index + offset) else { return }
            editor.fields.swapAt(index, index + offset); model.templateEditor = editor
        }
        let remove: () -> Void = { model.templateEditor?.fields.removeAll { $0.id == id } }
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                .frame(width: 16, height: 24).contentShape(Rectangle())
                .draggable(id.uuidString).help("Drag to reorder").accessibilityHidden(true)
            if showKeys {
                TextField("Marker", text: fieldBinding(index, \.key), prompt: Text("title"))
                    .hubField().labelsHidden().font(.system(size: 13, design: .monospaced)).frame(width: 130)
            }
            TextField("Question", text: labelBinding(index), prompt: Text("Title"))
                .hubField().labelsHidden()
                .overlay(alignment: .trailing) {
                    HubIconButton("trash", label: "Remove field", action: remove)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field))
                        .modifier(HoverReveal(hovering: hoveredField == id))
                }
            Toggle("Required", isOn: fieldBinding(index, \.required)).labelsHidden().frame(width: 60)
        }
        .padding(.horizontal, HubLayout.rowInset).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hoveredField = $0 ? id : (hoveredField == id ? nil : hoveredField) }
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first.flatMap(UUID.init(uuidString:)), var editor = model.templateEditor,
                  let from = editor.fields.firstIndex(where: { $0.id == source }),
                  let to = editor.fields.firstIndex(where: { $0.id == id }), from != to else { return false }
            editor.fields.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            model.templateEditor = editor; return true
        }
        .contextMenu {
            Button("Move Up") { move(-1) }.disabled(index == 0)
            Button("Move Down") { move(1) }.disabled(index + 1 == count)
            Divider()
            Button("Remove Field", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move up") { move(-1) }
        .accessibilityAction(named: "Move down") { move(1) }
    }

    /// Editing a question keeps its key in step while the key still matches the
    /// old question, and renames that key's placeholders in the text with it.
    private func labelBinding(_ index: Int) -> Binding<String> {
        Binding(get: { model.templateEditor?.fields[index].label ?? "" }, set: { label in
            guard let editor = model.templateEditor else { return }
            model.templateEditor = Self.renamingField(editor, at: index, to: label)
        })
    }

    /// A question that's cleared (or has no letters yet) keeps its last key, so the
    /// rename resumes once a new question is typed and `{{}}` never appears.
    static func renamingField(_ editor: GuidedTemplateDefinition, at index: Int, to label: String) -> GuidedTemplateDefinition {
        guard editor.fields.indices.contains(index) else { return editor }
        var editor = editor
        let field = editor.fields[index]
        let others = Set(editor.fields.enumerated().filter { $0.offset != index }.map(\.element.key))
        let previous = derivedKey(field.label, avoiding: others)
        let inStep = field.key.isEmpty || previous.isEmpty || field.key == previous
        let key = derivedKey(label, avoiding: others)
        if inStep, !key.isEmpty, key != field.key {
            if !field.key.isEmpty {
                editor.body = editor.body.replacingOccurrences(of: "{{\(field.key)}}", with: "{{\(key)}}")
            }
            editor.fields[index].key = key
        }
        editor.fields[index].label = label
        return editor
    }

    /// "Steps to reproduce" → "steps_to_reproduce": lowercase letters, digits and _,
    /// starting with a letter, at most 32 characters, unique among the other fields.
    static func derivedKey(_ label: String, avoiding taken: Set<String>) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var key = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { key.unicodeScalars.append(scalar) }
            else if !key.isEmpty, !key.hasSuffix("_") { key += "_" }
        }
        while key.hasSuffix("_") { key.removeLast() }
        if key.isEmpty { return "" }
        if !(key.first.map { ("a"..."z").contains($0) } ?? false) { key = "field_" + key }
        key = String(key.prefix(28))
        var candidate = key, n = 2
        while taken.contains(candidate) { candidate = "\(key)_\(n)"; n += 1 }
        return candidate
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
    }

    private func draft(_ key: WritableKeyPath<GuidedTemplateDefinition, String>) -> Binding<String> {
        Binding(get: { model.templateEditor?[keyPath: key] ?? "" }, set: { model.templateEditor?[keyPath: key] = $0 })
    }
    private func fieldBinding<Value>(_ index: Int, _ key: WritableKeyPath<GuidedTemplateField, Value>) -> Binding<Value> {
        Binding(get: { model.templateEditor!.fields[index][keyPath: key] }, set: { model.templateEditor?.fields[index][keyPath: key] = $0 })
    }
}

/// Pinned under the scrolling editor so Save and Cancel never leave the window.
struct TemplateEditorBar: View {
    @ObservedObject var model: HubModel
    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { model.cancelTemplateEditor() }
                .buttonStyle(HubButtonStyle())
            Button("Save Template") { model.saveTemplateDefinition() }
                .buttonStyle(HubButtonStyle(kind: .primary)).keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, HubLayout.pageInset)
        .frame(maxWidth: HubLayout.columnWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
