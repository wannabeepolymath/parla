import XCTest
import ParlaCore
@testable import Parla

private final class RecoveryClient: RecognitionClient {
    var calls = 0
    var language: String?
    var prompt: String?
    var result: String? = "raw recovered text"
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        calls += 1; self.language = language; prompt = initialPrompt
        return shouldAbort?() == true ? nil : result
    }
}
private final class FakeRecoveryPlayer: RecoveryAudioPlaying {
    var played: [URL] = []
    var stops = 0
    var error = false
    var finished: ((Bool) -> Void)?
    func play(url: URL, finished: @escaping (Bool) -> Void) throws {
        if error { throw RecordingStore.Failure("Fake player failed.") }
        played.append(url); self.finished = finished
    }
    func stop() { stops += 1; finished = nil }
    func finish(_ success: Bool) { let done = finished; finished = nil; done?(success) }
}
private actor RecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class BlockingRecoveryClient: RecognitionClient, @unchecked Sendable {
    let entered = XCTestExpectation(description: "recovery native entered")
    let exit = RecognitionTestLatch()
    private let lock = NSLock()
    private var abort: (() -> Bool)?
    var shouldAbort: Bool { lock.withLock { abort?() == true } }
    func transcribe(_ samples: [Float], initialPrompt: String?, language: String?, shouldAbort: (() -> Bool)?) async -> String? {
        lock.withLock { abort = shouldAbort }; entered.fulfill(); await exit.wait()
        return "ignored cancellation late result"
    }
}

private final class RecoveryRetryRequest: CleanupProviding, @unchecked Sendable {
    let entered = XCTestExpectation(description: "independent text retry entered")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }; entered.fulfill()
        }
    }
    func complete() { lock.withLock { continuation?.resume(returning: "independent retry result"); continuation = nil } }
}

