import AppKit
import XCTest
@testable import ParlaCore
@testable import Parla

private let admittedSource = "Please review the complete proposal before the meeting tomorrow"
private let admittedOutput = admittedSource + "."

final class LocalAppBottom: @unchecked Sendable {
    private let lock = NSLock()
    var hold = false
    var started: XCTestExpectation?
    private var pending: CheckedContinuation<String, Error>?
    private var calls = 0, checks = 0, joins = 0
    var counts: (generation: Int, availability: Int, watchdog: Int) { lock.withLock { (calls, checks, joins) } }
    var runtime: LocalCleanupRuntime {
        LocalCleanupRuntime(availability: { _ in self.lock.withLock { self.checks += 1 }; return nil },
            language: { _ in ["en": 0.99] }, generate: { _, attempted in
                self.lock.withLock { self.calls += 1 }; try attempted()
                if self.hold {
                    return try await withCheckedThrowingContinuation { continuation in
                        self.lock.withLock { self.pending = continuation }; self.started?.fulfill()
                    }
                }
                return admittedOutput
            }, now: { 10 }, sleep: { _ in
                defer { self.lock.withLock { self.joins += 1 } }
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }, appLocale: { "en_US" })
    }
    func release() { lock.withLock { pending?.resume(returning: admittedOutput); pending = nil } }
}

final class LocalHistoryFaults { var failWrite = false }

@MainActor final class LocalAppRig {
    let root: URL, store: SettingsStore, history: HistoryStore, hub: HubModel
    let backend = FakeCredentialBackend(), bottom = LocalAppBottom(), admission = LocalCleanupAdmission()
    var chain: Task<Void, Never>?
    let historyFaults = LocalHistoryFaults()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wave4d1-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try recordWave4BFixture(root, "created")
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: CredentialStore(backend: backend))
        // Legacy values and an intentionally invalid inactive network binding:
        // every automatic entry and local request must defer them unchanged.
        try Data(#"{"cleanup":{"provider":"apple-intelligence","localSourceLocale":"en","baseURL":"inactive-invalid","apiKey":"test-inactive-key"},"anthropicApiKey":"test-other-key","recoveryAudioEnabled":false}"#.utf8).write(to: store.url)
        let faults = historyFaults
        history = HistoryStore(url: root.appendingPathComponent("history.json"), persistence: .init(writeAtomically: { data, url in
            if faults.failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }))
        hub = HubModel(store: store, history: history, clipboard: { _ in XCTFail("Unexpected clipboard") },
            recordings: RecordingStore(directory: root.appendingPathComponent("audio")), retryHTTP: Self.forbiddenHTTP())
        hub.localCleanupRuntime = bottom.runtime
        hub.credentialEnvironment = { XCTFail("Local status evaluated secret environment"); return [:] }
        hub.retryEnvironment = { XCTFail("Local retry evaluated secret environment"); return [:] }
        hub.refresh()
        hub.retryFactory = { [unowned self] settings, env, access, usage in
            try ParlaCore.makeCleanupClient(settings: settings, env: Self.forbiddenEnvironment(), credentials: Self.forbiddenCredentials(),
                access: access, http: Self.forbiddenHTTP(), localRuntime: self.bottom.runtime, usage: usage)
        }
        hub.localRetryScheduler = { [unowned self] operation, work in
            guard self.admission.admit(operation) else { return .failure(LocalCleanupReason.schedulerUnavailable.error) }
            return await withCheckedContinuation { continuation in
                self.chain = LocalHistoryRetryQueue.enqueue(previous: self.chain, operation: operation, work: work) { result in
                    self.admission.exited(operation); continuation.resume(returning: result)
                }
            }
        }
    }
    static func forbiddenEnvironment() -> [String: String] { XCTFail("Local environment evaluated"); return [:] }
    static func forbiddenCredentials() -> CredentialStore { XCTFail("Local credential dependency evaluated"); return testCredentialStore() }
    static func forbiddenHTTP() -> HTTPPosting { XCTFail("Local HTTP dependency evaluated"); return URLSessionPoster() }
    func client(_ settings: Settings) throws -> CleanupProviding {
        try ParlaCore.makeCleanupClient(settings: settings, env: Self.forbiddenEnvironment(), credentials: Self.forbiddenCredentials(),
            http: Self.forbiddenHTTP(), localRuntime: bottom.runtime, usage: { _, _, _ in })
    }
    func row() -> HistoryEntry {
        let entry = HistoryEntry(raw: admittedSource, cleaned: "Previous text")
        XCTAssertTrue(history.append(entry)); return entry
    }
    func close() async throws {
        await chain?.value
        hub.flushPendingSave()
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0)
        try FileManager.default.removeItem(at: root); try recordWave4BFixture(root, "removed")
    }
}

