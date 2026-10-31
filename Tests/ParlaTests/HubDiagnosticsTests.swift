import Darwin
import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import ParlaCore
@testable import Parla

private struct DiagnosticHTTP: HTTPPosting {
    let model: String?
    var failure = false
    func post(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var body: [String: Any] = ["choices": [["message": ["content": "PRIVATE_RESULT"], "finish_reason": "stop"]]]
        if let model { body["model"] = model }
        if failure { body = ["error": ["message": "PRIVATE_PROVIDER_DESCRIPTION PRIVATE_KEY PRIVATE_SELECTION"]] }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: failure ? 500 : 200, httpVersion: nil, headerFields: nil)!)
    }
}
private final class DiagnosticHubRecognition: RecognitionClient {
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? { "PRIVATE_TRANSCRIPT" }
}

private final class DiagnosticHubClock {
    private let lock = NSLock()
    private var value: Double = 100
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

final class HubDiagnosticsTests: XCTestCase {
    private var root: URL!
    private var backend: FakeCredentialBackend!
    private var store: SettingsStore!
    private var history: HistoryStore!
    private var recordings: RecordingStore!
    private var diagnostics: DiagnosticStore!
    private var clock: DiagnosticHubClock!
    private var hub: HubModel!
    private var selected: URL?
    private var writes: [Data] = []
    private var failWrite = false
    private var forbidden = 0
    private var panelCalls = 0
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-diagnostics-3c-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backend = FakeCredentialBackend()
        let credentials = CredentialStore(backend: backend)
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: credentials)
        var settings = Settings(); settings.historyEnabled = false
        settings.whisperModelPath = "/PRIVATE_MODEL_PATH/PRIVATE_MODEL"
        settings.cleanup.provider = "openai-compatible"
        settings.cleanup.baseURL = "https://PRIVATE_ENDPOINT.test/PRIVATE_PATH"
        settings.cleanup.model = "PRIVATE_MODEL"; settings.cleanup.apiKeyEnvVar = "PRIVATE_ENV_NAME"
        settings.inputDeviceUID = "PRIVATE_DEVICE_NAME_UID"
        settings.dictionary = ["PRIVATE_DICTIONARY"]; settings.snippets = ["PRIVATE_SNIPPET_KEY": "PRIVATE_SNIPPET_VALUE"]
        settings.transformPresets = [.init(name: "PRIVATE_PRESET", instruction: "PRIVATE_INSTRUCTION")]
        try store.save(settings)
        backend.values[try CredentialScope.compatible(settings.cleanup.baseURL)] = "PRIVATE_KEY"
        history = HistoryStore(url: root.appendingPathComponent("history.json"))
        recordings = RecordingStore(directory: root.appendingPathComponent("recordings"), keepAll: false, requireValidatedPolicy: true)
        try FileManager.default.createDirectory(at: recordings.directory, withIntermediateDirectories: true)
        clock = DiagnosticHubClock()
        diagnostics = DiagnosticStore(now: clock.now)
        hub = HubModel(store: store, history: history, clipboard: { [unowned self] _ in self.forbidden += 1 }, recordings: recordings, retryHTTP: DiagnosticHTTP(model: "PRIVATE_RETRY_MODEL"), diagnostics: diagnostics)
        hub.refresh()
        selected = root.appendingPathComponent("export.json")
        hub.diagnosticPanel = { [unowned self] request in
            XCTAssertEqual(request.contentType, .json); XCTAssertEqual(request.filename, "parla-diagnostics.json")
            self.panelCalls += 1; return self.selected
        }
        hub.diagnosticWriter = { [unowned self] data, _ in
            if self.failWrite { throw NSError(domain: "PRIVATE_WRITE_ERROR_PATH", code: 1) }
            self.writes.append(data)
        }
        hub.retryEnvironment = { [:] }
        hub.onTryoutStart = { [unowned self] in self.forbidden += 1; return "forbidden" }
        hub.onTryoutStop = { [unowned self] _ in self.forbidden += 1 }
        hub.onDownloadModel = { [unowned self] _ in self.forbidden += 1 }
        hub.onRecoveryTranscribe = { [unowned self] _, _, _ in self.forbidden += 1 }
        hub.onSaved = { [unowned self] in self.forbidden += 1 }
    }
    override func tearDownWithError() throws {
        XCTAssertEqual(forbidden, 0)
        hub = nil; recordings = nil; history = nil; store = nil; backend = nil; diagnostics = nil
        try FileManager.default.removeItem(at: root)
    }
    func testActualHubReviewExportsRealAdapterEvidenceAndNoPrivateIdentity() async throws {
        let native = FoundationNativeProbe(), operation = record()
        native.outputs = [.init(status: 0, segments: ["PRIVATE_TRANSCRIPT"])]
        let handle = try await native.factory().acquire(request: RecognitionRequest(settings: store.load()), diagnostics: operation.diagnostics)
        _ = await handle.finalResult(samples: [Float](repeating: 0.2, count: 8000), window: nil, diagnostics: operation.diagnostics)
        let reads = native.metadataReads
        hub.prepareDiagnostics(); hub.exportDiagnostics()
        let data = try XCTUnwrap(writes.first)
        try assertPrivateValuesAbsent(data)
        let snapshot = try JSONDecoder().decode(DiagnosticRecord.self, from: JSONEncoder().encode(diagnostics.snapshot().records[0]))
        XCTAssertEqual(snapshot.recognition?.evidence, .customUnknown)
        XCTAssertEqual(snapshot.recognition?.nativeOutcome, .completed)
        XCTAssertEqual(snapshot.recognition?.modelLanguages, .multilingual)
        XCTAssertEqual(native.metadataReads, reads); XCTAssertEqual(native.paths.count, 1)
    }
    private func record() -> PendingOperation { PendingOperation(name: "PRIVATE_APP_SITE_PRESET", origin: .dictation, diagnostics: diagnostics) }
    private func assertPrivateValuesAbsent(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_"), file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["schemaVersion", "appVersion", "osVersion", "records"]))
        XCTAssertNotNil(object["osVersion"])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let allowlist: Set<String> = ["id", "origin", "operationFinished", "cancellationRequested", "capture", "firstPCMDeadline", "captureStartedMs", "captureStoppedMs", "firstPCMMs", "route", "routeEvidence", "asr", "recognition", "provider", "providerOutcome", "providerRequestAttempted", "delivery", "reason", "clipboard", "receiptObserved", "staleCompletion", "requestedASR", "resolvedASR", "frozenProviderModel", "requestedProviderModel", "resolvedProviderModel", "timings"]
        for record in records {
            XCTAssertTrue(Set(record.keys).isSubset(of: allowlist), file: file, line: line)
            if let recognition = record["recognition"] as? [String: Any] {
                let keys: Set<String> = ["engine", "evidence", "modelLanguages", "sampleRate", "nativeIncrementalStream", "cooperativeDecodeAbort", "cancellableConstruction", "wordTiming", "confidence", "alternatives", "nativeOutcome", "deliveryCanceled", "assembly"]
                XCTAssertTrue(Set(recognition.keys).isSubset(of: keys), file: file, line: line)
                XCTAssertEqual(recognition["engine"] as? String, "whisper")
                XCTAssertEqual(recognition["sampleRate"] as? Int, 16000)
                let strings = recognition.values.compactMap { $0 as? String }
                let finite: Set<String> = ["whisper", "admittedCatalog", "customUnknown", "unknown", "englishOnly", "multilingual", "completed", "failed", "canceled", "completedTail", "failedTail", "canceledTail", "skippedTail"]
                XCTAssertTrue(strings.allSatisfy { finite.contains($0) }, file: file, line: line)
            }
        }
    }
    private func produce(http: HTTPPosting) async throws -> PendingOperation {
        let operation = record(), settings = store.load(), credentials = store.credentials
        let request = RecognitionRequest(settings: settings)
        operation.diagnostics?.recognition(request: request)
        let queue = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true, work: {
            await DictationProcessing.final(operation: operation, samples: [Float](repeating: 0.2, count: 8000), window: nil, prepare: {
                try! RecognitionHandle(request: request, diagnostics: operation.diagnostics) { _ in DiagnosticHubRecognition() }
            }, recognized: { _, raw in raw }, clean: { source in
                let pipeline = Pipeline(outputSettings: settings, bundleID: "PRIVATE_APP", browserURL: "https://PRIVATE_SITE.test", diagnostics: operation.diagnostics) { settings in
                    try ParlaCore.makeCleanupClient(settings: settings, env: ["PRIVATE_UNUSED_ENV": "PRIVATE_ENV_VALUE"], credentials: credentials, http: http, usage: { _, _, _ in })
                }
                return await pipeline.clean(transcript: source)
            }, completed: { _, _, _ in
                if operation.authorizeDispatch() { _ = DiagnosticDispatch.paste(diagnostics: operation.diagnostics) { true } }
            })
        })
        await queue.value
        return operation
    }

    @MainActor func testActualProducerToReviewToWriterOmitsPrivateInputsAndDescriptions() async throws {
        _ = try await produce(http: DiagnosticHTTP(model: "PRIVATE_RESPONSE_MODEL"))
        _ = try await produce(http: DiagnosticHTTP(model: nil, failure: true))
        hub.prepareDiagnostics()
        let review = try XCTUnwrap(hub.diagnosticReview)
        try assertPrivateValuesAbsent(review)
        _ = HubDiagnosticsView(model: hub).body
        hub.exportDiagnostics()
        XCTAssertEqual(writes, [review]); XCTAssertEqual(panelCalls, 1)
        let records = diagnostics.snapshot().records
        XCTAssertEqual(records.first?.providerOutcome, .returned); XCTAssertEqual(records.last?.providerOutcome, .failed)
        XCTAssertEqual(records.first?.resolvedASR, .unavailable)
        XCTAssertEqual(records.first?.resolvedProviderModel, .unavailable)
        XCTAssertEqual(records.first?.delivery, .postedUnverified)
        XCTAssertTrue(records.allSatisfy { $0.providerRequestAttempted && $0.timings.contains { $0.stage == .providerRequest } })
    }

    @MainActor func testSelectedSourceAndInstructionGoThroughTransformButNeverDiagnosticExport() async throws {
        var settings = store.load()
        let preset = try XCTUnwrap(settings.transformPresets.first)
        settings.selectedPresetID = preset.id
        let session = DictationSession.Session(gen: 1, mode: .savedPreset(selection: "PRIVATE_SELECTION", preset: preset),
            settings: settings, cleanupConfigured: true, diagnostics: diagnostics)
        let credentials = store.credentials
        let task = PendingOperationQueue.enqueue(previous: nil, operation: session.operation, completes: true, work: {
            let result = await DictationProcessing.transform(operation: session.operation, request: {
                try await session.transform(instruction: preset.intent) { settings in
                    try ParlaCore.makeCleanupClient(settings: settings, env: [:], credentials: credentials,
                        http: DiagnosticHTTP(model: "PRIVATE_RESPONSE_MODEL"), usage: { _, _, _ in })
                }
            })
            XCTAssertNotNil(result)
            if session.operation.authorizeDispatch() { _ = DiagnosticDispatch.paste(diagnostics: session.operation.diagnostics) { true } }
        })
        await task.value
        XCTAssertEqual(diagnostics.snapshot().records.first?.origin, .savedTransform)
        XCTAssertTrue(diagnostics.snapshot().records.first!.providerRequestAttempted)
        hub.prepareDiagnostics(); hub.exportDiagnostics()
        try assertPrivateValuesAbsent(try XCTUnwrap(writes.last))
    }

    @MainActor func testRequestedAndResponseModelAreSeparateAndMissingResponseRemainsUnknown() async throws {
        var settings = store.load(); settings.cleanup.model = "claude-haiku-4-5"; try store.save(settings)
        _ = try await produce(http: DiagnosticHTTP(model: "claude-sonnet-5"))
        _ = try await produce(http: DiagnosticHTTP(model: nil))
        let records = diagnostics.snapshot().records
        XCTAssertEqual(records[0].frozenProviderModel, .haiku); XCTAssertEqual(records[0].requestedProviderModel, .haiku)
        XCTAssertEqual(records[0].resolvedProviderModel, .sonnet)
        XCTAssertEqual(records[1].requestedProviderModel, .haiku); XCTAssertEqual(records[1].resolvedProviderModel, .unavailable)
        hub.prepareDiagnostics(); hub.exportDiagnostics(); try assertPrivateValuesAbsent(try XCTUnwrap(writes.last))
    }

    @MainActor func testDeniedCredentialRetryPreparationIsTypedAndExportStillWorksWithHistoryOff() async throws {
        XCTAssertTrue(history.append(.init(raw: "PRIVATE_TRANSCRIPT", appName: "PRIVATE_APP")))
        let row = try XCTUnwrap(history.entries.first)
        backend.readState = .denied
        hub.prepareHistoryRetry(row.id)
        XCTAssertNil(hub.historyRetries[row.id])
        XCTAssertEqual(diagnostics.snapshot().records.last?.origin, .historyRetry)
        XCTAssertEqual(diagnostics.snapshot().records.last?.providerOutcome, .credentialDenied)
        XCTAssertEqual(diagnostics.snapshot().records.last?.delivery, .notAttempted)
        hub.prepareDiagnostics(); hub.exportDiagnostics()
        try assertPrivateValuesAbsent(try XCTUnwrap(writes.last))
    }

    @MainActor func testRetrySetupTimesFrozenCredentialAcquisitionAndRefusalWithoutExtraReads() async throws {
        XCTAssertTrue(history.append(.init(raw: "PRIVATE_TRANSCRIPT")))
        let row = try XCTUnwrap(history.entries.first)
        backend.onRead = { [unowned self] in self.clock.advance(0.25) }
        for state in [CredentialRead.value("PRIVATE_KEY"), .denied, .canceled] {
            hub.discardHistoryRetry(row.id)
            hub.clearDiagnostics(); backend.readState = state
            let reads = backend.reads
            hub.prepareHistoryRetry(row.id)
            var record = try XCTUnwrap(diagnostics.snapshot().records.last)
            let preparation = try XCTUnwrap(record.timings.first { $0.stage == .providerSetup })
            XCTAssertEqual(preparation.calls, 1); XCTAssertEqual(preparation.active, 0)
            XCTAssertEqual(preparation.totalMs, 250, accuracy: 0.001)
            XCTAssertEqual(backend.reads, reads + 1)
            if case .value = state {
                await hub.startHistoryRetry(row.id)
                record = try XCTUnwrap(diagnostics.snapshot().records.last)
                let setup = try XCTUnwrap(record.timings.first { $0.stage == .providerSetup })
                XCTAssertEqual(setup.calls, 2); XCTAssertEqual(setup.active, 0)
                XCTAssertEqual(setup.totalMs, 250, accuracy: 0.001)
                XCTAssertEqual(backend.reads, reads + 1, "Start must use the frozen credential")
                XCTAssertNotNil(hub.historyRetries[row.id]?.proposed)
            } else {
                XCTAssertNil(hub.historyRetries[row.id]); XCTAssertTrue(record.operationFinished)
                XCTAssertEqual(record.providerOutcome, state.status == .denied ? .credentialDenied : .credentialCanceled)
            }
        }
        var settings = store.load(); settings.cleanupEnabled = false
        try store.save(settings); hub.refresh(); hub.clearDiagnostics()
        let reads = backend.reads
        hub.prepareHistoryRetry(row.id)
        XCTAssertEqual(backend.reads, reads)
        XCTAssertFalse(try XCTUnwrap(diagnostics.snapshot().records.last).timings.contains { $0.stage == .providerSetup })
    }

    @MainActor func testReviewFreezePanelCancelFailedWriteAndRetryDoNotReadOrMutateOtherStores() throws {
        let settingsBytes = try Data(contentsOf: store.url)
        XCTAssertTrue(history.append(.init(raw: "PRIVATE_SAVED_TEXT")))
        let historyBytes = try Data(contentsOf: history.url)
        let reads = backend.reads, statuses = backend.statuses
        _ = record(); hub.prepareDiagnostics()
        let frozen = try XCTUnwrap(hub.diagnosticReview)
        _ = record()
        selected = nil; hub.exportDiagnostics()
        XCTAssertTrue(writes.isEmpty); XCTAssertEqual(hub.diagnosticReview, frozen)
        selected = root.appendingPathComponent("export.json"); failWrite = true; hub.exportDiagnostics()
        XCTAssertTrue(writes.isEmpty); XCTAssertEqual(hub.diagnosticReview, frozen)
        XCTAssertFalse(hub.diagnosticMessage!.contains("PRIVATE_"))
        hub.diagnosticPanel = { [unowned self] _ in _ = self.record(); return self.selected }
        failWrite = false; hub.exportDiagnostics()
        XCTAssertEqual(writes, [frozen]); XCTAssertNil(hub.diagnosticReview)
        XCTAssertEqual(try Data(contentsOf: store.url), settingsBytes); XCTAssertEqual(try Data(contentsOf: history.url), historyBytes)
        XCTAssertEqual(backend.reads, reads); XCTAssertEqual(backend.statuses, statuses)
        XCTAssertFalse(store.load().historyEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected!.path), "The injected writer only records bytes")
    }

    func testActualHubActionProtectsFilesResolvedDanglingAndOutwardRecordingAliases() async throws {
        _ = record(); hub.prepareDiagnostics()
        let settingsAlias = root.appendingPathComponent("settings-alias.json")
        try FileManager.default.createSymbolicLink(at: settingsAlias, withDestinationURL: store.url)
        let outside = root.appendingPathComponent("outside.json")
        try Data("PRIVATE_AUDIO".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: recordings.directory.appendingPathComponent("live.wav"), withDestinationURL: outside)
        let recordingAlias = root.appendingPathComponent("recordings-alias")
        try FileManager.default.createSymbolicLink(at: recordingAlias, withDestinationURL: recordings.directory)
        let missingSettings = root.appendingPathComponent("not-created.json")
        let dangling = root.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missingSettings)
        let otherStore = SettingsStore(url: dangling, credentials: store.credentials)
        let otherHub = HubModel(store: otherStore, history: history, recordings: recordings, diagnostics: diagnostics)
        otherHub.diagnosticPanel = { _ in missingSettings }; otherHub.diagnosticWriter = { _, _ in XCTFail("Dangling settings alias must be protected") }
        otherHub.prepareDiagnostics(); otherHub.exportDiagnostics()
        XCTAssertNotNil(otherHub.diagnosticReview)
        for url in [store.url, history.url, settingsAlias, recordings.directory.appendingPathComponent("new.json"), recordingAlias.appendingPathComponent("nested/new.json"), outside, root.appendingPathComponent("wrong.txt")] {
            selected = url; hub.exportDiagnostics()
            XCTAssertTrue(writes.isEmpty); XCTAssertNotNil(hub.diagnosticReview)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("PRIVATE_AUDIO".utf8))
    }

    @MainActor func testIndependentRetryAndRecoveryOriginsStayPreviewOnly() async throws {
        XCTAssertTrue(history.append(.init(raw: "PRIVATE_SAVED_TRANSCRIPT")))
        let id = try XCTUnwrap(history.entries.first?.id)
        hub.prepareHistoryRetry(id)
        await hub.startHistoryRetry(id)
        XCTAssertNotNil(hub.historyRetries[id]?.proposed)
        let retryID = try XCTUnwrap(hub.historyRetries[id]?.operation.id)
        let url = try XCTUnwrap(recordings.stash([Float](repeating: 0.2, count: 8000), settings: store))
        recordings.resolve(url, transcript: nil, secure: false)
        var task: Task<Void, Never>?
        hub.onRecoveryTranscribe = { [unowned self] lease, request, done in
            task = RecoveryTranscription.enqueue(previous: nil, recordings: self.recordings, lease: lease, request: request,
                authorize: { self.recordings.refreshPolicy(from: self.store) }, load: { request in
                    try await RecoveryTranscription.acquire(request: request, operation: lease.operation,
                        snapshot: { (nil, nil) }, verify: { _ in }, load: { _ in DiagnosticHubRecognition() })
                }, done: done)
        }
        hub.transcribeRecovery(url)
        await task?.value
        XCTAssertNotNil(hub.recoveryPreview?.entry)
        let records = diagnostics.snapshot().records
        XCTAssertEqual(records.map(\.origin), [.historyRetry, .recovery])
        XCTAssertEqual(records.first?.id, retryID)
        XCTAssertNotEqual(records.first?.id, records.last?.id)
        XCTAssertEqual(records.first?.providerOutcome, .returned)
        XCTAssertEqual(records.last?.asr, .text)
        XCTAssertTrue(records.allSatisfy { $0.delivery == .notAttempted && $0.reason == .previewOnly && $0.operationFinished })
        hub.prepareDiagnostics(); hub.exportDiagnostics()
        try assertPrivateValuesAbsent(try XCTUnwrap(writes.last))
        // Explicit discard of one origin never invalidates another's preview.
        hub.discardHistoryRetry(id); XCTAssertNotNil(hub.recoveryPreview?.entry)
    }

    func testClearRemovesFrozenReviewAndActiveCallbacksCannotRestoreRecords() throws {
        let operation = record(), span = operation.diagnostics?.begin(.asr)
        hub.prepareDiagnostics(); XCTAssertNotNil(hub.diagnosticReview)
        hub.clearDiagnostics(); operation.diagnostics?.receipt(); span?.end(); operation.finish()
        XCTAssertNil(hub.diagnosticReview); XCTAssertTrue(diagnostics.snapshot().records.isEmpty)
        hub.exportDiagnostics(); XCTAssertEqual(panelCalls, 0)
        XCTAssertTrue(history.entries.isEmpty)
        // This is also the action used by applicationWillTerminate.
        hub.prepareDiagnostics(); hub.exportDiagnostics()
        try assertPrivateValuesAbsent(try XCTUnwrap(writes.last))
    }
}

