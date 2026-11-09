import Foundation
import ParlaCore

struct HistoryRetryPreview: Identifiable {
    var id: UUID { original.id }
    let operation: PendingOperation
    init(original: HistoryEntry, version: UUID, request: HistoryRetryRequest,
         operation: PendingOperation = PendingOperation(name: "History retry")) {
        self.original = original; self.version = version; self.request = request; self.operation = operation
    }
    var token: UUID { operation.id }
    let original: HistoryEntry
    let version: UUID
    let request: HistoryRetryRequest
    var completedSegments = 0
    var started = false
    var loading = false
    var proposed: String?
    var provenance: HistoryRetryProvenance?
    var error: String?
    var stale = false
    var saved = false
    var saveFailed = false

    var status: String {
        if stale { return "This dictation changed in History. You can copy the result but not save it." }
        if loading { return request.isSegmented ? "Cleaning up: \(completedSegments) of \(request.plannedSegments) sections…" : "Working…" }
        if saved { return "Saved. The original text is kept too." }
        if let error { return error }
        if proposed != nil {
            switch provenance?.configuration.executionKind ?? request.configuration.executionKind {
            case .deterministic: return "Result ready. Nothing was sent online."
            case .onDevice: return "Result ready from Apple Intelligence."
            case .network: return "Result ready."
            }
        }
        return "Check the settings below, then start."
    }
}

extension HubModel {
    /// Missing/corrupt current settings never authorize a fallback request/save.
    private func currentRetrySettings() -> Settings? {
        flushPendingSave()
        let current = store.load()
        if store.lastError != nil { loadError = store.lastError }
        guard loadError == nil, saveError == nil, store.lastError == nil else {
            historyRetryMessage = "Fix settings.json before starting or saving."
            return nil
        }
        return current
    }

    private func currentSegmentedRetrySettings() -> Settings? {
        // Latch invalidity before a pending flush can repair what was observed.
        do { _ = try store.savedRetrySnapshot() }
        catch {
            historyRetryMessage = "Fix settings.json first."
            return nil
        }
        // The normal save owns credential migration and application callbacks.
        // Leave its pending work intact and require an explicit review afterward.
        guard !hasPendingSettingsSave else {
            historyRetryMessage = "Wait for settings to save, then try again."
            return nil
        }
        do {
            let current = try store.savedRetrySnapshot()
            guard loadError == nil, saveError == nil else { throw SegmentedRetryFailure.configuration }
            return current
        } catch {
            historyRetryMessage = "Settings can’t be read. Fix settings.json."
            return nil
        }
    }

    func prepareSegmentedHistoryRetry(_ id: UUID) {
        guard experimentalRetryOwner.admits else {
            historyRetryMessage = "Discard the current cleanup first."
            return
        }
        guard let current = currentSegmentedRetrySettings(), !history.loadBlocked,
              let entry = history.entries.first(where: { $0.id == id }), let version = history.version(of: id),
              historyRetryTasks[id] == nil else { return }
        do {
            let request = try HistoryRetryRequest(segmentedSettings: current, source: entry, version: version)
            let operation = PendingOperation(name: "Experimental saved Original", origin: .historyRetry, diagnostics: diagnostics)
            operation.diagnostics?.disposition(.previewOnly, delivery: .notAttempted)
            guard experimentalRetryOwner.reserve(operation) else { operation.finish(); return }
            discardHistoryRetry(id)
            historyRetries[id] = HistoryRetryPreview(original: entry, version: version, request: request, operation: operation)
            historyRetryMessage = nil
        } catch {
            historyRetryMessage = (error as? SegmentedRetryFailure)?.message ?? "Cleanup isn’t set up."
        }
    }

    func prepareHistoryRetry(_ id: UUID, applyPreset: Bool = false) {
        guard let current = currentRetrySettings() else { return }
        guard !history.loadBlocked, let entry = history.entries.first(where: { $0.id == id }),
              let version = history.version(of: id) else {
            historyRetryMessage = "History couldn’t load. Try again."
            return
        }
        let operation = PendingOperation(name: "History retry", origin: .historyRetry, diagnostics: diagnostics)
        operation.diagnostics?.disposition(.previewOnly, delivery: .notAttempted)
        do {
            let request = try HistoryRetryRequest(settings: current, environment: retryEnvironment(), source: entry, applyPreset: applyPreset, credentials: store.credentials, diagnostics: operation.diagnostics)
            discardHistoryRetry(id)
            historyRetries[id] = HistoryRetryPreview(original: entry, version: version, request: request, operation: operation)
            historyRetryMessage = nil
        } catch {
            operation.diagnostics?.providerRefusal(error)
            operation.finish()
            // Only our policy errors are displayed, never raw provider errors.
            historyRetryMessage = (error as? TransformError)?.description ?? "Couldn’t prepare this. Check your cleanup settings."
        }
    }