final class LocalCleanupIntegrationTests: XCTestCase {
    @MainActor func testCompletedModelPathAdoptionAdvancesOnlyThatDraftBaseField() async throws {
        let r = try LocalAppRig()
        var installed = r.store.load()
        installed.whisperModelPath = "/owned/completed-model.bin"
        try r.store.save(installed) // Completed download's authoritative path write.
        r.hub.adoptModelPath(installed.whisperModelPath!)
        r.hub.settings.cleanup.localSourceLocale = "hi"
        r.hub.flushPendingSave()
        XCTAssertNil(r.hub.saveError)
        XCTAssertEqual(r.store.load().cleanup.localSourceLocale, "hi")
        XCTAssertEqual(r.store.load().whisperModelPath, installed.whisperModelPath)

        // Adopting a path must not refresh unrelated older privacy authority.
        var newer = try JSONSerialization.jsonObject(with: Data(contentsOf: r.store.url)) as! [String: Any]
        newer["historyEnabled"] = false
        newer["whisperModelPath"] = "/owned/another-completed-model.bin"
        let bytes = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
        try bytes.write(to: r.store.url, options: .atomic)
        _ = r.store.load()
        r.hub.adoptModelPath("/owned/another-completed-model.bin")
        r.hub.settings.cleanup.localSourceLocale = "en"
        r.hub.flushPendingSave()
        XCTAssertNotNil(r.hub.saveError)
        XCTAssertEqual(try Data(contentsOf: r.store.url), bytes)
        try await r.close()
    }