extension HubDiagnosticsTests {
    func testClipboardLateRealHandleUpdatesLiveRecordButExportsExactFrozenReviewedBytes() throws {
        let board = ExperimentBoard()
        board.contents = [ExperimentItem([.init("PRIVATE_UTI"): Data("PRIVATE_SNAPSHOT".utf8)])]
        var time = 100.0, timers: [(Double, () -> Void)] = [], notices: [() -> Void] = []
        let delivery = ClipboardDelivery(board: board, now: { time }, schedule: { delay, action in
            timers.append((time + delay, action)); return {}
        }, enqueue: { notices.append($0) })
        let operation = record()
        XCTAssertTrue(DiagnosticDispatch.paste(diagnostics: operation.diagnostics) {
            delivery.paste("PRIVATE_PREPARED", mode: .observableRequests, diagnostics: operation.diagnostics) {}
        })
        operation.finish(); hub.prepareDiagnostics()
        let frozen = try XCTUnwrap(hub.diagnosticReview)
        let item = board.contents[0]
        time = 100.1; item.request(); notices.forEach { $0() }; notices = []
        XCTAssertEqual(diagnostics.snapshot().records[0].clipboard?.requests, 1)
        XCTAssertEqual(diagnostics.snapshot().records[0].delivery, .postedUnverified)
        XCTAssertEqual(hub.diagnosticReview, frozen)
        hub.exportDiagnostics(); XCTAssertEqual(writes, [frozen])
        time = timers.last!.0; timers.last!.1()
        let live = try diagnostics.snapshot().encoded()
        XCTAssertNotEqual(frozen, live)
        try assertPrivateValuesAbsent(live); try assertPrivateValuesAbsent(frozen)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: live) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let clipboard = try XCTUnwrap(records[0]["clipboard"] as? [String: Any])
        let allowed: Set<String> = ["mode", "floorMs", "quietMs", "maximumMs", "requestedDelayMs", "requests", "ignored", "supplyFailures", "firstRequestMs", "elapsedMs", "end", "restore", "receipt"]
        XCTAssertEqual(Set(clipboard.keys), allowed)
        XCTAssertEqual(clipboard["restore"] as? String, "restored")
        XCTAssertEqual(clipboard["receipt"] as? String, "observed")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        // An older reader's existing-key projection is unchanged by addition.
        var old = records[0]; old.removeValue(forKey: "clipboard")
        XCTAssertNil(try JSONDecoder().decode(DiagnosticRecord.self, from: JSONSerialization.data(withJSONObject: old)).clipboard)
        hub.clearDiagnostics(); item.request(); notices.forEach { $0() }
        XCTAssertTrue(diagnostics.snapshot().records.isEmpty)
        XCTAssertEqual(writes, [frozen]); XCTAssertFalse(delivery.isRestorePending)
    }
}


extension HubDiagnosticsTests {
    @MainActor func testSavedOriginalHardlinkGuardPrecedesActualInjectedWriter() async throws {
        let rig = try SavedImportRig(), original = try await rig.run()
        let alias = rig.root.appendingPathComponent("original-hardlink.json")
        XCTAssertEqual(link(original.path,alias.path),0)
        rig.hub.diagnosticWriter = { bytes,_ in rig.written.append(bytes) }
        rig.hub.diagnosticPanel = { _ in alias }; rig.hub.prepareDiagnostics(); rig.hub.exportDiagnostics()
        XCTAssertTrue(rig.written.isEmpty)
        rig.hub.diagnosticPanel = { _ in rig.root.appendingPathComponent("safe.json") }
        rig.hub.exportDiagnostics(); XCTAssertEqual(rig.written.count,1)
        XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
}
