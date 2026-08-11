import AppKit
import ParlaCore

/// Model download + install. Progress lands in the menu bar and the Hub; the
/// install itself (verify + move) is ModelCatalog's.
extension AppDelegate {

    /// Menu action: fetch the catalog default. The Hub picker calls
    /// `download(_:)` directly for any other model.
    @objc func downloadModel() { download(ModelCatalog.default) }

    /// menuNeedsUpdate hides the action while downloadTask is non-nil so a
    /// second click can't start a duplicate.
    func download(_ model: ModelCatalog.Model) {
        guard downloadTask == nil else { return }
        setStatus("⬇️ 0%")
        let dest = URL(fileURLWithPath: ModelCatalog.path(for: model))
        let task = URLSession.shared.downloadTask(with: model.url) { [weak self] tmp, _, error in
            // The tmp file is deleted the moment this handler returns — verify
            // and move it NOW, before hopping to main for the UI. URLSession's
            // temp file IS vibe PR #1245's `.part` staging; re-staging it into
            // one of our own would cost another 574 MB of I/O for nothing.
            let failure: Error?
            if let error {
                failure = error
            } else if let tmp {
                do { try ModelCatalog.install(staged: tmp, as: model, at: dest); failure = nil }
                catch { failure = error }
            } else {
                failure = ModelFileError(description: "no file")
            }
            DispatchQueue.main.async { self?.finishDownload(model: model, error: failure) }
        }
        // KVO on the task's own Progress — least code for a live percentage,
        // no delegate class needed.
        downloadObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.setStatus("⬇️ \(Int(progress.fractionCompleted * 100))%")
                self?.hubModel.downloadProgress = progress.fractionCompleted
            }
        }
        downloadTask = task
        hubModel.downloadProgress = 0
        hubModel.downloadingModel = model
        task.resume()
    }

    private func finishDownload(model: ModelCatalog.Model, error: Error?) {
        downloadObservation = nil
        downloadTask = nil
        hubModel.downloadProgress = nil
        hubModel.downloadingModel = nil
        if let error {
            NSLog("%@", "Parla model download failed: \(error)")
            // A verification failure is not a network failure: the file arrived
            // and was wrong (proxy error page, truncation, re-upload). Saying so
            // stops the user retrying a download that will keep failing.
            hud.show(.error(error is ModelFileError
                            ? "Downloaded model failed verification" : "Model download failed"))
            showIdle()
            return
        }
        // Switch to what the user just waited for. Written through the store
        // rather than hubModel.settings: hubModel's copy is default-constructed
        // until the window is first opened, so writing it would save those
        // defaults over the user's real settings.json.
        var s = store.load()
        let path = ModelCatalog.path(for: model)
        if s.whisperModelPath != path {
            s.whisperModelPath = path
            try? store.save(s)
            hubModel.refresh()
        }
        loadModel() // clears the ⚠️ when it succeeds (showIdle() inside)
    }
}