    @MainActor func testPendingLocalHubDraftCannotOverwriteNewerPrivacyAfterInterveningLoad() async throws {
        let r = try LocalAppRig()
        r.hub.settings.cleanup.localSourceLocale = "hi"
        var newer = try JSONSerialization.jsonObject(with: Data(contentsOf: r.store.url)) as! [String: Any]
        newer["historyEnabled"] = false
        newer["dictionary"] = ["Newer external vocabulary"]
        let bytes = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
        try bytes.write(to: r.store.url, options: .atomic)
        _ = r.store.load() // Same cache refresh performed by the real Hub save.
        r.hub.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: r.store.url), bytes)
        XCTAssertFalse(r.store.load().historyEnabled)
        XCTAssertEqual(r.store.load().dictionary, ["Newer external vocabulary"])
        XCTAssertNotNil(r.hub.saveError)
        try await r.close()
    }

    @MainActor func testRealHubPrepareFrozenLocalRunPreviewExplicitSaveAndStorageOnlyRetry() async throws {
        let r = try LocalAppRig(), row = r.row()
        let bytes = try Data(contentsOf: r.store.url)
        r.hub.prepareHistoryRetry(row.id)
        XCTAssertEqual(r.bottom.counts.generation, 0); XCTAssertEqual(r.bottom.counts.availability, 0)
        let prepared = try XCTUnwrap(r.hub.historyRetries[row.id])
        XCTAssertEqual(prepared.request.configuration.executionKind, .onDevice)
        // A later locale changes the new request only; the frozen request keeps en.
        r.hub.settings.cleanup.localSourceLocale = "hi"; r.hub.flushPendingSave()
        await r.hub.startHistoryRetry(row.id)
        XCTAssertEqual(r.hub.historyRetries[row.id]?.proposed, admittedOutput)
        XCTAssertTrue(r.hub.historyRetries[row.id]!.status.contains("from Apple Intelligence"))
        XCTAssertEqual(r.history.entries, [row]); XCTAssertEqual(r.bottom.counts.generation, 1)
        r.hub.settings.historyEnabled = false; r.hub.flushPendingSave(); r.hub.saveHistoryRetry(row.id)
        XCTAssertEqual(r.history.entries, [row])
        r.hub.settings.historyEnabled = true; r.hub.flushPendingSave()
        // A real storage failure retains the same proposal; repeated Save never generates.
        r.historyFaults.failWrite = true
        r.hub.saveHistoryRetry(row.id); r.hub.saveHistoryRetry(row.id)
        XCTAssertTrue(r.hub.historyRetries[row.id]!.saveFailed)
        r.historyFaults.failWrite = false
        r.hub.saveHistoryRetry(row.id)
        XCTAssertEqual(r.history.entries.first?.raw, row.raw); XCTAssertEqual(r.history.entries.first?.best, admittedOutput)
        XCTAssertEqual(r.history.entries.first?.retries?.count, 1); XCTAssertEqual(r.bottom.counts.generation, 1)
        XCTAssertEqual(r.bottom.counts.watchdog, 1)
        XCTAssertNotEqual(try Data(contentsOf: r.store.url), bytes) // deliberate genuine settings edits
        try await r.close()
    }

    @MainActor func testLocalStartupRefreshNoopRecheckAndMissingSchedulerDoNotMigrateOrGenerate() async throws {
        let r = try LocalAppRig(), row = r.row(), bytes = try Data(contentsOf: r.store.url)
        let startup = ApplicationStartupCoordinator(configure: { _ = r.store.load() }, register: {}, services: {},
            migrate: { _ = r.store.migrateSelectedCredentials() }, setup: {}, warmMic: {})
        startup.bootstrap(); startup.enterSetup(); startup.enterDictation()
        r.hub.refreshCredentialStatus(); r.hub.recheckLocalCleanup(); r.hub.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: r.store.url), bytes); XCTAssertEqual(r.bottom.counts.generation, 0)
        r.hub.prepareHistoryRetry(row.id); r.hub.localRetryScheduler = nil
        await r.hub.startHistoryRetry(row.id)
        XCTAssertEqual(r.hub.historyRetries[row.id]?.error, LocalCleanupReason.schedulerUnavailable.message)
        XCTAssertFalse(r.hub.historyRetries[row.id]!.loading); XCTAssertEqual(r.bottom.counts.generation, 0)
        XCTAssertEqual(try Data(contentsOf: r.store.url), bytes)
        r.hub.previewVocabulary(try VocabularyDocument(settings: Settings()).encoded())
        XCTAssertNotNil(r.hub.importPreview)
        let corrupt = Data("invalid local settings after preview".utf8)
        try corrupt.write(to: r.store.url)
        r.hub.applyVocabulary(.merge)
        XCTAssertNotNil(r.hub.loadError); XCTAssertEqual(try Data(contentsOf: r.store.url), corrupt)
        try await r.close()
    }

    @MainActor func testDifferentRowsSerializeAndDiscardBeforeDequeueSettlesExactlyOnce() async throws {
        let r = try LocalAppRig(), first = r.row(), second = r.row()
        r.bottom.hold = true; r.bottom.started = expectation(description: "first local entered")
        r.hub.prepareHistoryRetry(first.id); r.hub.prepareHistoryRetry(second.id)
        let one = Task { await r.hub.startHistoryRetry(first.id) }
        await fulfillment(of: [r.bottom.started!], timeout: 2)
        let two = Task { await r.hub.startHistoryRetry(second.id) }
        // Yield main until both scheduler calls have appended to the same chain.
        while r.hub.historyRetries[second.id]?.loading != true { await Task.yield() }
        let secondOperation = r.hub.historyRetries[second.id]!.operation
        r.hub.discardHistoryRetry(second.id)
        XCTAssertFalse(secondOperation.hasExited); XCTAssertEqual(r.bottom.counts.generation, 1)
        r.hub.discardHistoryRetry(first.id)
        XCTAssertNotNil(r.hub.historyRetryTasks[first.id])
        r.bottom.release(); await one.value; await two.value
        XCTAssertTrue(secondOperation.hasExited); XCTAssertNil(r.hub.historyRetries[first.id]); XCTAssertNil(r.hub.historyRetries[second.id])
        XCTAssertTrue(r.hub.historyRetryTasks.isEmpty); XCTAssertEqual(r.bottom.counts.generation, 1)
        try await r.close()
    }

    @MainActor func testActualTerminationWaitsRealLocalExitWithPreparationOffAndOnAndCanceledQuitOnlyAllowsFreshWork() async throws {
        for enabled in [false, true] {
            let r = try LocalAppRig(), prep = try PreparationAppRig(enabled: enabled), row = r.row()
            r.bottom.hold = true; r.bottom.started = expectation(description: "held local for quit")
            r.hub.prepareHistoryRetry(row.id)
            let running = Task { await r.hub.startHistoryRetry(row.id) }
            await fulfillment(of: [r.bottom.started!], timeout: 2)
            let operation = r.hub.historyRetries[row.id]!.operation
            var clipboardReply: ((Bool) -> Void)?, replies: [Bool] = []
            let replied = expectation(description: "termination reply")
            let prepExited = expectation(description: "preparation participant exited")
            let coordinator = TerminationCoordinator(clipboard: { clipboardReply = $0 }, updater: { $0(true) },
                preparation: { done in prep.owner.beginShutdown(chain: { r.chain }, reply: { allowed in
                    prepExited.fulfill(); done(allowed)
                }) }, cancelPreparation: prep.owner.cancelShutdown,
                localCleanup: { r.admission.beginShutdown(chain: { r.chain }, reply: $0) }, cancelLocalCleanup: r.admission.cancelShutdown,
                cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0); replied.fulfill() }, failure: {})
            XCTAssertEqual(coordinator.request(), .terminateLater); XCTAssertTrue(operation.shouldAbort)
            XCTAssertFalse(operation.hasExited); XCTAssertTrue(replies.isEmpty)
            XCTAssertFalse(r.admission.admit(PendingOperation(name: "late")))
            // B25's failed owner veto cancels quit, without restoring old publication authority.
            clipboardReply?(false)
            await fulfillment(of: [replied], timeout: 2)
            XCTAssertEqual(replies, [false]); XCTAssertTrue(operation.shouldAbort); XCTAssertFalse(operation.hasExited)
            r.bottom.release(); await running.value; await r.chain?.value
            await fulfillment(of: [prepExited], timeout: 2)
            XCTAssertNil(r.hub.historyRetries[row.id]?.proposed); XCTAssertFalse(r.hub.historyRetries[row.id]!.loading)
            let fresh = PendingOperation(name: "fresh after canceled quit")
            XCTAssertTrue(r.admission.admit(fresh)); r.admission.exited(fresh)
            XCTAssertEqual(replies, [false]); XCTAssertEqual(r.bottom.counts.watchdog, 1)
            try await prep.close(); try await r.close()
        }
    }

    @MainActor func testAcceptedQuitRepliesOnceAfterHeldWorkerAndRestartFailureReleasesBeforeUpdaterReply() async throws {
        let r = try LocalAppRig(), row = r.row()
        r.bottom.hold = true; r.bottom.started = expectation(description: "held for accepted quit")
        r.hub.prepareHistoryRetry(row.id)
        let running = Task { await r.hub.startHistoryRetry(row.id) }
        await fulfillment(of: [r.bottom.started!], timeout: 2)
        var replies: [Bool] = []; let reply = expectation(description: "accepted quit")
        let coordinator = TerminationCoordinator(clipboard: { $0(true) }, updater: { $0(true) },
            localCleanup: { r.admission.beginShutdown(chain: { r.chain }, reply: $0) }, cancelLocalCleanup: r.admission.cancelShutdown,
            cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0); reply.fulfill() }, failure: {})
        XCTAssertEqual(coordinator.request(), .terminateLater); XCTAssertEqual(coordinator.request(), .terminateLater)
        XCTAssertTrue(replies.isEmpty); r.bottom.release(); await running.value
        await fulfillment(of: [reply], timeout: 2); XCTAssertEqual(replies, [true])
        XCTAssertFalse(r.admission.admit(PendingOperation(name: "after accepted quit")))
        // Separate owner: actual updater intent callback observes all releases before completion.
        let local = LocalCleanupAdmission(), update = UpdateTerminationIntent(), prep = try PreparationAppRig()
        let catalog = CatalogDownloadOwner(root: r.root.appendingPathComponent("restart-catalog"), catalog: [])
        var generation = 1, undoSettings = r.store.load(); undoSettings.canceledCaptureUndoEnabled = true
        let undo = CanceledCaptureUndoController(configuration: { undoSettings }, generation: { generation }, security: { .safe },
            now: { 0 }, schedule: { _, _ in {} }, copy: { _ in XCTFail("Unexpected copy") })
        let quit = CanceledCaptureTermination(undo: undo, coordinator: TerminationCoordinator(clipboard: { $0(true) }, updater: { $0(true) },
            cancelClipboard: {}, cancelUpdater: {}, reply: { _ in }, failure: {}))
        undo.shutdown()
        XCTAssertTrue(local.reserveRestart()); XCTAssertTrue(prep.owner.core.reserveRestart()); XCTAssertTrue(catalog.claimRestartIfIdle())
        var order: [String] = []
        update.request(waitingForInstall: true, committing: true, cancelInstall: {}, reply: { _ in
            XCTAssertEqual(order, ["local", "catalog", "preparation", "guarded B57 failure"])
            let fresh = PendingOperation(name: "new"); XCTAssertTrue(local.admit(fresh)); local.exited(fresh)
            XCTAssertTrue(prep.owner.core.reserveRestart()); prep.owner.core.releaseRestart()
            undo.deliberateEntry()
            let s = DictationSession.Session(gen: generation, mode: .dictation, settings: undoSettings, cleanupConfigured: true, diagnostics: nil)
            undo.accepted(s, physical: true); undo.acknowledged(s); generation += 1
            let canceled = DictationSession.CanceledCapture(generation: s.gen, operation: s.operation, request: s.recognition, reason: .explicitCancel)
            XCTAssertTrue(undo.permitsTransfer(canceled, deadline: 3))
        })
        XCTAssertTrue(update.installFailed(releaseRestart: {
            local.releaseRestart(); order.append("local")
            catalog.releaseRestartReservation(); order.append("catalog")
            prep.owner.core.releaseRestart(); order.append("preparation")
            quit.restartFailed(); order.append("guarded B57 failure")
        }))
        try await prep.close(); try await r.close()
    }

    @MainActor func testLocalOrdinaryHistoryUsesOnlyOperationUsageAndCannotBorrowNewerNetworkTokens() async throws {
        let r = try LocalAppRig(), usage = TransformUsage(), liveBefore = Metrics.shared.snapshot()
        let settings = r.store.load()
        usage.recordRecognition(model: "fake-observed-asr")
        let pipeline = Pipeline(outputSettings: settings, bundleID: nil) { frozen in
            try ParlaCore.makeCleanupClient(settings: frozen, env: LocalAppRig.forbiddenEnvironment(), credentials: LocalAppRig.forbiddenCredentials(),
                http: LocalAppRig.forbiddenHTTP(), localRuntime: r.bottom.runtime, usage: usage.record)
        }
        let result = await pipeline.clean(transcript: admittedSource)
        XCTAssertNil(result.failure); XCTAssertEqual(Metrics.shared.snapshot(), liveBefore)
        let session = DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: true, diagnostics: nil)
        let landed = DictationSession.Landed(landing: .history, raw: admittedSource, insertText: "", bundleID: nil, appName: nil)
        let sink = HistoryPersistenceSink(history: r.history, settings: r.store)
        sink.beginEvent(for: .cleanReady(session, landed, text: result.text, failure: nil, focus: .none, metrics: usage.snapshot()), currentGeneration: 2)
        _ = sink.record(.appendHistory(raw: admittedSource, cleaned: result.text, appName: nil), metrics: { XCTFail("Borrowed newer global usage"); return nil })
        let row = try XCTUnwrap(r.history.entries.first)
        XCTAssertEqual(row.metrics?.cleanupModel, "Apple Intelligence · on-device"); XCTAssertEqual(row.metrics?.model, "fake-observed-asr")
        XCTAssertNil(row.metrics?.promptTokens); XCTAssertNil(row.metrics?.completionTokens)
        XCTAssertNil(CleanupCostEstimate.over([row]))
        // Failed/no-generation completion likewise cannot inherit old network usage.
        sink.beginEvent(for: .cleanReady(session, landed, text: admittedSource, failure: "refused", focus: .none), currentGeneration: 2)
        _ = sink.record(.appendHistory(raw: admittedSource, cleaned: nil, appName: nil), metrics: { XCTFail("Borrowed network tokens on refusal"); return nil })
        XCTAssertNil(r.history.entries.first?.metrics?.cleanupModel)
        try await r.close()
    }

    @MainActor func testActualOrdinaryDispatcherFinalizerPipelineAndHistoryWithKeyboardAndAutomationDelivery() async throws {
        let r = try LocalAppRig(), native = FoundationNativeProbe()
        native.outputs = [.init(status: 0, segments: [admittedSource])]
        var settings = r.store.load(); settings.whisperModelPath = "/owned/" + ModelCatalog.default.filename
        settings.replacements = [.init(source: "proposal", replacement: "document")]
        try r.store.save(settings)
        let undo = CanceledCaptureUndoController(configuration: { settings }, generation: { 0 }, security: { .safe },
            schedule: { _, _ in {} }, copy: { _ in XCTFail("Unexpected undo copy") })
        let preview = CanceledCaptureRecognition(controller: undo, factory: native.factory(), verify: { _ in false })
        let sink = HistoryPersistenceSink(history: r.history, settings: r.store)
        for delivery in [DictationSession.Delivery.keyboard, .resultOnly] {
            let session = DictationSession.Session(gen: 1, mode: .dictation, settings: settings, cleanupConfigured: true,
                diagnostics: DiagnosticStore(), delivery: delivery)
            let finalizer = OrdinaryDictationFinalization(recordings: r.hub.recordings, settings: r.store)
            var completed: String?
            let dispatcher = DictationExecutionDispatcher(preview: preview, ordinary: { s, samples, _ in
                await finalizer.run(operation: s.operation, samples: samples, window: nil, prepare: { _, _ in
                    try! await RecognitionAcquisition.acquire(request: s.recognition, resident: nil, factory: native.factory(), operation: s.operation)
                }, recognized: { _, raw in
                    finalizer.resolve(transcript: raw, secure: false)
                    return raw
                }, clean: { raw in
                    let pipeline = Pipeline(outputSettings: session.effectiveSettings, bundleID: nil) { try r.client($0) }
                    return await pipeline.clean(transcript: raw)
                }, completed: { raw, text, failure in
                    XCTAssertNil(failure); completed = text
                    _ = sink.record(.appendHistory(raw: raw, cleaned: text, appName: nil))
                })
            })
            r.chain = dispatcher.enqueue(.ordinary(session, samples: [Float](repeating: 0.2, count: 8000), ledger: ""), previous: r.chain)
            await r.chain?.value
            XCTAssertEqual(completed, admittedOutput.replacingOccurrences(of: "proposal", with: "document"))
            XCTAssertTrue(session.operation.hasExited)
            XCTAssertEqual(r.history.entries.first?.raw, admittedSource)
            XCTAssertEqual(r.history.entries.first?.best, completed)
        }
        XCTAssertEqual(native.calls.count, 2); XCTAssertEqual(r.bottom.counts.generation, 2)
        try await r.close()
    }

    @MainActor func testSavedSelectionAndHistoryPresetUseActualIntentAndSourceVersionGuards() async throws {
        let r = try LocalAppRig()
        let preset = TransformPreset(name: "Same language", instruction: "Please rewrite this proposal more clearly while preserving the source meaning", localPreserveSourceLanguage: true)
        r.hub.settings.transformPresets = [preset]; r.hub.settings.selectedPresetID = preset.id
        r.hub.flushPendingSave()
        var settings = r.store.load(); settings.outputMode = .raw
        let session = DictationSession.Session(gen: 1, mode: .savedPreset(selection: admittedSource, preset: preset), settings: settings, cleanupConfigured: true, diagnostics: DiagnosticStore())
        let selected = try await session.transform(instruction: preset.intent) { try r.client($0) }
        XCTAssertEqual(selected, admittedOutput)
        let row = r.row(); r.hub.prepareHistoryRetry(row.id, applyPreset: true); await r.hub.startHistoryRetry(row.id)
        XCTAssertEqual(r.hub.historyRetries[row.id]?.proposed, admittedOutput)
        let count = r.bottom.counts.generation
        r.history.clear(); r.hub.saveHistoryRetry(row.id)
        XCTAssertTrue(r.hub.historyRetries[row.id]!.stale); XCTAssertTrue(r.history.entries.isEmpty)
        XCTAssertEqual(r.bottom.counts.generation, count)
        try await r.close()
    }
}

