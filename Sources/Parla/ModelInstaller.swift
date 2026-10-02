import AppKit
import ParlaCore

/// Model download + install. Progress lands in the Hub and the status menu —
/// never on the menu-bar item itself, which belongs to the dictation state.
/// The install (verify + move) is ModelCatalog's.
extension AppDelegate {

    /// Menu action: fetch the catalog default. The Hub picker calls
    /// `download(_:)` directly for any other model.
    @objc func downloadModel() { download(ModelCatalog.default) }

    /// menuNeedsUpdate and the Hub hide their download actions while one is
    /// running; the guard is what actually stops a duplicate.
    func download(_ model: ModelCatalog.Model) {
        guard downloadTask == nil else { return }
        let dest = URL(fileURLWithPath: ModelCatalog.path(for: model))
        let task = URLSession.shared.downloadTask(with: model.url) { [weak self] tmp, response, error in
            // The tmp file is deleted the moment this handler returns — verify
            // and move it NOW, before hopping to main for the UI. URLSession's
            // temp file IS vibe PR #1245's `.part` staging; re-staging it into
            // one of our own would cost another 574 MB of I/O for nothing.
            let failure: Error?
            if let error {
                failure = error
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // An error status still "succeeds", with the error page as its
                // file. Left to verify(), a passing 503 reads as a bad model
                // and tells the user not to bother retrying.
                failure = URLError(.badServerResponse,
                                   userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
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
            // Whole percents only: this fires ~25 times a second, and every
            // publish re-renders the whole Hub.
            let fraction = (progress.fractionCompleted * 100).rounded(.down) / 100
            DispatchQueue.main.async {
                guard let hub = self?.hubModel, hub.downloadProgress != fraction else { return }
                hub.downloadProgress = fraction
            }
        }
        downloadTask = task
        hubModel.downloadError = nil
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
            let message = error is ModelFileError ? "Model failed verification" : "Model download failed"
            hubModel.downloadError = message
            // Not over a live recording: the toast replaces the pill and then
            // hides it, leaving a capture running with nothing on screen. The
            // Hub's banner carries the failure instead.
            if !session.isCapturing { hud.show(.error(message)) }
            showIdle()
            return
        }
        // Switch to what the user just waited for. Written through the store
        // rather than hubModel.settings: hubModel's copy is default-constructed
        // until the window is first opened, so writing it would save those
        // defaults over the user's real settings.json. A Hub edit still inside
        // its debounce goes to disk first — flushed later, it would land on top
        // of the new path and switch straight back.
        hubModel.flushPendingSave()
        var s = store.load()
        let path = ModelCatalog.path(for: model)
        // An unreadable settings.json loads as defaults: never save those over
        // a file the user is hand-fixing (same rule as the menu's mic picker).
        if store.lastError == nil, s.whisperModelPath != path {
            s.whisperModelPath = path
            if (try? store.save(s)) != nil { hubModel.adoptModelPath(path) }
        }
        loadModel() // clears the ⚠️ when it succeeds (showIdle() inside)
    }
}