final class HubAudioRecoveryTests: XCTestCase {
    private var root: URL!
    private var settings: SettingsStore!
    private var recordings: RecordingStore!
    private var history: HistoryStore!
    private var hub: HubModel!
    private var player: FakeRecoveryPlayer!
    private var client: RecoveryClient!
    private var queue: Task<Void, Never>?
    private var loads: [RecognitionRequest] = []
    private var copies: [String] = []
    private var failWrite = false
    private var forbidden = 0
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-hub-recovery-2c4-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try recordWave4BFixture(root, "created")
        settings = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        var s = Settings(); s.whisperModelPath = "/fake/old.bin"; s.language = "hi"; s.dictionary = ["Parla"]
        try settings.save(s)
        recordings = RecordingStore(directory: root.appendingPathComponent("recordings"), keepAll: false, requireValidatedPolicy: true)
        history = HistoryStore(url: root.appendingPathComponent("history.json"), persistence: .init(writeAtomically: { [unowned self] data, url in
            if self.failWrite { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }))
        hub = HubModel(store: settings, history: history, clipboard: { [unowned self] in self.copies.append($0) }, recordings: recordings)
        player = FakeRecoveryPlayer(); client = RecoveryClient()
        hub.recoveryPlayback.factory = { [unowned self] in self.player }
        hub.onDownloadModel = { [unowned self] _ in self.forbidden += 1 }
        hub.onTryoutStart = { [unowned self] in self.forbidden += 1; return nil }
        hub.onTryoutStop = { [unowned self] _ in self.forbidden += 1 }
        hub.retryFactory = { [unowned self] _, _, _, _ in self.forbidden += 1; throw RecordingStore.Failure("No provider") }
        bindQueue()
        hub.refresh()
    }
    override func tearDownWithError() throws {
        XCTAssertEqual(forbidden, 0)
        hub.stopRecoveryPlayback(); hub.flushPendingSave(); hub = nil
        queue = nil; client = nil; player = nil; recordings = nil; history = nil; settings = nil
        try FileManager.default.removeItem(at: root)
        try recordWave4BFixture(root, "removed")
    }
    private func bindQueue(load: ((RecognitionRequest) async throws -> RecognitionHandle)? = nil) {
        hub.onRecoveryTranscribe = { [unowned self] lease, request, done in
            self.queue = RecoveryTranscription.enqueue(previous: self.queue, recordings: self.recordings,
                lease: lease, request: request, authorize: { [unowned self] in
                    return self.recordings.refreshPolicy(from: self.settings)
                }, load: load ?? { [unowned self] request in
                    self.loads.append(request)
                    return try RecognitionHandle(request: request) { _ in self.client }
                }, done: done)
        }
    }
    private func failed(silent: Bool = false, short: Bool = false) throws -> URL {
        let samples = silent ? [Float](repeating: 0, count: 8_000) : (0..<(short ? 1_000 : 8_000)).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let url = try XCTUnwrap(recordings.stash(samples, settings: settings))
        recordings.resolve(url, transcript: nil, secure: false)
        return url
    }
    @MainActor func testRealDefaultFactoryRecoveryQueueAndFloorBeforeNativeAdmission() async throws {
        let probe = FoundationNativeProbe(), factory = probe.factory()
        bindQueue(load: { request in
            try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory)
        })
        let silent = try failed(silent: true)
        hub.transcribeRecovery(silent); await queue?.value
        XCTAssertTrue(probe.paths.isEmpty); XCTAssertEqual(probe.admissions, 0)
        let url = try failed()
        hub.transcribeRecovery(url); await queue?.value
        XCTAssertEqual(hub.recoveryPreview?.entry?.raw, "native original")
        XCTAssertEqual(probe.paths, ["/fake/old.bin"]); XCTAssertEqual(probe.calls.count, 1)
        XCTAssertEqual(probe.calls.first?.language, "hi"); XCTAssertEqual(probe.calls.first?.prompt, "Parla")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(history.entries.isEmpty); XCTAssertEqual(probe.releases, 1)
        hub.copyRecovery(); XCTAssertEqual(copies, ["native original"])
        hub.saveRecovery(); XCTAssertEqual(history.entries.first?.raw, "native original")
        XCTAssertEqual(probe.calls.count, 1)
    }
    @MainActor func testProductionQueueHubSuccessDisposesBeforeSaveCopyAndDiskOnlyRetry() async throws {
        let url = try failed(); failWrite = true
        hub.transcribeRecovery(url); await queue?.value
        XCTAssertEqual(client.calls, 1); XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(client.language, "hi"); XCTAssertTrue(client.prompt?.contains("Parla") == true)
        XCTAssertEqual(hub.recoveryPreview?.entry?.raw, "raw recovered text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertTrue(history.entries.isEmpty)
        hub.copyRecovery(); XCTAssertEqual(copies, ["raw recovered text"])
        hub.saveRecovery(); XCTAssertEqual(hub.recoveryPreview?.saveFailed, true)
        let id = try XCTUnwrap(hub.recoveryPreview?.entry?.id)
        XCTAssertEqual(history.pendingEntries.map(\.id), [id])
        failWrite = false; hub.saveRecovery(); hub.saveRecovery()
        XCTAssertEqual(history.entries.map(\.id), [id]); XCTAssertTrue(history.pendingEntries.isEmpty)
        XCTAssertNil(history.entries.first?.cleaned); XCTAssertNil(history.entries.first?.operation)
        XCTAssertNil(history.entries.first?.appName); XCTAssertNil(history.entries.first?.metrics?.cleanupModel)
        XCTAssertEqual(client.calls, 1); XCTAssertEqual(hub.recoveryPreview?.saved, true)
    }
    @MainActor func testHistoryOffPreviewThenEnableSavesSameResultWithoutASR() async throws {
        var s = settings.load(); s.historyEnabled = false; try settings.save(s); hub.refresh()
        hub.transcribeRecovery(try failed()); await queue?.value
        hub.copyRecovery(); hub.saveRecovery()
        XCTAssertEqual(copies.count, 1); XCTAssertTrue(history.entries.isEmpty); XCTAssertTrue(history.pendingEntries.isEmpty)
        s.historyEnabled = true; try settings.save(s); hub.refresh(); hub.saveRecovery()
        XCTAssertEqual(history.entries.count, 1); XCTAssertEqual(client.calls, 1)
    }
    @MainActor func testFailedASRRetainsAudioAndReleasesOwnership() async throws {
        client.result = nil; let url = try failed()
        hub.transcribeRecovery(url); await queue?.value
        XCTAssertNotNil(hub.recoveryPreview?.error); XCTAssertNil(hub.recoveryPreview?.entry)
        XCTAssertEqual(client.calls, 1); XCTAssertEqual(recordings.descriptors().map(\.url), [url])
        hub.saveRecovery(); XCTAssertTrue(history.entries.isEmpty)
    }
    @MainActor func testSilentShortAndMissingNeverAcquireModel() async throws {
        for url in [try failed(silent: true), try failed(short: true)] {
            hub.transcribeRecovery(url); await queue?.value
            XCTAssertNotNil(hub.recoveryPreview?.error); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let missing = try failed(); try FileManager.default.removeItem(at: missing)
        hub.transcribeRecovery(missing)
        XCTAssertTrue(loads.isEmpty); XCTAssertEqual(client.calls, 0)
    }
    @MainActor func testMissingRequestedModelShowsFailureWithoutFallback() async throws {
        bindQueue(load: { [unowned self] request in
            self.loads.append(request); throw RecordingStore.Failure("Requested local model missing.")
        })
        let url = try failed(); hub.transcribeRecovery(url); await queue?.value
        XCTAssertEqual(loads.map(\.modelPath), ["/fake/old.bin"]); XCTAssertEqual(client.calls, 0)
        XCTAssertEqual(hub.recoveryPreview?.error, "Requested local model missing.")
        XCTAssertEqual(recordings.descriptors().map(\.url), [url])
    }
    @MainActor func testQueueFreezesOldAndNewGlobalRequestAndExactAudioPath() async throws {
        let gate = RecoveryGate(); queue = Task { await gate.wait() }
        let old = try failed(), other = try failed()
        hub.transcribeRecovery(old)
        XCTAssertTrue(recordings.recordings().contains(other)); XCTAssertFalse(recordings.recordings().contains(old))
        var s = settings.load(); s.whisperModelPath = "/fake/new.bin"; s.language = "en"; s.dictionary = ["Updated"]
        try settings.save(s); hub.refresh()
        await gate.release(); await queue?.value
        XCTAssertEqual(loads.first?.modelPath, "/fake/old.bin"); XCTAssertEqual(client.language, "hi")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        hub.transcribeRecovery(other); await queue?.value
        XCTAssertEqual(loads.map(\.modelPath), ["/fake/old.bin", "/fake/new.bin"])
        XCTAssertEqual(client.language, "en"); XCTAssertTrue(client.prompt?.contains("Updated") == true)
    }
    @MainActor func testQueuedMissingChangedExpiredAndSettingsErrorsStopBeforeModel() async throws {
        for variant in 0..<4 {
            let gate = RecoveryGate(); queue = Task { await gate.wait() }
            let url = try failed(); hub.transcribeRecovery(url)
            switch variant {
            case 0: try FileManager.default.removeItem(at: url)
            case 1: try RecordingStore.writeWAV([Float](repeating: 0.2, count: 7_000), to: url)
            case 2: try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: url.path)
            default: try Data("invalid".utf8).write(to: settings.url)
            }
            await gate.release(); await queue?.value
            XCTAssertTrue(loads.isEmpty); XCTAssertEqual(client.calls, 0); XCTAssertNotNil(hub.recoveryPreview?.error)
            if variant == 3 { try JSONEncoder().encode(Settings()).write(to: settings.url); hub.refresh() }
        }
    }
    @MainActor func testUseTimeChangeAfterAcquisitionAndRevocationPreventsASR() async throws {
        let url = try failed()
        bindQueue(load: { [unowned self] request in
            self.recordings.resolve(url, transcript: nil, secure: true)
            return try RecognitionHandle(request: request) { _ in self.client }
        })
        hub.transcribeRecovery(url); await queue?.value
        XCTAssertEqual(client.calls, 0); XCTAssertNotNil(hub.recoveryPreview?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testPlaybackNeverAutomaticAndStopsOnCompletionErrorStopDeleteAndWindowClose() throws {
        let url = try failed(); hub.refreshRecovery()
        XCTAssertTrue(player.played.isEmpty)
        hub.playRecovery(url); XCTAssertEqual(player.played, [url]); XCTAssertEqual(recordings.clear().busy, 1)
        player.finish(true); XCTAssertNil(hub.playingRecordingID); XCTAssertEqual(recordings.descriptors().count, 1)
        hub.playRecovery(url); player.finish(false); XCTAssertTrue(hub.recoveryMessage?.contains("Couldn’t play") == true)
        hub.playRecovery(url); hub.stopRecoveryPlayback(); XCTAssertNil(hub.playingRecordingID)
        hub.playRecovery(url)
        HubWindowController(model: hub).windowWillClose(Notification(name: Notification.Name("test")))
        XCTAssertNil(hub.playingRecordingID); XCTAssertEqual(recordings.descriptors().count, 1)
        player.error = true; hub.playRecovery(url); XCTAssertNil(hub.playingRecordingID)
        XCTAssertEqual(recordings.descriptors().count, 1)
        player.error = false; hub.playRecovery(url); hub.deleteRecovery(url)
        XCTAssertNil(hub.playingRecordingID); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testSecurePurgeStopsOwnedPlaybackBeforeRemovalAndBulkClearSkipsOtherOwner() async throws {
        let url = try failed(); hub.playRecovery(url)
        recordings.resolve(url, transcript: nil, secure: true)
        XCTAssertNil(hub.recoveryPlayback.id); XCTAssertGreaterThan(player.stops, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let active = try failed(), inactive = try failed()
        let lease = try recordings.acquire(active); hub.playRecovery(inactive); hub.clearRecovery()
        XCTAssertTrue(hub.recoveryMessage?.contains("1 in use") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactive.path)); recordings.release(lease)
    }
    @MainActor func testInvalidSettingsDisallowRequestAndSaveButPreservePreviewCopy() async throws {
        let url = try failed(); hub.transcribeRecovery(url); await queue?.value
        try Data("bad settings".utf8).write(to: settings.url); hub.refresh()
        hub.saveRecovery(); hub.copyRecovery()
        XCTAssertEqual(copies, ["raw recovered text"]); XCTAssertTrue(history.entries.isEmpty)
        let before = client.calls
        hub.transcribeRecovery(url); XCTAssertEqual(client.calls, before)
        XCTAssertNotNil(hub.recoveryPolicyStatus); XCTAssertNotNil(hub.loadError)
        XCTAssertNotNil(hub.recoveryPreview?.entry)
    }
    func testPlaybackOwnerDeinitAndExplicitStopReleaseWithoutRealPlayer() async throws {
        let url = try failed()
        var owner: RecoveryPlayback? = RecoveryPlayback(); owner?.factory = { self.player }
        try owner?.start(url: url, store: recordings, now: Date(), finished: { _ in })
        XCTAssertTrue(recordings.recordings().isEmpty)
        owner = nil; XCTAssertEqual(recordings.recordings(), [url])
    }
    @MainActor func testExternalCorruptHistoryCannotBeOverwrittenByRecoverySave() async throws {
        hub.transcribeRecovery(try failed()); await queue?.value
        let bad = Data("broken history".utf8); try bad.write(to: history.url)
        hub.saveRecovery()
        XCTAssertEqual(try Data(contentsOf: history.url), bad)
        XCTAssertTrue(history.loadBlocked); XCTAssertNotNil(hub.recoveryPreview?.entry)
        XCTAssertEqual(client.calls, 1)
    }
    @MainActor func testPendingPolicyEditCannotOverwriteExternallyBrokenSettings() async throws {
        let audio = try failed()
        let valid = try Data(contentsOf: settings.url)
        hub.settings.recoveryAudioEnabled = false
        let broken = Data("external broken settings".utf8); try broken.write(to: settings.url)
        hub.refreshRecovery()
        XCTAssertEqual(try Data(contentsOf: settings.url), broken)
        XCTAssertNotNil(hub.loadError); XCTAssertNotNil(hub.recoveryPolicyStatus)
        XCTAssertNotNil(hub.saveError)
        hub.refresh(); XCTAssertNotNil(hub.saveError) // invalid reload cannot resolve the error
        hub.transcribeRecovery(audio); XCTAssertEqual(client.calls, 0)

        // A full reload replaces the refused edit with authoritative disk settings.
        try valid.write(to: settings.url)
        hub.onSaved = { XCTFail("Repair/reload must not require another settings write") }
        hub.refresh()
        XCTAssertNil(hub.loadError); XCTAssertNil(hub.saveError)
        XCTAssertTrue(hub.settings.recoveryAudioEnabled)
        hub.transcribeRecovery(audio); await queue?.value
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(hub.recoveryPreview?.entry?.raw, "raw recovered text")
        hub.saveRecovery()
        XCTAssertEqual(history.entries.map(\.raw), ["raw recovered text"])
        XCTAssertEqual(hub.recoveryPreview?.saved, true)
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(try Data(contentsOf: settings.url), valid)
    }

    func testHistoryDeleteCountAndClearDoNotInferAnAudioLink() async throws {
        let audio = try failed()
        history.applyCountLimit(1)
        let a = HistoryEntry(raw: "same"), b = HistoryEntry(raw: "same")
        history.append(a); history.append(b); hub.deleteHistory(b.id); hub.clearHistory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(recordings.policy?.days, 7); XCTAssertEqual(recordings.policy?.enabled, true)
    }

    @MainActor func testQueueAppliesNewValidLifetimeBeforeReadingOrModelAcquisition() async throws {
        let url = try failed()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 86_400)], ofItemAtPath: url.path)
        let gate = RecoveryGate(); queue = Task { await gate.wait() }
        hub.transcribeRecovery(url)
        var shorter = settings.load(); shorter.recoveryAudioDays = 1; try settings.save(shorter)
        await gate.release(); await queue?.value
        XCTAssertTrue(loads.isEmpty); XCTAssertEqual(client.calls, 0)
        XCTAssertNil(hub.recoveryPreview?.entry); XCTAssertNotNil(hub.recoveryPreview?.error)
        XCTAssertEqual(recordings.policy?.days, 1)
    }

    @MainActor func testCancelRecoveryReleasesLeaseBeforeAbortAndRetainsSourceSuppressingLateSave() async throws {
        let gate = RecoveryGate(), entered = expectation(description: "acquisition entered"), aborted = expectation(description: "acquisition cancelled")
        var lease: RecordingStore.Lease?
        var verifications = 0, constructions = 0
        let url = try failed()
        hub.onRecoveryTranscribe = { [unowned self] current, request, done in
            lease = current
            self.queue = RecoveryTranscription.enqueue(previous: self.queue, recordings: self.recordings,
                lease: current, request: request, authorize: { true }, load: { request in
                    try await RecoveryTranscription.acquire(request: request, operation: current.operation, snapshot: {
                        await withTaskCancellationHandler(operation: {
                            entered.fulfill(); await gate.wait()
                        }, onCancel: {
                            XCTAssertTrue(current.operation.shouldAbort)
                            XCTAssertFalse(self.recordings.isActive(current), "lease release must precede abort")
                            aborted.fulfill()
                        })
                        return (nil, nil)
                    }, verify: { _ in verifications += 1 }, load: { _ in
                        constructions += 1
                        return self.client
                    })
                }, done: done)
        }
        hub.transcribeRecovery(url)
        await fulfillment(of: [entered], timeout: 2)
        let token = try XCTUnwrap(hub.recoveryPreview?.token)
        hub.discardRecovery(); hub.discardRecovery()
        XCTAssertNil(hub.recoveryPreview); XCTAssertFalse(recordings.isActive(try XCTUnwrap(lease)))
        await fulfillment(of: [aborted], timeout: 2)
        hub.transcribeRecovery(url) // exiting request must not be abandoned by re-preparation
        XCTAssertNil(hub.recoveryPreview)
        await gate.release(); await queue?.value
        hub.saveRecovery()
        XCTAssertTrue(history.entries.isEmpty); XCTAssertNil(hub.recoveryPreview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)); XCTAssertEqual(client.calls, 0)
        XCTAssertTrue(lease!.operation.hasExited)
        XCTAssertEqual(verifications, 0); XCTAssertEqual(constructions, 0)
        // The same source becomes explicitly usable again only after exit.
        bindQueue(); hub.transcribeRecovery(url); await queue?.value
        XCTAssertNotEqual(hub.recoveryPreview?.token, token); XCTAssertNotNil(hub.recoveryPreview?.entry)
    }

    @MainActor func testRecoveryAcquisitionRevokedDuringVerificationSkipsNativeConstruction() async throws {
        let operation = PendingOperation(name: "Recovery verification")
        var verifications = 0, constructions = 0
        do {
            _ = try await RecoveryTranscription.acquire(request: RecognitionRequest(settings: settings.load()),
                operation: operation, snapshot: { (nil, nil) }, verify: { _ in
                    verifications += 1
                    operation.revoke()
                }, load: { _ in
                    constructions += 1
                    return self.client
                })
            XCTFail("Revoked acquisition must throw")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected acquisition error: \(error)") }
        XCTAssertEqual(verifications, 1); XCTAssertEqual(constructions, 0)
    }

    @MainActor func testRecoveryNativeCancelDoesNotCancelConcurrentRetryOrPlaybackAndNoLatePreview() async throws {
        var current = settings.load(); current.cleanup.provider = "openai-compatible"
        current.cleanup.baseURL = "https://example.test"; current.cleanup.model = "fake"
        try settings.save(current); hub.refresh()
        let row = HistoryEntry(raw: "original text"); XCTAssertTrue(history.append(row))
        let retry = RecoveryRetryRequest(); hub.retryFactory = { _, _, _, _ in retry }
        hub.prepareHistoryRetry(row.id)
        let retryTask = Task { await hub.startHistoryRetry(row.id) }
        await fulfillment(of: [retry.entered], timeout: 2)
        let playing = try failed(), recovering = try failed()
        hub.playRecovery(playing)
        let native = BlockingRecoveryClient()
        bindQueue(load: { request in try RecognitionHandle(request: request) { _ in native } })
        hub.transcribeRecovery(recovering)
        await fulfillment(of: [native.entered], timeout: 2)
        hub.discardRecovery()
        XCTAssertTrue(native.shouldAbort)
        XCTAssertEqual(hub.playingRecordingID, playing.lastPathComponent)
        XCTAssertFalse(hub.historyRetries[row.id]!.operation.shouldAbort)
        retry.complete(); await retryTask.value; hub.saveHistoryRetry(row.id)
        native.exit.signal(); await queue?.value
        hub.saveRecovery()
        XCTAssertNil(hub.recoveryPreview); XCTAssertTrue(FileManager.default.fileExists(atPath: recovering.path))
        XCTAssertEqual(history.entries.count, 1); XCTAssertEqual(history.entries.first?.best, "independent retry result")
        XCTAssertEqual(hub.playingRecordingID, playing.lastPathComponent)
    }

}

extension HubAudioRecoveryTests {
    @MainActor func testSafeStartRefusalMapsBeforeGenericCatchCompletesLeaseAndPreservesSource() async throws {
        let p = try PreparationAppRig()
        p.owner.core.revokeDraft()
        bindQueue(load: { request in try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: p.factory) })
        let url = try failed(), before = try Data(contentsOf: url)
        hub.transcribeRecovery(url); await queue?.value
        XCTAssertNil(hub.recoveryLease); XCTAssertEqual(hub.recoveryOperation?.hasExited, true)
        XCTAssertEqual(hub.recoveryPreview?.error, PreparationRefusal.consentRequired.description)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(p.probe.paths.isEmpty); XCTAssertTrue(history.entries.isEmpty)
        try await p.close()
    }
}
