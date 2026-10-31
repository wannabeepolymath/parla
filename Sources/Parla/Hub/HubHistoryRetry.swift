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
        if stale { return "Saved row changed or was removed. This preview can only be copied; it cannot be saved." }
        if loading { return request.isSegmented ? "Experimental cleanup: \(completedSegments)/\(request.plannedSegments) complete. Cancellation waits for owned work to exit." : "Request in progress…" }
        if saved { return "Result saved. Original text and initial metadata preserved." }
        if let error { return error }
        if proposed != nil {
            switch provenance?.configuration.executionKind ?? request.configuration.executionKind {
            case .deterministic: return "Local-only result ready — no provider request ran."
            case .onDevice: return "On-device generated result ready for review; no endpoint request ran."
            case .network: return "Proposed result ready for review."
            }
        }
        return "Review the frozen current global settings below, then explicitly start the request."
    }
}

extension HubModel {
    /// Missing/corrupt current settings never authorize a fallback request/save.
    private func currentRetrySettings() -> Settings? {
        flushPendingSave()
        let current = store.load()
        if store.lastError != nil { loadError = store.lastError }
        guard loadError == nil, saveError == nil, store.lastError == nil else {
            historyRetryMessage = "Repair settings and reload them before starting a request or saving. Existing text and previews can still be copied."
            return nil
        }
        return current
    }

    private func currentSegmentedRetrySettings() -> Settings? {
        // Latch invalidity before a pending flush can repair what was observed.
        do { _ = try store.savedRetrySnapshot() }
        catch {
            historyRetryMessage = "Experimental cleanup requires readable, valid saved settings. Repair and reload before reviewing a new request."
            return nil
        }
        // The normal save owns credential migration and application callbacks.
        // Leave its pending work intact and require an explicit review afterward.
        guard !hasPendingSettingsSave else {
            historyRetryMessage = "Settings are still saving. Review the request after they finish."
            return nil
        }
        do {
            let current = try store.savedRetrySnapshot()
            guard loadError == nil, saveError == nil else { throw SegmentedRetryFailure.configuration }
            return current
        } catch {
            historyRetryMessage = "Saved settings are unavailable. Repair and reload before starting or saving."
            return nil
        }
    }

    func prepareSegmentedHistoryRetry(_ id: UUID) {
        guard experimentalRetryOwner.admits else {
            historyRetryMessage = "An experimental review or operation is still retained. Discard it and wait for actual exit before a new review."
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
            historyRetryMessage = (error as? SegmentedRetryFailure)?.message ?? "Experimental cleanup configuration is unavailable."
        }
    }

    func prepareHistoryRetry(_ id: UUID, applyPreset: Bool = false) {
        guard let current = currentRetrySettings() else { return }
        guard !history.loadBlocked, let entry = history.entries.first(where: { $0.id == id }),
              let version = history.version(of: id) else {
            historyRetryMessage = "Reload history before reviewing a saved row."
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
            historyRetryMessage = (error as? TransformError)?.description ?? "Cannot prepare this request."
        }
    }

    @MainActor func startHistoryRetry(_ id: UUID) async {
        guard var preview = historyRetries[id], !preview.started else { return }
        if preview.request.isSegmented, (!experimentalRetryOwner.owns(preview.token) || preview.operation.shouldAbort) {
            preview.started = true; preview.error = "This experimental review was revoked. Discard it and review a new request."
            historyRetries[id] = preview; return
        }
        // Start the single budget before validation/queueing/setup.
        let policy = preview.request.isSegmented ? HistoryRetryExecutionPolicy(planned: preview.request.plannedSegments, now: segmentedRetryNow, sleep: segmentedRetrySleep) : nil
        guard (preview.request.isSegmented ? currentSegmentedRetrySettings() : currentRetrySettings()) != nil,
              !preview.started,
              !preview.stale, !history.loadBlocked, history.matches(preview.original, version: preview.version) else { return }
        guard historyRetryTasks[id] == nil else {
            historyRetryMessage = "Previous request is still stopping. Wait for it to exit before starting another for this row."
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
            active.error = (error as? SegmentedRetryFailure)?.message ?? LocalCleanupReason.from(error)?.message ?? "Request failed or returned empty/invalid text. Review a new request to try again; Retry Save is unavailable."
        }
        historyRetries[id] = active
    }

    func saveHistoryRetry(_ id: UUID) {
        if let preview = historyRetries[id], preview.request.isSegmented,
           (!experimentalRetryOwner.owns(preview.token) || preview.operation.shouldAbort) {
            historyRetryMessage = "This experimental review was revoked. Retained text can be copied; discard and review a new request to continue."
            return
        }
        guard var preview = historyRetries[id],
              let current = preview.request.isSegmented ? currentSegmentedRetrySettings() : currentRetrySettings(),
              !preview.saved, !preview.stale, !preview.loading,
              let text = preview.proposed, let provenance = preview.provenance else { return }
        guard current.historyEnabled else {
            historyRetryMessage = "History is off. Preview and Copy remain available until quit or discard. Enable history to explicitly save this same result without another request."
            return
        }
        guard !history.loadBlocked else {
            historyRetryMessage = "Retry Load before saving. The proposed result remains available."
            return
        }
        switch history.updateResult(expected: preview.original, version: preview.version, text: text, retry: provenance) {
        case .saved: preview.saved = true; preview.error = nil; historyRetryMessage = nil
        case .stale: preview.stale = true
        case .failed:
            preview.saveFailed = true
            preview.error = "Couldn't save. Saved text is unchanged. Retry Save stores this same result without another request."
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