extension LocalCleanupIntegrationTests {
    @MainActor func testSegmentedCompletedLocalHandoffCannotPublishOrSaveAcrossCanceledQuit() async throws {
        let r = try LocalAppRig()
        let text = String(repeating: "Please review the complete proposal before the meeting tomorrow with every detail preserved ", count: 65)
        let row = HistoryEntry(raw: text, cleaned: "Previous local result")
        XCTAssertTrue(r.history.append(row))
        var generations = 0
        let runtime = LocalCleanupRuntime(availability: { _ in nil }, language: { _ in ["en": 0.99] },
            generate: { prompt, attempt in
                try attempt(); generations += 1
                return String(prompt.user.dropFirst("<transcript>\n".count))
            }, appLocale: { "en_US" })
        r.hub.segmentedRetryFactory = { settings, _, access, policy, usage in
            try ParlaCore.makeCleanupClient(settings: settings, env: LocalAppRig.forbiddenEnvironment(), credentials: LocalAppRig.forbiddenCredentials(),
                access: access, http: LocalAppRig.forbiddenHTTP(), localRuntime: runtime, executionPolicy: policy, usage: usage)
        }
        r.hub.prepareSegmentedHistoryRetry(row.id)
        let operation = try XCTUnwrap(r.hub.historyRetries[row.id]?.operation)
        let owner = r.hub.experimentalRetryOwner
        var armed = false, triggered = false, vetoes = 0
        let drained = expectation(description: "Completed experimental task drained")
        let coordinator = TerminationCoordinator(clipboard: { $0(false) }, updater: { $0(true) },
            experimentalRetry: { done in owner.beginShutdown { allowed in drained.fulfill(); done(allowed) } },
            cancelExperimentalRetry: owner.cancelShutdown, cancelClipboard: {}, cancelUpdater: {},
            reply: { _ in XCTFail("Synchronous veto must not reply twice") }, failure: { vetoes += 1 })
        let scheduler = r.hub.localRetryScheduler!
        r.hub.localRetryScheduler = { op, work in
            let result = await scheduler(op, work)
            await MainActor.run { XCTAssertTrue(op.hasExited); armed = true }
            return result
        }
        // The existing final main-actor budget check is after the retained task
        // succeeds but before Hub publication. No production timing hook needed.
        r.hub.segmentedRetryNow = {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if armed, !triggered {
                        triggered = true
                        XCTAssertTrue(operation.hasExited); XCTAssertFalse(operation.shouldAbort)
                        XCTAssertEqual(coordinator.request(), .terminateCancel)
                    }
                }
            }
            return 10
        }
        await r.hub.startHistoryRetry(row.id)
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(triggered); XCTAssertEqual(vetoes, 1)
        XCTAssertGreaterThan(generations, 1); XCTAssertTrue(operation.hasExited)
        XCTAssertFalse(owner.owns(operation.id)); XCTAssertTrue(owner.admits)
        XCTAssertTrue(r.hub.historyRetries[row.id]?.proposed == nil)
        r.hub.saveHistoryRetry(row.id)
        XCTAssertTrue(r.history.entries.first?.cleaned == row.cleaned)
        XCTAssertEqual(r.history.entries.first?.retries?.count ?? 0, 0)
        r.hub.prepareSegmentedHistoryRetry(row.id)
        XCTAssertNotEqual(r.hub.historyRetries[row.id]?.token, operation.id)
        XCTAssertFalse(r.hub.historyRetries[row.id]?.started ?? true)
        r.hub.discardHistoryRetry(row.id); try await r.close()
    }

    @MainActor func testSegmentedFinishedOperationRestartRevocationSurvivesRelease() async {
        let owner = ExperimentalHistoryRetryOwner(), operation = PendingOperation(name: "Completed local handoff")
        XCTAssertTrue(owner.reserve(operation))
        let task = Task<LocalHistoryRetryResult, Never> { operation.finish(); return .failure(CancellationError()) }
        owner.install(task, token: operation.id)
        _ = await task.value
        XCTAssertTrue(operation.hasExited); XCTAssertTrue(owner.busy)
        XCTAssertTrue(owner.reserveRestart()); XCTAssertFalse(owner.owns(operation.id))
        await owner.drainRestart(); owner.releaseRestart()
        XCTAssertFalse(owner.owns(operation.id)); XCTAssertTrue(owner.admits)
    }

    @MainActor func testSegmentedLocalWholeAndAllSegmentPreflightOneSchedulerAndRealSave() async throws {
        let r = try LocalAppRig()
        let text = String(repeating: "Please review the complete proposal before the meeting tomorrow with every detail preserved ", count: 65)
        let entry = HistoryEntry(raw: text, cleaned: "Previous local result")
        XCTAssertTrue(r.history.append(entry))
        var languages: [String] = [], prompts: [LocalCleanupPrompt] = [], admissions = 0
        var watchdogJoins = 0
        let runtime = LocalCleanupRuntime(availability: { _ in nil }, language: { text in languages.append(text); return ["en": 0.99] },
            generate: { prompt, attempt in
                try attempt(); prompts.append(prompt)
                XCTAssertTrue(languages.contains(text))
                XCTAssertGreaterThanOrEqual(languages.count, 3)
                return String(prompt.user.dropFirst("<transcript>\n".count))
            }, sleep: { _ in defer { watchdogJoins += 1 }; try await Task.sleep(nanoseconds: 60_000_000_000) }, appLocale: { "en_US" })
        r.hub.segmentedRetryFactory = { settings, _, access, policy, usage in
            try ParlaCore.makeCleanupClient(settings: settings, env: LocalAppRig.forbiddenEnvironment(), credentials: LocalAppRig.forbiddenCredentials(),
                access: access, http: LocalAppRig.forbiddenHTTP(), localRuntime: runtime, executionPolicy: policy, usage: usage)
        }
        let scheduler = r.hub.localRetryScheduler!
        r.hub.localRetryScheduler = { operation, work in admissions += 1; return await scheduler(operation, work) }
        r.hub.prepareSegmentedHistoryRetry(entry.id)
        XCTAssertTrue(languages.isEmpty); XCTAssertTrue(prompts.isEmpty); XCTAssertEqual(admissions, 0)
        let planned = r.hub.historyRetries[entry.id]!.request.plannedSegments
        await r.hub.startHistoryRetry(entry.id)
        XCTAssertNil(r.hub.historyRetries[entry.id]?.error)
        XCTAssertEqual(prompts.count, planned); XCTAssertEqual(admissions, 1); XCTAssertEqual(watchdogJoins, planned)
        XCTAssertEqual(r.hub.historyRetries[entry.id]?.proposed, text)
        XCTAssertNil(r.hub.historyRetries[entry.id]?.provenance?.usage?.promptTokens)
        r.hub.saveHistoryRetry(entry.id); XCTAssertEqual(r.history.entries.first?.raw, text)
        XCTAssertEqual(r.history.entries.first?.retries?.last?.segmented?.attempted, planned)
        r.hub.discardHistoryRetry(entry.id); try await r.close()
    }

    @MainActor func testSegmentedLocalPreflightRefusesWholeOrAnyShortSegmentBeforeGeneration() async throws {
        for text in [String(repeating: "word ", count: 1800), String(repeating: "Please review all complete details before the meeting tomorrow ", count: 65) + String(repeating: "x", count: 100)] {
            let r = try LocalAppRig(); let row = HistoryEntry(raw: text); XCTAssertTrue(r.history.append(row))
            r.hub.segmentedRetryFactory = { settings, _, access, policy, usage in
                try ParlaCore.makeCleanupClient(settings: settings, env: LocalAppRig.forbiddenEnvironment(), credentials: LocalAppRig.forbiddenCredentials(),
                    access: access, http: LocalAppRig.forbiddenHTTP(), localRuntime: r.bottom.runtime, executionPolicy: policy, usage: usage)
            }
            r.hub.prepareSegmentedHistoryRetry(row.id)
            await r.hub.startHistoryRetry(row.id)
            XCTAssertNil(r.hub.historyRetries[row.id]?.proposed); XCTAssertNotNil(r.hub.historyRetries[row.id]?.error)
            XCTAssertEqual(r.bottom.counts.generation, 0)
            r.hub.discardHistoryRetry(row.id); try await r.close()
        }
    }

    @MainActor func testSegmentedHeldLocalCancellationRetainsLeaseAndComposedQuitUntilActualExit() async throws {
        let r = try LocalAppRig()
        let text = String(repeating: "Please review the complete proposal before the meeting tomorrow with every detail preserved ", count: 65)
        let row = HistoryEntry(raw: text); XCTAssertTrue(r.history.append(row))
        r.bottom.hold = true; r.bottom.started = expectation(description: "native bottom held")
        r.hub.segmentedRetryFactory = { settings, _, access, policy, usage in
            try ParlaCore.makeCleanupClient(settings: settings, env: LocalAppRig.forbiddenEnvironment(), credentials: LocalAppRig.forbiddenCredentials(),
                access: access, http: LocalAppRig.forbiddenHTTP(), localRuntime: r.bottom.runtime, executionPolicy: policy, usage: usage)
        }
        r.hub.prepareSegmentedHistoryRetry(row.id)
        let running = Task { await r.hub.startHistoryRetry(row.id) }
        await fulfillment(of: [r.bottom.started!], timeout: 2)
        let operation = r.hub.historyRetries[row.id]!.operation
        let prep = try PreparationAppRig(), apple = AppleOwnerRig(), parakeet = try G2aRig()
        let clipboard = ExperimentRig(), update = UpdateTerminationIntent()
        let catalog = CatalogDownloadOwner(root: r.root.appendingPathComponent("idle-catalog"), catalog: [])
        XCTAssertTrue(clipboard.paste())
        var replies: [Bool] = []
        let reply = expectation(description: "B25 canceled quit")
        let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown,
            updater: { update.request(waitingForInstall: false, committing: false, cancelInstall: {}, reply: $0) },
            download: catalog.beginShutdown, cancelDownload: catalog.cancelShutdown,
            preparation: { prep.owner.beginShutdown(chain: { r.chain }, reply: $0) }, cancelPreparation: prep.owner.cancelShutdown,
            appleSpeech: { apple.owner.beginShutdown(chain: { r.chain }, reply: $0) }, cancelAppleSpeech: apple.owner.cancelShutdown,
            parakeet: { parakeet.owner.beginShutdown(chain: { r.chain }, reply: $0) }, cancelParakeet: parakeet.owner.cancelShutdown,
            localCleanup: { r.admission.beginShutdown(chain: { r.chain }, reply: $0) }, cancelLocalCleanup: r.admission.cancelShutdown,
            experimentalRetry: r.hub.experimentalRetryOwner.beginShutdown, cancelExperimentalRetry: r.hub.experimentalRetryOwner.cancelShutdown,
            cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: update.cancel,
            reply: { replies.append($0); reply.fulfill() }, failure: {})
        XCTAssertEqual(coordinator.request(), .terminateLater)
        XCTAssertTrue(operation.shouldAbort); XCTAssertFalse(operation.hasExited); XCTAssertTrue(replies.isEmpty)
        r.hub.discardHistoryRetry(row.id); XCTAssertTrue(r.hub.experimentalRetryOwner.busy)
        r.hub.prepareSegmentedHistoryRetry(row.id); XCTAssertNil(r.hub.historyRetries[row.id])
        clipboard.board.writeResults = [false]; clipboard.fire(clipboard.timers[0])
        await fulfillment(of: [reply], timeout: 2); XCTAssertEqual(replies, [false])
        XCTAssertTrue(clipboard.delivery.restoreFailed)
        XCTAssertTrue(r.hub.experimentalRetryOwner.busy)
        r.bottom.release(); await running.value; await r.chain?.value
        XCTAssertTrue(operation.hasExited); XCTAssertNil(r.hub.historyRetries[row.id]); XCTAssertFalse(r.hub.experimentalRetryOwner.busy)
        XCTAssertEqual(r.bottom.counts.generation, 1); XCTAssertEqual(r.bottom.counts.watchdog, 1)
        r.hub.prepareSegmentedHistoryRetry(row.id); XCTAssertNotNil(r.hub.historyRetries[row.id])
        r.hub.discardHistoryRetry(row.id)
        XCTAssertTrue(r.hub.experimentalRetryOwner.reserveRestart()); await r.hub.experimentalRetryOwner.drainRestart()
        XCTAssertFalse(r.hub.experimentalRetryOwner.admits); r.hub.experimentalRetryOwner.releaseRestart()
        XCTAssertTrue(r.hub.experimentalRetryOwner.admits)
        parakeet.cleanup(); try await prep.close(); try await r.close()
    }
}

