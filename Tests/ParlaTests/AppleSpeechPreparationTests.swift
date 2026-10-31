import Foundation
import Combine
import XCTest
@testable import ParlaCore
@testable import Parla

final class AppleRecordMemory: PreparationStorage {
    var data: Data?, writes = 0, fail = false
    func read() throws -> Data? { data }
    func replace(_ data: Data, authorized: () -> Bool) throws {
        guard !fail, authorized() else { throw AppleSpeechRefusal.trackingUnavailable }; self.data = data; writes += 1
    }
    func quarantine() throws { throw AppleSpeechRefusal.trackingUnavailable }
    func reset(_ data: Data) throws { throw AppleSpeechRefusal.trackingUnavailable }
}
final class AppleInstallFake: AppleSpeechInstallation {
    var downloads = 0, cancels = 0
    var hold = false, fail = false
    let entered = XCTestExpectation(description: "installation held")
    private let latch = RecognitionTestLatch()
    func download(progress: @escaping (AppleSpeechProgress) -> Void) async throws {
        downloads += 1
        for fraction in [Double.nan, -1, 0.2, 0.7, 1.5] { progress(.init(fraction: fraction, cancellable: true)) }
        if hold { entered.fulfill(); await latch.wait() }
        if fail { throw AppleSpeechRefusal.native }
    }
    func cancel() { cancels += 1 }
    func finish() { latch.signal() }
}
@MainActor final class AppleOwnerRig {
    let memory = AppleRecordMemory(), installation = AppleInstallFake()
    var reserved = Set<String>(), capacity = 4
    var installed = true, supported = true, available = true
    var reserves = 0, observations = 0, requests = 0, releases = 0
    var nilRequest = false, reserveResult = true, postInstalled = true
    var chain: Task<Void, Never>?
    var clock = AppleSpeechClock()
    var reserveHold = false
    let reserveEntered = XCTestExpectation(description: "reserve held")
    let reserveLatch = RecognitionTestLatch()
    var installationHold = false
    let installationEntered = XCTestExpectation(description: "installation request held")
    let installationLatch = RecognitionTestLatch()
    var saved: Settings
    lazy var owner: AppleSpeechPreparation = {
        let result = AppleSpeechPreparation(assets: AppleSpeechAssets(observe: { [self] _ in
            observations += 1
            return .init(available: available, supported: supported, installedLocale: installed,
                         moduleInstalled: installed, reserved: reserved, capacity: capacity)
        }, reserve: { [self] locale in
            XCTAssertNotNil(memory.data, "intent must precede mutation")
            let record = try JSONDecoder().decode(AppleSpeechReservationRecord.self, from: memory.data!)
            XCTAssertTrue(record.entries.contains { $0.locale == locale && $0.state == .intent })
            reserves += 1
            if reserveHold { reserveEntered.fulfill(); await reserveLatch.wait() }
            reserved.insert(locale); return reserveResult
        }, installation: { [self] _ in
            requests += 1
            if installationHold { installationEntered.fulfill(); await installationLatch.wait() }
            installed = postInstalled; return nilRequest ? nil : installation
        },
        release: { [self] locale in releases += 1; reserved.remove(locale); return true }), clock: clock, storage: { [self] in memory })
        result.enqueue = { [weak self] operation, work, finished in
            guard let self else { return }
            chain = PendingOperationQueue.enqueue(previous: chain, operation: operation, completes: true, work: work, finished: finished)
        }
        return result
    }()
    init() { var s = Settings(); s.recognitionEngine = .appleSpeech; s.appleSpeechLocale = "en-US"; saved = s }
    func configure() { owner.configure(saved) }
    func wait() async { var previous = chain; while true { await previous?.value; if previous == chain { return }; previous = chain } }
    func prepare(_ locale: String = "en-US") async { owner.act(.prepare, locale: locale, token: owner.snapshot.token); await wait() }
    func factory(_ native: AppleOriginSession) -> RecognitionFactory {
        RecognitionFactory(appleBottom: .init(available: {}, session: { _ in native }), appleInstalledUse: { [self] locale, operation in
            try await owner.installedUse(locale, operation: operation)
        }, native: { _, _ in XCTFail("Whisper native"); throw AppleSpeechRefusal.native }, runtime: { XCTFail("Whisper runtime"); return .init(nativeVersion: "", buildScope: "") }, metadata: { _ in XCTFail("Whisper file scan"); return nil }, admit: { _, _ in XCTFail("Whisper admission") })
    }
}
private final class AppleOriginConverter: AppleSpeechConverter {
    let format = AppleSpeechFormat(rate: 16_000, channels: 1, bytesPerFrame: 4)
    var consumedSourceSamples = 0, ended = false
    let count: Int
    init(_ count: Int) { self.count = count }
    func next() throws -> AppleSpeechBuffer? {
        if consumedSourceSamples == count { ended = true; return nil }
        let n = min(16_000, count - consumedSourceSamples); consumedSourceSamples += n
        return .init(frames: n, bytes: n * 4, payload: NSObject())
    }
}
final class AppleOriginSession: AppleSpeechSession {
    let latch = RecognitionTestLatch()
    var calls = 0
    var text = "spoken original"
    func converter(samples: [Float]) async throws -> AppleSpeechConverter { calls += 1; return AppleOriginConverter(samples.count) }
    func collect(ready: @escaping () -> Void, _ emit: @escaping (AppleSpeechEvent) throws -> Void) async throws {
        ready()
        await latch.wait()
        try emit(.init(text: text, start: .init(0, 16_000), end: .init(4_000, 16_000), finalization: .init(4_000, 16_000)))
    }
    func analyze(_ input: AppleSpeechInput) async throws -> AppleSpeechTime? { while try input.next() != nil { }; return .init(input.frames, 16_000) }
    func finalize(through: AppleSpeechTime) async throws { latch.signal() }
    func cancelAndFinish() async { latch.signal() }
}
@MainActor final class AppleSpeechPreparationTests: XCTestCase {
    func testRealOwnerPrepareRecheckNilRequestAndUnknownOwnershipNeverRelease() async throws {
        for preexisting in [false, true] {
            let rig = AppleOwnerRig(); rig.nilRequest = true
            if preexisting { rig.reserved.insert("en-US"); rig.reserveResult = false }
            rig.configure(); await rig.wait()
            XCTAssertEqual(rig.reserves + rig.requests, 0)
            await rig.prepare()
            XCTAssertEqual(rig.owner.snapshot.phase, .ready); XCTAssertEqual(rig.requests, 1); XCTAssertEqual(rig.installation.downloads, 0)
            let lease = try await rig.owner.installedUse("en-US", operation: nil)
            rig.saved.recognitionEngine = .whisper; rig.configure(); await rig.wait()
            rig.owner.act(.release, locale: "en-US", token: rig.owner.snapshot.token); await rig.wait()
            XCTAssertEqual(rig.releases, 0); XCTAssertEqual(rig.owner.snapshot.refusal, .protectedReservation)
            lease.release()
            rig.owner.act(.release, locale: "en-US", token: rig.owner.snapshot.token); await rig.wait()
            XCTAssertEqual(rig.releases, preexisting ? 0 : 1)
            let mutation = rig.reserves + rig.requests + rig.releases
            rig.owner.recheck("en-US"); await rig.wait()
            XCTAssertEqual(rig.reserves + rig.requests + rig.releases, mutation)
        }
        let rig = AppleOwnerRig(); rig.nilRequest = true; rig.postInstalled = false; rig.configure(); await rig.wait(); await rig.prepare()
        XCTAssertEqual(rig.owner.snapshot.refusal, .assetsUnavailable)
        await recognitionAssertThrows(try await rig.owner.installedUse("en-US", operation: nil))
    }
    func testLedgerCrashIntentCorruptionPersistenceAndCapacityPreserveUnknown() async throws {
        let records = [Data("{".utf8), Data(repeating: 32, count: 16_385),
            try AppleSpeechReservationRecord(entries: [.init(locale: "en-US", state: .intent)]).encodedIntent()]
        for data in records {
            let rig = AppleOwnerRig(); rig.memory.data = data; rig.reserved = ["en-US"]
            rig.configure(); await rig.wait(); await rig.prepare()
            XCTAssertEqual(rig.owner.snapshot.refusal, .trackingUnavailable)
            XCTAssertEqual(rig.reserves + rig.requests + rig.releases, 0); XCTAssertEqual(rig.memory.data, data)
        }
        let rig = AppleOwnerRig(); rig.capacity = 1; rig.reserved = ["ja-JP"]; rig.configure(); await rig.wait(); await rig.prepare()
        XCTAssertEqual(rig.owner.snapshot.refusal, .capacity); XCTAssertEqual(rig.reserves, 0)
        let failed = AppleOwnerRig(); failed.memory.fail = true; failed.configure(); await failed.wait(); await failed.prepare()
        XCTAssertEqual(failed.owner.snapshot.refusal, .trackingUnavailable); XCTAssertEqual(failed.reserves, 0)
        let restarted = AppleOwnerRig()
        restarted.memory.data = try AppleSpeechReservationRecord(entries: [.init(locale: "en-US", state: .owned, prepared: true)]).encoded()
        restarted.reserved = ["en-US"]; restarted.configure(); await restarted.wait()
        XCTAssertEqual(restarted.owner.snapshot.phase, .ready); XCTAssertEqual(restarted.reserves + restarted.requests, 0)
    }
    func testNoncooperativePrepareCancelHoldsQueueAndShutdownUntilWorkerActuallyExits() async throws {
        let rig = AppleOwnerRig(); rig.installation.hold = true; rig.configure(); await rig.wait()
        rig.owner.act(.prepare, locale: "en-US", token: rig.owner.snapshot.token)
        await fulfillment(of: [rig.installation.entered], timeout: 3)
        let scans = rig.observations
        XCTAssertEqual(rig.owner.snapshot.phase, .downloading)
        var reply: Bool?, successor = 0
        rig.owner.beginShutdown(chain: { rig.chain }, reply: { reply = $0 })
        rig.chain = PendingOperationQueue.enqueue(previous: rig.chain, operation: PendingOperation(name: "successor"), completes: true) { successor += 1 }
        XCTAssertTrue(rig.owner.admissionClosed); XCTAssertTrue(rig.owner.hasWork)
        XCTAssertEqual(rig.owner.snapshot.phase, .stopping); XCTAssertNil(reply); XCTAssertEqual(successor, 0)
        XCTAssertEqual(rig.observations, scans)
        rig.installation.finish(); await rig.wait()
        // The owned drain follows the stable chain and replies once after real exit.
        for _ in 0..<10 where reply == nil { await Task.yield() }
        XCTAssertEqual(reply, true); XCTAssertEqual(successor, 1); XCTAssertEqual(rig.installation.cancels, 1)
        XCTAssertFalse(rig.owner.hasWork); XCTAssertNotEqual(rig.owner.snapshot.phase, .ready)
        rig.owner.cancelShutdown(); XCTAssertTrue(rig.owner.admissionClosed)
        rig.owner.deliberateEntry(); XCTAssertFalse(rig.owner.admissionClosed)
    }
    func testRevocationWhileAcquiringInstallationRequestNeverStartsDownload() async throws {
        for mode in ["cancel", "selection", "shutdown", "deadline"] {
            let rig = AppleOwnerRig(), watchdog = RecognitionTestLatch()
            let watchdogEntered = XCTestExpectation(description: "watchdog admitted")
            var now: TimeInterval = 100
            if mode == "deadline" {
                rig.clock = .init(now: { now }, wait: { delay in
                    if delay >= 179 { watchdogEntered.fulfill(); await watchdog.wait() }
                    else { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1e9)) }
                })
            }
            rig.configure(); await rig.wait(); rig.installationHold = true
            var phases: [AppleSpeechSnapshot.Phase] = []
            let observation = rig.owner.$snapshot.sink { phases.append($0.phase) }
            rig.owner.act(.prepare, locale: "en-US", token: rig.owner.snapshot.token)
            await fulfillment(of: [rig.installationEntered], timeout: 3)
            let shutdown = XCTestExpectation(description: "shutdown drained")
            switch mode {
            case "selection": rig.saved.appleSpeechLocale = "ja-JP"; rig.configure()
            case "shutdown": rig.owner.beginShutdown(chain: { rig.chain }, reply: { _ in shutdown.fulfill() })
            case "deadline":
                await fulfillment(of: [watchdogEntered], timeout: 3)
                now = 280; watchdog.signal()
            default: rig.owner.cancel(token: rig.owner.snapshot.token)
            }
            XCTAssertTrue(rig.owner.hasWork); XCTAssertEqual(rig.installation.downloads, 0)
            rig.installationLatch.signal(); await rig.wait()
            if mode == "shutdown" { await fulfillment(of: [shutdown], timeout: 3) }
            XCTAssertEqual(rig.installation.downloads, 0, mode)
            XCTAssertFalse(phases.contains(.downloading), mode)
            XCTAssertFalse(rig.owner.hasWork); XCTAssertEqual(rig.releases, 0)
            observation.cancel()
        }
    }
    func testCanceledQuitDoesNotAuthorizeReopeningANewerPendingQuit() async throws {
        let rig = AppleOwnerRig(); rig.configure(); await rig.wait(); await rig.prepare()
        let first = expectation(description: "first quit drained")
        rig.owner.beginShutdown(chain: { rig.chain }, reply: { _ in first.fulfill() })
        await fulfillment(of: [first], timeout: 3)
        rig.owner.cancelShutdown(); XCTAssertTrue(rig.owner.admissionClosed)
        let held = RecognitionTestLatch(), second = expectation(description: "second quit drained")
        rig.chain = Task { await held.wait() }
        rig.owner.beginShutdown(chain: { rig.chain }, reply: { _ in second.fulfill() })
        let observations = rig.observations
        rig.owner.deliberateEntry()
        XCTAssertTrue(rig.owner.admissionClosed)
        XCTAssertEqual(rig.owner.cachedRefusal(for: RecognitionRequest(settings: rig.saved), deliberate: true), .closed)
        do {
            let lease = try await rig.owner.installedUse("en-US", operation: nil)
            lease.release(); XCTFail("The newer quit must keep installed use closed")
        } catch { XCTAssertEqual(error as? AppleSpeechRefusal, .closed) }
        XCTAssertEqual(rig.observations, observations)
        held.signal(); await rig.wait(); await fulfillment(of: [second], timeout: 3)
        rig.owner.cancelShutdown(); rig.owner.deliberateEntry()
        XCTAssertFalse(rig.owner.admissionClosed)
    }
    func testGlobalProfileSharedReferencesAndRestartReservationRemainIndependentOfQuit() async throws {
        let rig = AppleOwnerRig(); rig.configure(); await rig.wait(); await rig.prepare()
        var profile = DictationProfile(); profile.name = "shared"; profile.target = "test.app"; profile.recognitionEngine = .appleSpeech; profile.appleSpeechLocale = "en-US"
        rig.saved.recognitionEngine = .whisper; rig.saved.profiles = [profile]; rig.configure(); await rig.wait()
        rig.owner.act(.release, locale: "en-US", token: rig.owner.snapshot.token); await rig.wait()
        XCTAssertEqual(rig.releases, 0); XCTAssertEqual(rig.owner.snapshot.refusal, .protectedReservation)
        XCTAssertTrue(rig.owner.reserveRestart()); await rig.wait(); XCTAssertTrue(rig.owner.restartReady())
        rig.owner.beginShutdown(chain: { rig.chain }, reply: { _ in })
        rig.owner.releaseRestart(); XCTAssertTrue(rig.owner.admissionClosed)
        await rig.wait()
        for _ in 0..<10 { await Task.yield() }
        rig.owner.cancelShutdown()
        var apple = Settings(); apple.recognitionEngine = .appleSpeech; apple.appleSpeechLocale = "en-US"
        XCTAssertEqual(rig.owner.cachedRefusal(for: RecognitionRequest(settings: apple)), .closed)
        XCTAssertNotEqual(rig.owner.cachedRefusal(for: RecognitionRequest(settings: apple), deliberate: true), .closed)
        XCTAssertFalse(rig.owner.admissionClosed)
        rig.saved.profiles = []; rig.configure(); await rig.wait()
        XCTAssertEqual(rig.releases, 0)
    }
    func testActualHubActionsCachedProjectionProfileAndPrepareReachOneOwner() async throws {
        let rig = AppleOwnerRig()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave4f2-hub-\(UUID())")
        try recordWave4BFixture(root, "created")
        defer { try? FileManager.default.removeItem(at: root); try? recordWave4BFixture(root, "removed") }
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore())
        try store.save(rig.saved)
        let hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")), recordings: RecordingStore(directory: root.appendingPathComponent("audio")))
        hub.bindAppleSpeech(rig.owner)
        hub.onPreparationSaved = { rig.owner.configure($0) }
        hub.refreshPreparationConfiguration(); await rig.wait()
        let scans = rig.observations
        for _ in 0..<20 {
            XCTAssertTrue(hub.recognitionCapabilityDetail.contains("cleanup only")); _ = hub.appleSpeechSnapshot.message
            XCTAssertFalse(hub.recognitionCapabilities.manualTextPrompt); XCTAssertFalse(hub.recognitionCapabilities.shadowWindows)
            XCTAssertEqual(hub.recognitionCapabilities.modelLanguages, .fixedLocale)
        }
        XCTAssertEqual(rig.observations, scans)
        hub.onAppleSpeechAction(.prepare, "en-US", hub.appleSpeechSnapshot.token); await rig.wait()
        XCTAssertEqual(hub.appleSpeechSnapshot.phase, .ready); XCTAssertEqual(rig.requests, 1)
        var profile = DictationProfile(); profile.name = "explicit"; profile.target = "test.app"; profile.recognitionEngine = .appleSpeech; profile.appleSpeechLocale = "ja-JP"
        XCTAssertTrue(hub.saveProfile(profile)); hub.flushPendingSave(); await rig.wait()
        XCTAssertEqual(store.load().profiles[0].recognitionEngine, .appleSpeech)
        let frozen = hub.profilePreview(bundleID: "test.app", browserURL: "").settings
        XCTAssertEqual(RecognitionRequest(settings: frozen).selection, .appleSpeech(locale: "ja-JP"))
        hub.onAppleSpeechAction(.prepare, "ja-JP", hub.appleSpeechSnapshot.token); await rig.wait()
        XCTAssertEqual(rig.requests, 2)
        XCTAssertNil(rig.owner.cachedRefusal(for: RecognitionRequest(settings: rig.saved)), "profile prepare preserves cached global readiness")
        hub.onAppleSpeechAction(.recheck, "ja-JP", hub.appleSpeechSnapshot.token); await rig.wait()
        XCTAssertEqual(rig.requests, 2)
    }
    func testActualAppAcquisitionFinalCommandTryoutAndRecoveryUseInstalledOnlyAdapter() async throws {
        let rig = AppleOwnerRig(); rig.configure(); await rig.wait(); await rig.prepare()
        let request = RecognitionRequest(settings: rig.saved), native = AppleOriginSession(), factory = rig.factory(native)
        let audio = [Float](repeating: 0.2, count: 8_000), before = rig.requests + rig.reserves
        let handle = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory)
        recognitionAssertEqual(await handle.finalResult(samples: audio, window: nil).text, "spoken original")
        recognitionAssertEqual(await handle.commandResult(samples: audio).text, "spoken original")
        recognitionAssertEqual(await RecognitionAcquisition.tryout(samples: audio, request: request, resident: nil, factory: factory), "spoken original")
        XCTAssertEqual(native.calls, 3); XCTAssertEqual(rig.requests + rig.reserves, before)
        XCTAssertFalse(RecognitionAcquisition.mayPromote(handle, global: request, epoch: UUID(), currentEpoch: UUID(), current: request, factory: factory))
        let op = PendingOperation(name: "setup")
        _ = try await RecognitionAcquisition.prepare(request: request, resident: nil, factory: factory, operation: op)
        XCTAssertEqual(native.calls, 3, "setup only checks ready assets; no silence decode")
        XCTAssertFalse(CanceledCaptureLimits.accepts(request))
    }
    func testPrepareEqualityDeadlineDuringNoncooperativeReserveNeverInstallsOrPublishesReady() async throws {
        let rig = AppleOwnerRig(), watchdog = RecognitionTestLatch()
        let waiting = expectation(description: "prepare watchdog")
        var now: TimeInterval = 100
        rig.clock = .init(now: { now }, wait: { delay in
            if delay >= 179 { waiting.fulfill(); await watchdog.wait() }
            else { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1e9)) }
        })
        rig.configure(); await rig.wait(); rig.reserveHold = true
        rig.owner.act(.prepare, locale: "en-US", token: rig.owner.snapshot.token)
        await fulfillment(of: [rig.reserveEntered, waiting], timeout: 3)
        now = 280; watchdog.signal()
        for _ in 0..<20 where rig.owner.snapshot.phase != .stopping { await Task.yield() }
        XCTAssertEqual(rig.owner.snapshot.phase, .stopping); XCTAssertTrue(rig.owner.hasWork)
        XCTAssertEqual(rig.requests, 0)
        rig.reserveLatch.signal(); await rig.wait()
        XCTAssertEqual(rig.requests, 0); XCTAssertNotEqual(rig.owner.snapshot.phase, .ready); XCTAssertFalse(rig.owner.hasWork)
        XCTAssertEqual(rig.releases, 0, "an uncertain/canceled prepare never sweeps reservations")
    }
    func testRecoveryProductionBatchUsesFrozenLeaseChecksAndNoPrepareOrProviderPorts() async throws {
        let rig = AppleOwnerRig(); rig.configure(); await rig.wait(); await rig.prepare()
        let native = AppleOriginSession(), factory = rig.factory(native), request = RecognitionRequest(settings: rig.saved)
        var validations = 0, reads = 0
        let before = rig.requests + rig.reserves
        let text = try await RecoveryTranscription.batch(request: request, operation: PendingOperation(name: "recovery"), samples: {
            reads += 1; return [Float](repeating: 0.2, count: 8000)
        }, validate: { validations += 1 }, active: { true }, authorize: { true }, load: {
            try await RecognitionAcquisition.acquire(request: $0, resident: nil, factory: factory)
        })
        XCTAssertEqual(text, "spoken original"); XCTAssertEqual(validations, 2); XCTAssertEqual(reads, 1)
        XCTAssertEqual(rig.requests + rig.reserves, before)
        await recognitionAssertThrows(try await RecoveryTranscription.batch(request: request, operation: PendingOperation(name: "floor"),
            samples: { [] }, validate: { XCTFail("floor must precede lease/model admission") }, active: { true }, authorize: { true },
            load: { _ in XCTFail("floor loaded model"); throw AppleSpeechRefusal.native }))
        XCTAssertEqual(native.calls, 1)
    }
    func testB57ActualControllerRejectsAppleBeforeOfferAudioRetentionOrAnyExecution() throws {
        var saved = Settings(); saved.recognitionEngine = .appleSpeech; saved.appleSpeechLocale = "en-US"; saved.canceledCaptureUndoEnabled = true
        var generation = 1, jobs = 0, copies = 0
        let controller = CanceledCaptureUndoController(configuration: { saved }, generation: { generation }, security: { .safe },
            now: { 100 }, schedule: { _, _ in XCTFail("Apple must not arm offer/retention timers"); return {} }, copy: { _ in copies += 1 })
        controller.enqueue = { _ in jobs += 1 }
        let session = DictationSession.Session(gen: 1, mode: .dictation, settings: saved, cleanupConfigured: false)
        controller.accepted(session, physical: true); controller.acknowledged(session)
        session.operation.revoke(); generation = 2
        controller.transferred([Float](repeating: 0.2, count: 8000), context: .init(generation: 1, operation: session.operation, request: session.recognition, reason: .explicitCancel), deadline: 103)
        controller.present(generation: 1)
        XCTAssertEqual(controller.retainedAudioCount, 0); XCTAssertEqual(controller.view, .empty)
        XCTAssertNil(controller.activeJob); XCTAssertEqual(jobs + copies, 0)
    }
    func testPrivateAtomicAppleRecordRoundTripBoundsAndUnknownIntentRefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave4f2-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try recordWave4BFixture(root, "created")
        defer { try? FileManager.default.removeItem(at: root); try? recordWave4BFixture(root, "removed") }
        let record = AppleSpeechReservationRecord(entries: [.init(locale: "en-US", state: .owned, prepared: true), .init(locale: "ja-JP", state: .preparedUnknown, prepared: true)])
        var io: PrivatePreparationStorage? = try PrivatePreparationStorage(root: root.appendingPathComponent("v1"))
        try io?.replace(record.encoded(), authorized: { true })
        XCTAssertEqual(try AppleSpeechReservationRecord.decode(io?.read()), record)
        io = nil; io = try PrivatePreparationStorage(root: root.appendingPathComponent("v1"))
        XCTAssertEqual(try AppleSpeechReservationRecord.decode(io?.read()), record)
        let ambiguous = AppleSpeechReservationRecord(entries: [.init(locale: "en-US", state: .intent)])
        try io?.replace(ambiguous.encodedIntent(), authorized: { true })
        XCTAssertThrowsError(try AppleSpeechReservationRecord.decode(io?.read()))
        let tooMany = AppleSpeechReservationRecord(entries: (0..<33).map { .init(locale: "en-X\($0)", state: .owned) })
        XCTAssertThrowsError(try tooMany.encoded())
        io = nil
    }

    private final class OriginCleanup: CleanupProviding {
        var calls = 0
        func clean(transcript: String, context: CleanupContext) async throws -> String { calls += 1; return "transformed" }
    }
    func testActualOrdinaryFinalizerAndDictatedPresetCommandUseFrozenAppleRequestAndExistingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parla-wave4f2-origins-\(UUID())")
        try recordWave4BFixture(root, "created")
        defer { try? FileManager.default.removeItem(at: root); try? recordWave4BFixture(root, "removed") }
        for mode in 0..<3 {
            let rig = AppleOwnerRig(); rig.configure(); await rig.wait(); await rig.prepare()
            let native = AppleOriginSession(), factory = rig.factory(native), provider = OriginCleanup()
            var saved = rig.saved; saved.dictionary = ["frozen cleanup word"]; saved.recoveryAudioEnabled = false
            saved.cleanupEnabled = mode != 0; saved.outputMode = mode == 1 ? .selectedPreset : .raw
            let preset = TransformPreset(name: "Rewrite", instruction: "be concise")
            saved.transformPresets = [preset]; saved.selectedPresetID = preset.id
            let machine = DictationSession()
            _ = machine.handle(mode == 2 ? .startCommand(settings: saved, cleanupConfigured: true, focus: .editable, selection: "selected source")
                : .startDictation(settings: saved, cleanupConfigured: mode != 0, live: false))
            _ = machine.handle(.recorderStarted(gen: machine.gen))
            if mode != 2 { _ = machine.handle(.focusSampled(gen: machine.gen, focus: .editable)) }
            guard case .recording(let session) = machine.state else { return XCTFail("expected frozen capture") }
            let request = session.recognition, before = rig.requests + rig.reserves
            saved.recognitionEngine = .whisper; saved.appleSpeechLocale = "ja-JP"
            let audio = [Float](repeating: 0.2, count: 8000)
            if mode == 2 {
                let handle = try await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory, operation: session.operation)
                let instruction = await DictationProcessing.command(operation: session.operation, handle: handle, samples: audio)
                let text = try await session.transform(instruction: XCTUnwrap(instruction)) { _ in provider }
                XCTAssertEqual(text, "transformed")
            } else {
                let store = SettingsStore(url: root.appendingPathComponent("settings-\(mode).json"), credentials: testCredentialStore())
                try store.save(saved)
                let recordings = RecordingStore(directory: root.appendingPathComponent("no-audio-\(mode)"), writer: { _, _ in XCTFail("audio writes disabled") })
                var order: [String] = []
                let finalizer = OrdinaryDictationFinalization(recordings: recordings, settings: store, entered: { order.append($0 == .stash ? "stash" : "resolve") })
                await finalizer.run(operation: session.operation, samples: audio, window: nil, prepare: { recording, disposal in
                    XCTAssertNil(recording); XCTAssertNil(disposal); order.append("prepare")
                    return try! await RecognitionAcquisition.acquire(request: request, resident: nil, factory: factory, operation: session.operation)
                }, recognized: { handle, raw in
                    XCTAssertEqual(handle.request.selection, .appleSpeech(locale: "en-US")); order.append("raw")
                    finalizer.resolve(transcript: raw, secure: false); return raw
                }, clean: { raw in
                    order.append("clean")
                    return await Pipeline(outputSettings: session.effectiveSettings, bundleID: nil) { _ in provider }.clean(transcript: raw)
                }, completed: { _, text, failure in
                    order.append("completed"); XCTAssertNil(failure); XCTAssertEqual(text, mode == 0 ? "spoken original" : "transformed")
                })
                XCTAssertEqual(order, ["stash", "prepare", "raw", "resolve", "clean", "completed"])
            }
            XCTAssertEqual(native.calls, 1); XCTAssertEqual(provider.calls, mode == 0 ? 0 : 1)
            XCTAssertEqual(rig.requests + rig.reserves, before)
        }
    }
    func testActualTerminationCoordinatorWaitsForAppleAndClipboardWithOtherParticipantsOff() async throws {
        let rig = AppleOwnerRig(); rig.installation.hold = true; rig.configure(); await rig.wait()
        rig.owner.act(.prepare, locale: "en-US", token: rig.owner.snapshot.token)
        await fulfillment(of: [rig.installation.entered], timeout: 3)
        var clipboard: ((Bool) -> Void)?, replies: [Bool] = []
        let settled = expectation(description: "composed quit settled")
        let coordinator = TerminationCoordinator(clipboard: { clipboard = $0 }, updater: { $0(true) },
            appleSpeech: { rig.owner.beginShutdown(chain: { rig.chain }, reply: $0) }, cancelAppleSpeech: { rig.owner.cancelShutdown() },
            cancelClipboard: {}, cancelUpdater: {}, reply: { replies.append($0); settled.fulfill() }, failure: { XCTFail("unexpected refusal") })
        XCTAssertEqual(coordinator.request(), .terminateLater); XCTAssertTrue(rig.owner.admissionClosed)
        clipboard?(true); XCTAssertTrue(replies.isEmpty); XCTAssertTrue(rig.owner.hasWork)
        rig.installation.finish(); await rig.wait(); await fulfillment(of: [settled], timeout: 3)
        XCTAssertEqual(replies, [true]); XCTAssertFalse(coordinator.isPending); XCTAssertFalse(rig.owner.hasWork)
    }

}
