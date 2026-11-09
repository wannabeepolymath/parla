import AppKit
import ParlaCore

extension HubModel {
    /// This is the production completion path, also used with isolated stores
    /// in tests. Capture only a model-selection intent, never a settings copy.
    @MainActor func bindCatalogDownloads(_ owner: CatalogDownloadOwner, setup: @escaping () -> Void) {
        onCatalogDownloadAction = { [weak owner] action, model in owner?.act(action, model: model) }
        onDownloadModel = { [weak owner] model in owner?.act(.download, model: model) }
        owner.selectionIntent = { [weak self] model in
            guard let self else { return {} }
            let epoch = self.modelSelectionEpoch
            let original = self.store.load().whisperModelPath
            // A draft selected before this fresh action may reach disk via
            // debounce while downloading. It is part of the captured intent;
            // any later model selection still revokes the epoch immediately.
            let draft = self.hasPendingSettingsSave ? self.settings.whisperModelPath : original
            let valid = self.store.lastError == nil && self.loadError == nil
            return { [weak self] in
                guard let self, valid, self.modelSelectionEpoch == epoch else { return }
                // Inspect the authoritative file before flushing drafts: a new
                // disk choice must not be overwritten by an older Hub copy.
                let before = self.store.load()
                guard self.store.lastError == nil,
                      before.whisperModelPath == original || before.whisperModelPath == draft else { return }
                let expected = self.hasPendingSettingsSave ? self.settings.whisperModelPath : before.whisperModelPath
                self.flushPendingSave()
                guard self.modelSelectionEpoch == epoch, self.loadError == nil, self.saveError == nil else { return }
                var current = self.store.load()
                guard self.store.lastError == nil, current.whisperModelPath == expected else { return }
                let path = ModelCatalog.path(for: model)
                current.whisperModelPath = path
                do {
                    try self.store.save(current)
                    self.adoptModelPath(path)
                    setup()
                } catch { self.downloadError = "Model downloaded, but couldn't be selected. Click Use." }
            }
        }
        catalogDownloadObserver = owner.$rows.sink { [weak self, weak owner] rows in
            guard let self else { return }
            self.catalogDownloads = rows
            self.downloadingModel = owner?.catalog.first { rows[$0.id]?.active == true }
            self.downloadProgress = self.downloadingModel.flatMap { rows[$0.id].map { Double($0.percent) / 100 } }
        }
        owner.onStart = { [weak self] in self?.downloadError = nil }
        owner.onFailure = { [weak self] in self?.downloadError = "Download failed. Retry or discard it." }
    }
}

extension AppDelegate {
    @objc func downloadModel() { download(ModelCatalog.default) }
    func download(_ model: ModelCatalog.Model) {
        _ = hubModel // install the actual settings/setup binding before action
        MainActor.assumeIsolated { catalogDownloads.act(.download, model: model) }
    }
    @objc func catalogDownloadMenuAction(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? CatalogDownloadMenuRoute else { return }
        MainActor.assumeIsolated { route.perform(on: hubModel) }
    }
}

/// Menu rows carry the same scalar route the Hub uses; never an implicit
/// "whatever is active now" pause/discard target.
final class CatalogDownloadMenuRoute {
    let action: CatalogDownloadAction
    let model: ModelCatalog.Model
    init(_ action: CatalogDownloadAction, _ model: ModelCatalog.Model) { self.action = action; self.model = model }
    @MainActor func perform(on hub: HubModel) { hub.onCatalogDownloadAction(action, model) }
}