    @MainActor func startHistoryRetry(_ id: UUID) async {
        guard var preview = historyRetries[id], !preview.started else { return }
        if preview.request.isSegmented, (!experimentalRetryOwner.owns(preview.token) || preview.operation.shouldAbort) {
            preview.started = true; preview.error = "Settings changed. Discard this and try again."
            historyRetries[id] = preview; return
        }
        // Start the single budget before validation/queueing/setup.
        let policy = preview.request.isSegmented ? HistoryRetryExecutionPolicy(planned: preview.request.plannedSegments, now: segmentedRetryNow, sleep: segmentedRetrySleep) : nil
        guard (preview.request.isSegmented ? currentSegmentedRetrySettings() : currentRetrySettings()) != nil,
              !preview.started,
              !preview.stale, !history.loadBlocked, history.matches(preview.original, version: preview.version) else { return }
        guard historyRetryTasks[id] == nil else {
            historyRetryMessage = "Wait for the last request to stop."
            return
        }
        preview.started = true; preview.loading = true; preview.error = nil
        historyRetries[id] = preview
        let token = preview.token
        let operation = preview.operation
        policy?.installCancellation { operation.requestAbort() }
        let work = { () async -> Result<(String, HistoryRetryProvenance), Error> in
            guard !operation.shouldAbort else { return .failure(CancellationError()) }
            do {
                if let policy {
                    return .success(try await preview.request.runSegmented(policy: policy, environment: self.retryEnvironment,
                        credentials: { self.store.credentials }, factory: self.segmentedRetryFactory, now: self.retryClock, diagnostics: operation.diagnostics,
                        progress: { completed, _ in
                            await MainActor.run {
                                do { try policy.check() } catch { return }
                                guard self.experimentalRetryOwner.owns(token), !operation.shouldAbort,
                                      var active = self.historyRetries[id], active.token == token, active.request.sameExperimentalRequest(as: preview.request) else { return }
                                active.completedSegments = completed; self.historyRetries[id] = active
                            }
                        }))
                }
                return .success(try await preview.request.run(source: preview.original.raw, factory: self.retryFactory, now: self.retryClock, diagnostics: operation.diagnostics))
            }
            catch { return .failure(error) }
        }
        let isLocal = preview.request.configuration.executionKind == .onDevice
        let run = { () async -> LocalHistoryRetryResult in
            if isLocal {
                guard let scheduler = self.localRetryScheduler else { return .failure(LocalCleanupReason.schedulerUnavailable.error) }
                return await scheduler(operation, work)
            }
            return await work()
        }
        let task = Task { () -> LocalHistoryRetryResult in
            if let policy {
                do { return try await policy.joined { await run() } }
                catch { return .failure(error) }
            }
            return await run()
        }
        historyRetryTasks[id] = task
        if preview.request.isSegmented { experimentalRetryOwner.install(task, token: token) }
        if !isLocal { operation.installAbort { task.cancel() } }
        var result = await task.value
        // The main-actor continuation can be delayed after the joined loop exits.
        // Recheck at the publication boundary, not only inside the loop.
        do { try policy?.check() } catch { result = .failure(error) }
        if let policy, case .failure(let error) = result {
            let summary = policy.finish((error as? SegmentedRetryFailure) ?? (operation.shouldAbort ? .canceled : .provider))
            operation.diagnostics?.update { $0.segmentedRetry = summary }
        }
        historyRetryTasks[id] = nil
        if preview.request.isSegmented { experimentalRetryOwner.exited(token) }
        // Admitted local work was finished by the app queue's real-exit callback.
        // A missing/refused scheduler still needs one terminal settlement here.
        if !operation.hasExited { operation.finish() }
        guard var active = historyRetries[id], active.token == token, active.request.sameExperimentalRequest(as: preview.request) else { return }
        active.loading = false
        if operation.shouldAbort || (preview.request.isSegmented && !experimentalRetryOwner.owns(token)) {
            active.error = LocalCleanupReason.canceled.message
            historyRetries[id] = active
            return
        }
        active.stale = active.stale || !history.matches(active.original, version: active.version)
        if active.stale { operation.diagnostics?.disposition(.resultUnavailable, delivery: .notAttempted) }
        switch result {
        case .success(let (text, provenance)):
            // Retain before any storage operation. This method never writes.
            active.proposed = text; active.provenance = provenance
        case .failure(let error):
            active.error = (error as? SegmentedRetryFailure)?.message ?? LocalCleanupReason.from(error)?.message ?? "That didn’t work. Try again."
        }
        historyRetries[id] = active
    }

    func saveHistoryRetry(_ id: UUID) {
        if let preview = historyRetries[id], preview.request.isSegmented,
           (!experimentalRetryOwner.owns(preview.token) || preview.operation.shouldAbort) {
            historyRetryMessage = "Settings changed. Copy the text or discard and try again."
            return
        }
        guard var preview = historyRetries[id],
              let current = preview.request.isSegmented ? currentSegmentedRetrySettings() : currentRetrySettings(),
              !preview.saved, !preview.stale, !preview.loading,
              let text = preview.proposed, let provenance = preview.provenance else { return }
        guard current.historyEnabled else {
            historyRetryMessage = "History is off. Turn it on to save, or copy the result."
            return
        }
        guard !history.loadBlocked else {
            historyRetryMessage = "History couldn’t load. Try again from History."
            return
        }
        switch history.updateResult(expected: preview.original, version: preview.version, text: text, retry: provenance) {
        case .saved: preview.saved = true; preview.error = nil; historyRetryMessage = nil
        case .stale: preview.stale = true
        case .failed:
            preview.saveFailed = true
            preview.error = "Couldn’t save to history. Try again."
        }
        historyRetries[id] = preview
    }

    func discardHistoryRetry(_ id: UUID) {
        guard let preview = historyRetries.removeValue(forKey: id) else { return }
        if preview.request.isSegmented { experimentalRetryOwner.discard(preview.token) }
        preview.operation.revoke()
        preview.operation.requestAbort()
    }
    func copyHistoryRetryOriginal(_ id: UUID) { if let preview = historyRetries[id] { copy(preview.original.raw) } }
    func copyHistoryRetryPrevious(_ id: UUID) { if let preview = historyRetries[id] { copy(preview.original.best) } }
    func copyHistoryRetryProposed(_ id: UUID) { if let text = historyRetries[id]?.proposed { copy(text) } }
}
