import Combine
import Foundation
import ParlaCore

extension HubModel {
    /// Narrow adoption preserves unrelated drafts, their base and owed debounce/callbacks.
    func adoptTemplates(_ document: GuidedTemplateDocument) {
        let wasLoading = loading; loading = true
        settings.guidedTemplates = document; settingsBase.guidedTemplates = document
        templateDocument = document
        loading = wasLoading
        if let selectedTemplateID, !document.definitions.contains(where: { $0.id == selectedTemplateID }) { self.selectedTemplateID = nil }
    }
    func refreshTemplates() {
        do {
            let saved = try store.savedRetrySnapshot()
            templates.observeSaved(); adoptTemplates(saved.guidedTemplates)
            templateMessage = nil
        } catch { templates.cancel("Settings can't be read."); templateMessage = "Fix settings.json to use templates." }
    }
    func templateDraftReady() -> Bool { !hasPendingSettingsSave && loadError == nil && saveError == nil }
    func selectTemplate(_ id: UUID?) { templates.cancel(); selectedTemplateID = id; templateEditor = nil }
    func editTemplate(_ id: UUID?) {
        templates.cancel("Form canceled.")
        guard !templates.ownsSession else { templateMessage = "Wait for the current form to stop."; return }
        refreshTemplates()
        if let id, let definition = templateDocument.definitions.first(where: { $0.id == id }) {
            templateEditor = definition; templateEditorBase = definition.revision
        } else if id == nil {
            templateEditor = GuidedTemplateDefinition(name: "", body: "", fields: [GuidedTemplateField(key: "", label: "")])
            templateEditorBase = nil
        }
    }
    func cancelTemplateEditor() { templateEditor = nil; templateEditorBase = nil; templateMessage = nil }
    func saveTemplateDefinition() {
        guard let definition = templateEditor else { return }
        do {
            let committed = try store.saveTemplateDefinition(definition, expectedRevision: templateEditorBase)
            adoptTemplates(committed); selectedTemplateID = definition.id
            cancelTemplateEditor()
        } catch { templateMessage = error.localizedDescription }
    }
    func deleteTemplateDefinition(_ definition: GuidedTemplateDefinition) {
        templates.cancel("Form canceled.")
        do { adoptTemplates(try store.deleteTemplateDefinition(definition.id, expectedRevision: definition.revision)) }
        catch { templateMessage = error.localizedDescription }
    }
    func beginTemplate() {
        guard templateDraftReady() else { templates.notice("Wait for your settings to save, then try again."); return }
        refreshTemplates()
        guard templateEditor == nil, let selectedTemplateID,
              let definition = templateDocument.definitions.first(where: { $0.id == selectedTemplateID }) else { return }
        templates.begin(definition)
    }
    func copyTemplate() { templates.copy(using: copy) }
    func saveCompletedTemplate() { templates.save(history: history) }
    func leaveTemplates() { templates.cancel(); cancelTemplateEditor(); templatesPageActive = false }
}