extension LocalCleanupIntegrationTests {
    @MainActor func testSegmentedSingleStartDeadlineIncludesRealSchedulerQueueWaitAndJoinsWatchdog() async throws {
        let r = try LocalAppRig()
        let text = String(repeating: "Please review the complete proposal before the meeting tomorrow with every detail preserved ", count: 65)
        let row = HistoryEntry(raw: text); XCTAssertTrue(r.history.append(row))
        var clock: TimeInterval = 10
        var wake: CheckedContinuation<Void, Never>?, releaseQueue: CheckedContinuation<Void, Never>?
        let schedulerEntered = expectation(description: "existing scheduler entered")
        let scheduler = r.hub.localRetryScheduler!
        r.hub.localRetryScheduler = { operation, work in schedulerEntered.fulfill(); return await scheduler(operation, work) }
        let watchdogEntered = expectation(description: "single outer watchdog installed")
        let queueEntered = expectation(description: "real queue predecessor held")
        var watchdogJoins = 0, sleeps = 0
        r.hub.segmentedRetryNow = { clock }
        r.hub.segmentedRetrySleep = { remaining in
            XCTAssertEqual(remaining, 60); sleeps += 1
            await withCheckedContinuation { wake = $0; watchdogEntered.fulfill() }
            watchdogJoins += 1
        }
        r.chain = Task { await withCheckedContinuation { releaseQueue = $0; queueEntered.fulfill() } }
        await fulfillment(of: [queueEntered], timeout: 2)
        r.hub.segmentedRetryFactory = { settings, _, access, policy, usage in
            try ParlaCore.makeCleanupClient(settings: settings, env: LocalAppRig.forbiddenEnvironment(), credentials: LocalAppRig.forbiddenCredentials(),
                access: access, http: LocalAppRig.forbiddenHTTP(), localRuntime: r.bottom.runtime, executionPolicy: policy, usage: usage)
        }
        r.hub.prepareSegmentedHistoryRetry(row.id)
        let running = Task { await r.hub.startHistoryRetry(row.id) }
        await fulfillment(of: [watchdogEntered, schedulerEntered], timeout: 2)
        clock = 70; wake?.resume(); wake = nil
        // The watchdog cannot turn queue cancellation into an actual exit.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(r.hub.experimentalRetryOwner.busy); XCTAssertNotNil(r.hub.historyRetryTasks[row.id])
        XCTAssertEqual(r.bottom.counts.generation, 0); XCTAssertNil(r.hub.historyRetries[row.id]?.proposed)
        releaseQueue?.resume(); releaseQueue = nil
        await running.value; await r.chain?.value
        XCTAssertEqual(sleeps, 1); XCTAssertEqual(watchdogJoins, 1); XCTAssertEqual(r.bottom.counts.generation, 0)
        XCTAssertNotNil(r.hub.historyRetries[row.id]?.error); XCTAssertNil(r.hub.historyRetries[row.id]?.proposed)
        r.hub.discardHistoryRetry(row.id); try await r.close()
    }
}
