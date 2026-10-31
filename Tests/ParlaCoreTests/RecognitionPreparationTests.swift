import Darwin
import Foundation
import XCTest
@testable import ParlaCore

private final class PreparationFixture: @unchecked Sendable {
    let root: URL, health: URL
    var consent = UUID(), epoch = UUID()
    var build = PreparationBuild(app: UUID(), native: UUID(), architecture: "arm64")
    var runtime = RecognitionRuntime(nativeVersion: "fixture-native", buildScope: "process-only")
    var generation = RecognitionFileGeneration(bytes: ModelCatalog.default.bytes, modified: 42, fileNumber: 7)
    var entries = 0, decodes = 0, frees = 0, builds = 0, storageOpens = 0, admissions = 0
    var fail: PrivatePreparationStorage.Boundary?, failWrites = false, failPoison = false
    var boundary: ((PrivatePreparationStorage.Boundary) -> Void)?
    var constructing: (() throws -> Void)?, decoding: (() -> Void)?
    var output = WhisperNativeDecode(status: 0)
    var prompts: [String?] = []
    private let preserveRoot: Bool
    init(root ownedRoot: URL? = nil, existing: Bool = false, preserveRoot: Bool = false) throws {
        self.preserveRoot = preserveRoot
        root = ownedRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("wave4c1-" + UUID().uuidString)
        health = root.appendingPathComponent("health")
        if !existing {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("wave4c1 owned fixture".utf8).write(to: root.appendingPathComponent("CANARY"))
        }
        try record("created")
    }
    deinit {
        if !preserveRoot { try? FileManager.default.removeItem(at: root); try? record("removed") }
    }
    func record(_ action: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
        let f = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? f.close() }
        try f.seekToEnd(); try f.write(contentsOf: Data("\(action)\t\(getpid())\t\(root.path)\n".utf8))
    }
    func storage() throws -> PrivatePreparationStorage {
        storageOpens += 1
        return try PrivatePreparationStorage(root: health) { [unowned self] point in
            self.boundary?(point)
            if self.fail == point || (self.failWrites && [.createTemp, .write, .fileSync, .rename, .directorySync].contains(point))
                || (self.failPoison && point == .quarantine) { throw PreparationRefusal.trackingUnavailable }
        }
    }
    func owner(launch: UUID = UUID(), enable: Bool = true, clean: Bool = true) throws -> RecognitionPreparation {
        let guardOwner = RecognitionPreparation(launch: launch, storage: { [unowned self] in try self.storage() }, build: { [unowned self] in self.builds += 1; return self.build })
        if enable, clean { try guardOwner.prepareConsent(consent) }
        guardOwner.configure(enabled: enable, consent: enable ? consent : nil, selection: epoch)
        return guardOwner
    }
    var request: RecognitionRequest {
        var s = Settings(); s.whisperModelPath = "/owned/" + ModelCatalog.default.filename
        s.language = "PRIVATE_LANGUAGE"; s.dictionary = ["PRIVATE_PROMPT"]
        return RecognitionRequest(settings: s)
    }
    func factory(_ owner: RecognitionPreparation? = nil) -> RecognitionFactory {
        RecognitionFactory(native: { [unowned self] _, _ in self.entries += 1; try self.constructing?(); return Context(self) },
            guardedNative: { [unowned self] _, compute, token in
                guard compute == .nativeDefaults else { throw TranscriberError(description: "fixture config") }
                return try token.nativeEntry { self.entries += 1; try self.constructing?(); return Context(self) }
            }, preparation: owner, runtime: { [unowned self] in self.runtime }, metadata: { [unowned self] _ in self.generation },
            directory: URL(fileURLWithPath: "/owned"), admit: { [unowned self] _, _ in self.admissions += 1 })
    }
    final class Context: WhisperNativeContext {
        unowned let fixture: PreparationFixture
        init(_ fixture: PreparationFixture) { self.fixture = fixture }
        deinit { fixture.frees += 1 }
        var multilingual: Bool { false }
        func knowsLanguage(_ code: String) -> Bool { false }
        func spokenLanguage() -> String? { nil }
        func decode(_ samples: [Float], initialPrompt: String?, language: String,
                    configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
            fixture.decodes += 1; fixture.prompts.append(initialPrompt); fixture.decoding?(); return fixture.output
        }
    }
    func ledger() throws -> PreparationLedger { try JSONDecoder().decode(PreparationLedger.self, from: Data(contentsOf: health.appendingPathComponent("health.json"))) }
    func seed(_ mutate: (inout PreparationLedger, PreparationKey, PreparationKey) -> Void) throws {
        let identity = try factory().resolve(request)
        var value = PreparationLedger(consent: consent)
        let construction = try PreparationKey(identity: identity, build: build, phase: .nativeConstruction)
        let warmup = try PreparationKey(identity: identity, build: build, phase: .explicitSyntheticWarmup)
        mutate(&value, construction, warmup)
        try storage().replace(JSONEncoder().encode(value))
    }
    func seedPending(_ phase: PreparationPhase, count: Int = 0, launch: UUID = UUID()) throws {
        try seed { ledger, construction, warmup in
            let key: PreparationKey
            switch phase {
            case .nativeConstruction: key = construction
            case .explicitSyntheticWarmup: key = warmup
            case .firstRealAudioRequest: key = try! PreparationKey(identity: factory().resolve(request), build: build, phase: phase)
            }
            ledger.entries = [PreparationEntry(key: key, unresolved: count,
                pending: PreparationPending(attempt: UUID(), launch: launch, operation: UUID(), selection: epoch))]
        }
    }
    func held(_ phase: PreparationPhase = .nativeConstruction) throws { try seedPending(phase, count: 1) }
}

final class RecognitionPreparationTests: XCTestCase {
    func testAsyncWarmupRevocationRetiresJournalButHoldsOwnerAndSuccessorUntilActualReturn() async throws {
        let f = try fixture(), owner = try f.owner(), operation = PendingOperation(name: "awaited warmup")
        let handle = try await f.factory(owner).acquire(request: f.request, operation: operation)
        let resident = try XCTUnwrap(handle.resident)
        let permit = try XCTUnwrap(owner.authorize(identity: resident.identity, policy: .standard, resident: resident, operation: operation))
        let client = RecognitionSuspension()
        var successor = false
        let work = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) {
            do {
                _ = try await permit.warmup(readiness: resident.preparation) {
                    await client.recognize([0], initialPrompt: nil, language: nil, shouldAbort: nil)
                }
                XCTFail("Revoked warmup cannot publish readiness")
            } catch { XCTAssertEqual(error as? PreparationRefusal, .revoked) }
        }
        await fulfillment(of: [client.entered], timeout: 2)
        XCTAssertTrue(owner.hasActiveEntry)
        operation.revoke(); operation.requestAbort()
        let canceled = try f.ledger()
        let canceledBytes = try Data(contentsOf: f.health.appendingPathComponent("health.json"))
        let record = try XCTUnwrap(canceled.entries.first { $0.key.p == .explicitSyntheticWarmup })
        XCTAssertNil(record.pending); XCTAssertEqual(record.outcome, .canceled)
        let next = PendingOperationQueue.enqueue(previous: work, operation: PendingOperation(name: "next"), completes: true) { successor = true }
        XCTAssertTrue(owner.hasActiveEntry); XCTAssertFalse(operation.hasExited); XCTAssertFalse(successor)
        client.finish()
        await next.value
        XCTAssertFalse(owner.hasActiveEntry); XCTAssertTrue(operation.hasExited); XCTAssertTrue(successor)
        XCTAssertEqual(try Data(contentsOf: f.health.appendingPathComponent("health.json")), canceledBytes, "Late success must not overwrite the revocation terminal")
    }

    private func fixture() throws -> PreparationFixture {
        let f = try PreparationFixture()
        addTeardownBlock { f.constructing = nil; f.decoding = nil; f.boundary = nil }
        return f
    }
    func testDefaultOffCodableAndMalformedFailClosedWithoutConsentCreation() async throws {
        for source in ["{}", "{\"nativePreparationSafeStartEnabled\":null}", "{\"nativePreparationSafeStartEnabled\":false}"] {
            let s = try JSONDecoder().decode(Settings.self, from: Data(source.utf8))
            XCTAssertFalse(s.nativePreparationSafeStartEnabled); XCTAssertNil(s.nativePreparationConsent)
        }
        for source in ["{\"nativePreparationSafeStartEnabled\":1}", "{\"nativePreparationSafeStartEnabled\":\"true\"}", "{\"nativePreparationConsent\":\"bad\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data(source.utf8)))
        }
        var s = Settings(); s.nativePreparationSafeStartEnabled = true; s.nativePreparationConsent = UUID()
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)), s)
        let f = try fixture(), owner = try f.owner(enable: false)
        _ = try await f.factory(owner).acquire(request: f.request)
        XCTAssertEqual(f.entries, 1); XCTAssertEqual(f.builds, 0); XCTAssertEqual(f.storageOpens, 0)
        for _ in 0..<10 { _ = owner.snapshot }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.health.path))
        owner.configure(enabled: true, consent: nil, selection: f.epoch)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
        XCTAssertEqual(f.entries, 1); XCTAssertEqual(f.storageOpens, 0)
    }
    func testRealFactoryAdapterDurableBoundaryEmptyWarmupAndPreparedBorrow() async throws {
        let f = try fixture(), owner = try f.owner(), factory = f.factory(owner)
        f.constructing = {
            let ledger = try f.ledger()
            XCTAssertEqual(ledger.entries.first?.pending?.launch, owner.launch)
            XCTAssertEqual(ledger.entries.first?.key.p, .nativeConstruction)
        }
        let handle = try await factory.acquire(request: f.request)
        XCTAssertTrue(handle.client is WhisperTranscriber)
        XCTAssertNil(try f.ledger().entries.first?.pending)
        f.decoding = { XCTAssertEqual(try? f.ledger().entries.last?.key.p, .explicitSyntheticWarmup); XCTAssertNotNil(try? f.ledger().entries.last?.pending) }
        recognitionAssertEqual(await handle.recognize([0], pass: .warmup).native, .completed(.init(text: "")))
        XCTAssertEqual(f.prompts.count, 1); XCTAssertNil(f.prompts[0])
        XCTAssertTrue(try f.ledger().entries.allSatisfy { $0.pending == nil && $0.unresolved == 0 && $0.outcome == .completed })
        let warmOnly = try Data(contentsOf: f.health.appendingPathComponent("health.json"))
        await recognitionAssertThrows(try await factory.acquire(request: f.request, resident: handle.resident, policy: .readOnlyCatalog))
        XCTAssertEqual(try Data(contentsOf: f.health.appendingPathComponent("health.json")), warmOnly)
        f.decoding = nil
        _ = await handle.recognize([0.2], pass: .fullFinal)
        let bytes = try Data(contentsOf: f.health.appendingPathComponent("health.json"))
        let borrowed = try await factory.acquire(request: f.request, resident: handle.resident, policy: .readOnlyCatalog)
        _ = await borrowed.recognize([0], pass: .warmup)
        XCTAssertEqual(f.entries, 1); XCTAssertEqual(f.decodes, 2)
        XCTAssertEqual(try Data(contentsOf: f.health.appendingPathComponent("health.json")), bytes)
        f.decoding = nil
        _ = await borrowed.recognize([0.2], pass: .fullFinal)
        XCTAssertEqual(f.decodes, 3)
        XCTAssertEqual(try Data(contentsOf: f.health.appendingPathComponent("health.json")), bytes)
        let json = String(decoding: bytes, as: UTF8.self)
        for canary in ["PRIVATE_LANGUAGE", "PRIVATE_PROMPT", "/owned", "process-only", "PRIVATE_ERROR"] { XCTAssertFalse(json.contains(canary)) }
    }
    func testReadOnlyCatalogRejectsColdAndConstructedButUnpreparedWithZeroGuardWrites() async throws {
        let f = try fixture(), owner = try f.owner(), factory = f.factory(owner)
        let clean = try Data(contentsOf: f.health.appendingPathComponent("health.json"))
        await recognitionAssertThrows(try await factory.acquire(request: f.request, policy: .readOnlyCatalog)) { XCTAssertEqual($0 as? PreparationRefusal, .preparedResidentRequired) }
        XCTAssertEqual(f.entries, 0)
        XCTAssertEqual(try Data(contentsOf: f.health.appendingPathComponent("health.json")), clean)
        let handle = try await factory.acquire(request: f.request)
        let constructed = try Data(contentsOf: f.health.appendingPathComponent("health.json"))
        await recognitionAssertThrows(try await factory.acquire(request: f.request, resident: handle.resident, policy: .readOnlyCatalog))
        XCTAssertEqual(try Data(contentsOf: f.health.appendingPathComponent("health.json")), constructed)
        XCTAssertEqual(f.entries, 1); XCTAssertEqual(f.decodes, 0)
    }
    func testFirstAndSecondExactKeyUnknownRecordsAcrossReconstructedLaunches() async throws {
        let f = try fixture()
        try f.seedPending(.nativeConstruction)
        do {
            let owner = try f.owner(clean: false), factory = f.factory(owner)
            XCTAssertEqual(try f.ledger().entries[0].unresolved, 1)
            let consumed = try f.ledger().entries[0].consumed
            owner.configure(enabled: true, consent: f.consent, selection: f.epoch)
            for _ in 0..<20 { _ = owner.snapshot }
            XCTAssertEqual(try f.ledger().entries[0].consumed, consumed)
            f.constructing = { f.failWrites = true; f.failPoison = true }
            await recognitionAssertThrows(try await factory.acquire(request: f.request))
            XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
            XCTAssertEqual(f.entries, 1); XCTAssertEqual(f.frees, 1)
        }
        f.failWrites = false; f.failPoison = false; f.constructing = nil
        let owner = try f.owner(clean: false)
        XCTAssertEqual(try f.ledger().entries[0].unresolved, 2)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request)) { XCTAssertEqual($0 as? PreparationRefusal, .paused) }
        XCTAssertEqual(f.entries, 1)
    }
    func testSameLaunchAndDuplicateOwnerNeverConsumePendingAgain() async throws {
        let f = try fixture(), launch = UUID()
        try f.seedPending(.nativeConstruction, launch: launch)
        let owner = try f.owner(launch: launch, clean: false)
        XCTAssertEqual(try f.ledger().entries[0].unresolved, 0)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
        let duplicate = try f.owner(launch: launch, clean: false)
        XCTAssertEqual(duplicate.snapshot.status, .trackingUnavailable)
        XCTAssertEqual(try f.ledger().entries[0].unresolved, 0); XCTAssertEqual(f.entries, 0)
    }
    func testConsumeFailurePublishesNoCountOrGrantAndPoisonPreventsCounting() async throws {
        let f = try fixture(); try f.seedPending(.nativeConstruction)
        f.fail = .rename
        do {
            let owner = try f.owner(clean: false)
            XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
            await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.health.appendingPathComponent("health.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.health.appendingPathComponent("quarantine").path))
        }
        f.fail = nil
        let next = try f.owner(clean: false)
        XCTAssertEqual(next.snapshot.status, .trackingUnavailable); XCTAssertEqual(f.entries, 0)
    }
    func testBothPhaseHoldsCannotBeClearedByConstructionOrUnpreparedBorrow() async throws {
        for phase in [PreparationPhase.nativeConstruction, .explicitSyntheticWarmup] {
            let f = try fixture(); try f.held(phase)
            let owner = try f.owner(clean: false), factory = f.factory(owner)
            await recognitionAssertThrows(try await factory.acquire(request: f.request))
            XCTAssertEqual(owner.snapshot.status, .paused); XCTAssertEqual(f.entries, 0)
        }
    }
    func testStableKeyIgnoresProcessScopeButSeparatesAllRealMetadataAndCustomRefuses() async throws {
        let f = try fixture(); try f.held()
        let owner = try f.owner(clean: false)
        f.runtime = .init(nativeVersion: f.runtime.nativeVersion, buildScope: UUID().uuidString)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
        f.generation = .init(bytes: f.generation.bytes, modified: 43, fileNumber: 7)
        _ = try await f.factory(owner).acquire(request: f.request)
        XCTAssertEqual(f.entries, 1)
        var s = Settings(); s.whisperModelPath = "/custom/" + ModelCatalog.default.filename
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: RecognitionRequest(settings: s))) { XCTAssertEqual($0 as? PreparationRefusal, .unsupportedSelection) }
        let original = try f.factory().resolve(f.request)
        let base = try PreparationKey(identity: original, build: f.build, phase: .nativeConstruction)
        for build in [PreparationBuild(app: UUID(), native: f.build.native, architecture: "arm64"),
                      PreparationBuild(app: f.build.app, native: UUID(), architecture: "arm64"),
                      PreparationBuild(app: f.build.app, native: f.build.native, architecture: "x86_64")] {
            XCTAssertNotEqual(try PreparationKey(identity: original, build: build, phase: .nativeConstruction), base)
        }
        XCTAssertNotEqual(try PreparationKey(identity: original, build: f.build, phase: .explicitSyntheticWarmup), base)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(base).count, 512)
    }
    func testMissingBuildAndUnsupportedComputeVersionAndGenerationNeverEnter() async throws {
        let f = try fixture()
        let owner = RecognitionPreparation(storage: { try f.storage() }, build: { throw PreparationRefusal.unsupportedSelection })
        try owner.prepareConsent(f.consent); owner.configure(enabled: true, consent: f.consent, selection: f.epoch)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
        XCTAssertEqual(owner.snapshot.status, .unsupportedSelection); XCTAssertEqual(f.entries, 0)
        for model in ModelCatalog.all {
            let identity = RecognitionIdentity(engine: .whisper, selection: .whisper(localPath: "/PRIVATE_PATH"),
                artifact: .admittedCatalog(id: model.id, expectedSHA256: model.sha256, expectedBytes: model.bytes),
                generation: .init(bytes: model.bytes, modified: 1), runtime: .init(nativeVersion: "v", buildScope: "p"), unknownRevisionScope: nil)
            XCTAssertNoThrow(try PreparationKey(identity: identity, build: f.build, phase: .nativeConstruction))
        }
    }
    func testEveryBeginAtomicFaultHasZeroNativeEntriesAndNoPublishedSuccess() async throws {
        for point in [PrivatePreparationStorage.Boundary.createTemp, .write, .fileSync, .rename, .directorySync] {
            let f = try fixture(), owner = try f.owner()
            f.fail = point
            await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request), "\(point)")
            XCTAssertEqual(f.entries, 0); XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
            XCTAssertFalse(owner.hasActiveEntry)
        }
    }
    func testCancellationDuringDurableBeginRefusesBeforeNativeAndPreservesAbortSlot() async throws {
        let f = try fixture(), owner = try f.owner(), op = PendingOperation(name: "PRIVATE_OPERATION")
        var childCanceled = 0
        op.installAbort { childCanceled += 1 }
        f.boundary = { if $0 == .fileSync { op.revoke(); op.requestAbort() } }
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request, operation: op))
        XCTAssertEqual(f.entries, 0); XCTAssertEqual(childCanceled, 1)
    }
    func testReturnedNilErrorPostcheckAndOrdinaryASRNeverLeavePending() async throws {
        let f = try fixture(), owner = try f.owner(), factory = f.factory(owner)
        f.constructing = { throw TranscriberError(description: "PRIVATE_ERROR") }
        await recognitionAssertThrows(try await factory.acquire(request: f.request))
        XCTAssertEqual(try f.ledger().entries[0].outcome, .returnedFailure)
        f.constructing = { f.generation = .init(bytes: f.generation.bytes, modified: 99) }
        await recognitionAssertThrows(try await factory.acquire(request: f.request))
        XCTAssertEqual(try f.ledger().entries[0].outcome, .completed)
        XCTAssertNil(try f.ledger().entries[0].pending)
        f.constructing = nil
        let handle = try await factory.acquire(request: f.request)
        _ = await handle.recognize([0.2], pass: .fullFinal)
        XCTAssertEqual(try f.ledger().entries.last?.key.p, .firstRealAudioRequest)
        let data = try Data(contentsOf: f.health.appendingPathComponent("health.json"))
        for pass in [RecognitionHandle.Pass.fullFinal, .command, .streamHead("PRIVATE"), .streamTail("PRIVATE"), .windowedFinal("PRIVATE")] {
            _ = await handle.recognize([0.2], pass: pass)
        }
        XCTAssertEqual(try Data(contentsOf: f.health.appendingPathComponent("health.json")), data)
    }
    func testWarmupFailureAndCancellationAreTerminalAndEmptySuccessBreaksOnlyOwnPhase() async throws {
        for result in [WhisperNativeDecode(status: 1), .init(status: 1, abortObserved: true), .init(status: 0)] {
            let f = try fixture(), owner = try f.owner(), handle = try await f.factory(owner).acquire(request: f.request)
            f.output = result
            _ = await handle.recognize([0], pass: .warmup)
            XCTAssertEqual(try f.ledger().entries.last?.outcome, result.status == 0 ? .completed : (result.abortObserved ? .canceled : .returnedFailure))
            XCTAssertTrue(try f.ledger().entries.allSatisfy { $0.pending == nil && $0.unresolved == 0 })
        }
    }
    func testAllPostReturnWritesAndPoisonFailNextLaunchMayCountUnknownPolicyWitness() async throws {
        let f = try fixture()
        do {
            let owner = try f.owner()
            f.constructing = { f.failWrites = true; f.failPoison = true }
            await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
            XCTAssertEqual(f.entries, 1); XCTAssertEqual(f.frees, 1)
            XCTAssertNotNil(try f.ledger().entries.first?.pending)
            XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
        }
        f.failWrites = false; f.failPoison = false; f.constructing = nil
        let next = try f.owner(clean: false)
        XCTAssertEqual(try f.ledger().entries[0].unresolved, 1) // UNKNOWN record, NOT a confirmed native crash
        XCTAssertEqual(next.snapshot.status, .ready)
    }
    func testSuccessfulPoisonPreventsUnknownCountAndExplicitResetRecoversOwnedHealthOnly() async throws {
        let f = try fixture()
        do {
            let owner = try f.owner()
            f.constructing = { f.failWrites = true }
            await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.health.appendingPathComponent("quarantine").path))
        }
        f.failWrites = false; f.constructing = nil
        let next = try f.owner(clean: false)
        XCTAssertEqual(next.snapshot.status, .trackingUnavailable)
        // The fresh owner cannot identify the quarantined grant through the storage read API.
        // Explicit repair alone therefore cannot manufacture expanded consent.
        // Only the already-authorized failed-retirement owner can Reset back to schema2.
        XCTAssertThrowsError(try next.reset(token: next.snapshot.token))
        f.consent = UUID(); try next.prepareConsent(f.consent)
        next.configure(enabled: true, consent: f.consent, selection: f.epoch)
        XCTAssertTrue(try f.ledger().entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("CANARY")), "wave4c1 owned fixture")
        _ = try await f.factory(next).acquire(request: f.request)
    }
    func testRetrySingleUseExactTargetKeepResetStaleTokenDisableAndNewConsent() async throws {
        let f = try fixture(); try f.held(.explicitSyntheticWarmup)
        let owner = try f.owner(clean: false), factory = f.factory(owner)
        await recognitionAssertThrows(try await factory.acquire(request: f.request))
        let oldToken = owner.snapshot.token, op = PendingOperation(name: "Retry")
        try owner.retryOnce(token: oldToken, operation: op, identity: factory.resolve(f.request))
        XCTAssertThrowsError(try owner.retryOnce(token: oldToken, operation: PendingOperation(name: "Duplicate"), identity: factory.resolve(f.request)))
        let handle = try await factory.acquire(request: f.request, operation: op)
        recognitionAssertEqual(await handle.recognize([0.2], pass: .fullFinal).native, .failed(.preparationUnavailable))
        recognitionAssertEqual(await handle.recognize([0], pass: .warmup).native, .completed(.init(text: "")))
        owner.finishRetry(op)
        XCTAssertEqual(f.entries, 1); XCTAssertEqual(f.decodes, 1)
        let fresh = try await factory.acquire(request: f.request, resident: handle.resident)
        XCTAssertEqual(fresh.instance, handle.instance)
        owner.revokeDraft()
        await recognitionAssertThrows(try await factory.acquire(request: f.request, resident: fresh.resident))
        owner.configure(enabled: false, consent: nil, selection: f.epoch)
        let opens = f.storageOpens, builds = f.builds
        _ = try await factory.acquire(request: f.request)
        XCTAssertEqual(f.storageOpens, opens); XCTAssertEqual(f.builds, builds)
        f.consent = UUID(); try owner.prepareConsent(f.consent)
        owner.configure(enabled: true, consent: f.consent, selection: f.epoch)
        XCTAssertTrue(try f.ledger().entries.isEmpty)
        XCTAssertThrowsError(try owner.reset(token: oldToken))
        XCTAssertFalse(handle.preparationIsCurrent)
    }
    func testCapacityCorruptUnknownFilesSymlinksModesLinksAndOversizeRefusePreserve() async throws {
        for mutation in 0..<6 {
            let f = try fixture()
            do { _ = try f.owner() }
            let file = f.health.appendingPathComponent("health.json")
            switch mutation {
            case 0: try Data("corrupt".utf8).write(to: file)
            case 1: try Data(repeating: 1, count: 16_385).write(to: file)
            case 2: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            case 3: try FileManager.default.linkItem(at: file, to: f.health.appendingPathComponent("unknown-hardlink"))
            case 4: try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.root.appendingPathComponent("CANARY"))
            default: try Data("unknown".utf8).write(to: f.health.appendingPathComponent("unknown"))
            }
            let owner = try f.owner(clean: false)
            XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
            await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request)); XCTAssertEqual(f.entries, 0)
            if mutation != 0 { XCTAssertThrowsError(try owner.reset(token: owner.snapshot.token)) }
            else {
                try owner.reset(token: owner.snapshot.token)
                XCTAssertEqual(owner.snapshot.refusal, .consentRequired)
                await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
            }
        }
        let f = try fixture()
        try f.seed { ledger, key, _ in
            for n in 0..<12 {
                let identity = RecognitionIdentity(engine: .whisper, selection: f.request.selection,
                    artifact: .admittedCatalog(id: "fixture\(n)", expectedSHA256: ModelCatalog.default.sha256, expectedBytes: f.generation.bytes),
                    generation: f.generation, runtime: f.runtime, unknownRevisionScope: nil)
                ledger.entries.append(PreparationEntry(key: try! PreparationKey(identity: identity, build: f.build, phase: .nativeConstruction)))
            }
        }
        let owner = try f.owner(clean: false)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request)); XCTAssertEqual(f.entries, 0)
        XCTAssertEqual(try f.ledger().entries.count, 12)
    }
    func testMachOFixturesBoundsMagicUUIDAndBothProductArchitectures() throws {
        func image(_ cpu: UInt32 = 0x0100000c) -> Data {
            var b = Data(repeating: 0, count: 56)
            func put(_ value: UInt32, at: Int) { for i in 0..<4 { b[at+i] = UInt8((value >> (i*8)) & 255) } }
            put(0xfeedfacf, at: 0); put(cpu, at: 4); put(1, at: 16); put(24, at: 20)
            put(0x1b, at: 32); put(24, at: 36)
            for i in 0..<16 { b[40+i] = UInt8(i+1) }
            return b
        }
        XCTAssertEqual(try PreparationMachO.parse(image()).architecture, "arm64")
        XCTAssertEqual(try PreparationMachO.parse(image(0x01000007)).architecture, "x86_64")
        for kind in 0..<9 {
            var b = image()
            switch kind {
            case 0: b[0] = 0
            case 1: b[4] = 0
            case 2: b[16] = 0
            case 3: b[17] = 5
            case 4: b[20] = 255
            case 5: b[36] = 0
            case 6: b[36] = 32
            case 7: for i in 40..<56 { b[i] = 0 }
            default: b.append(contentsOf: repeatElement(0, count: 65_536))
            }
            XCTAssertThrowsError(try PreparationMachO.parse(b), "fixture \(kind)")
        }
        let data = image()
        try data.withUnsafeBytes { a in
            try data.withUnsafeBytes { n in
                let build = try PreparationBuildReader.readImages(main: a.baseAddress!, native: n.baseAddress!)
                XCTAssertEqual(build.app, build.native)
            }
        }
        var duplicate = image(); duplicate[16] = 2; duplicate[20] = 48
        duplicate.append(image().suffix(24))
        XCTAssertThrowsError(try PreparationMachO.parse(duplicate))
    }
}

extension RecognitionPreparationTests {
    func testHeldConstructorAndWarmupRevokeRetireButRetainActualExitAndSerialBarrier() async throws {
        for phase in [PreparationPhase.nativeConstruction, .explicitSyntheticWarmup] {
            let f = try fixture(), owner = try f.owner(), factory = f.factory(owner)
            let entered = expectation(description: "fake native held"), gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            if phase == .nativeConstruction { f.constructing = { entered.fulfill(); gate.wait() } }
            else { f.decoding = { entered.fulfill(); gate.wait() } }
            let op = PendingOperation(name: "held preparation")
            let first = PendingOperationQueue.enqueue(previous: nil, operation: op, completes: true, work: {
                do {
                    let handle = try await factory.acquire(request: f.request, operation: op, selectionEpoch: f.epoch)
                    _ = await handle.recognize([0], pass: .warmup, shouldAbort: { op.shouldAbort })
                } catch { }
            })
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertTrue(owner.hasActiveEntry)
            op.revoke(); op.requestAbort()
            XCTAssertTrue(owner.hasActiveEntry)
            XCTAssertEqual(owner.snapshot.status, .preparing)
            XCTAssertEqual(try f.ledger().entries.last?.outcome, .canceled)
            XCTAssertNil(try f.ledger().entries.last?.pending)
            XCTAssertEqual(f.frees, 0)
            XCTAssertThrowsError(try owner.reset(token: owner.snapshot.token))
            owner.selectionChanged(UUID())
            let second = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "new stale work"), work: {
                do { _ = try await factory.acquire(request: f.request, selectionEpoch: f.epoch); XCTFail("stale work entered") } catch { }
            })
            XCTAssertEqual(f.entries, 1)
            gate.signal(); await second.value
            XCTAssertEqual(f.frees, 1); XCTAssertFalse(owner.hasActiveEntry)
            XCTAssertTrue(op.hasExited)
        }
    }
    func testKnownCleanQuitBreaksOnlyItsPhaseAndCancelQuitNeverRevivesOldGrant() async throws {
        let f = try fixture(), owner = try f.owner(), factory = f.factory(owner)
        let operation = PendingOperation(name: "prepare")
        f.constructing = { owner.beginQuit(); owner.cancelQuit() }
        await recognitionAssertThrows(try await factory.acquire(request: f.request, operation: operation))
        XCTAssertEqual(try f.ledger().entries.first?.outcome, .cleanQuit)
        XCTAssertNil(try f.ledger().entries.first?.pending)
        XCTAssertFalse(owner.hasActiveEntry)
        f.constructing = nil
        _ = try await factory.acquire(request: f.request, operation: PendingOperation(name: "fresh deliberate"))
        XCTAssertEqual(f.entries, 2)
    }
    func testConstructionSuccessDoesNotClearWarmupStreakButEmptyWarmupDoes() async throws {
        let f = try fixture(); try f.seedPending(.explicitSyntheticWarmup)
        let owner = try f.owner(clean: false), handle = try await f.factory(owner).acquire(request: f.request)
        XCTAssertEqual(try f.ledger().entries.first?.unresolved, 1)
        _ = await handle.recognize([0], pass: .warmup)
        XCTAssertEqual(try f.ledger().entries.first?.unresolved, 0)
    }
    func testResetPersistenceFailureKeepsUnavailableAndFailedEnableCannotClaimProtection() async throws {
        let f = try fixture(), owner = try f.owner()
        f.fail = .reset
        XCTAssertThrowsError(try owner.reset(token: owner.snapshot.token))
        XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request)); XCTAssertEqual(f.entries, 0)
        f.fail = nil
        owner.revokeDraft()
        owner.configure(enabled: true, consent: f.consent, selection: f.epoch)
        XCTAssertNotEqual(owner.snapshot.status, .ready)
        await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request))
    }
    func testStaleTargetRetryAndKeySchemaCapacityBoundsAreClosed() async throws {
        let f = try fixture(); try f.held()
        let owner = try f.owner(clean: false), factory = f.factory(owner)
        await recognitionAssertThrows(try await factory.acquire(request: f.request))
        let token = owner.snapshot.token
        f.generation = .init(bytes: f.generation.bytes, modified: 100)
        XCTAssertThrowsError(try owner.retryOnce(token: token, operation: PendingOperation(name: "stale target"), identity: factory.resolve(f.request)))
        owner.selectionChanged(UUID())
        XCTAssertThrowsError(try owner.reset(token: token))
        XCTAssertEqual(f.entries, 0)
        let identity = try factory.resolve(f.request)
        for runtime in [RecognitionRuntime(nativeVersion: String(repeating: "x", count: 65), buildScope: "p"),
                        .init(nativeVersion: "v\n", buildScope: "p"), .init(nativeVersion: "v", buildScope: "p", adapterRevision: 2),
                        .init(nativeVersion: "v", buildScope: "p", compute: .init(defaultsRevision: 2))] {
            let changed = RecognitionIdentity(engine: identity.engine, selection: identity.selection, artifact: identity.artifact,
                generation: identity.generation, runtime: runtime, unknownRevisionScope: nil)
            XCTAssertThrowsError(try PreparationKey(identity: changed, build: f.build, phase: .nativeConstruction))
        }
    }
}

extension RecognitionPreparationTests {
    func testWarmupAllTerminalWritesFailProducesUnknownWarmupRecordOnNextLaunch() async throws {
        let f = try fixture()
        do {
            let owner = try f.owner(), handle = try await f.factory(owner).acquire(request: f.request)
            f.decoding = { f.failWrites = true; f.failPoison = true }
            recognitionAssertEqual(await handle.recognize([0], pass: .warmup).native, .failed(.preparationUnavailable))
            XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
            XCTAssertEqual(try f.ledger().entries.last?.key.p, .explicitSyntheticWarmup)
            XCTAssertNotNil(try f.ledger().entries.last?.pending)
        }
        f.decoding = nil; f.failWrites = false; f.failPoison = false
        _ = try f.owner(clean: false)
        XCTAssertEqual(try f.ledger().entries.last?.unresolved, 1)
        XCTAssertEqual(try f.ledger().entries.first?.unresolved, 0)
    }
    func testBottomParameterRefusalIsBeforeEntryAndKeepsLedgerEmpty() async throws {
        let f = try fixture(), owner = try f.owner()
        var factory = f.factory(owner)
        factory.guardedNative = { _, _, _ in throw PreparationRefusal.unsupportedSelection }
        await recognitionAssertThrows(try await factory.acquire(request: f.request))
        XCTAssertTrue(try f.ledger().entries.isEmpty); XCTAssertEqual(f.entries, 0)
    }
    func testInvalidSchemaCountersDuplicateKeysAndPrivateFifoRefusePreserve() async throws {
        for mutation in 0..<5 {
            let f = try fixture()
            try f.seed { ledger, key, _ in ledger.entries = [PreparationEntry(key: key)] }
            let file = f.health.appendingPathComponent("health.json")
            if mutation == 4 {
                try FileManager.default.removeItem(at: file)
                XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            } else {
                var ledger = try f.ledger()
                if mutation == 0 { ledger.entries[0].unresolved = 3 }
                if mutation == 1 { ledger.entries.append(ledger.entries[0]) }
                if mutation == 2 { ledger.entries[0].unresolved = -1 }
                var data = try JSONEncoder().encode(ledger)
                if mutation == 3 {
                    data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"schema\":2", with: "\"schema\":3").utf8)
                }
                try data.write(to: file)
            }
            let owner = try f.owner(clean: false)
            XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
            await recognitionAssertThrows(try await f.factory(owner).acquire(request: f.request)); XCTAssertEqual(f.entries, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }
}


extension RecognitionPreparationTests {
    private func mapperFactory(_ f: PreparationFixture, _ owner: RecognitionPreparation, _ probe: TimedNativeProbe) -> RecognitionFactory {
        var factory = f.factory(owner)
        factory.guardedNative = { _, _, permit in try permit.nativeEntry { f.entries += 1; return probe.context() } }
        return factory
    }
    private func bytes(_ f: PreparationFixture) throws -> Data { try Data(contentsOf: f.health.appendingPathComponent("health.json")) }
    private func first(_ f: PreparationFixture) throws -> PreparationEntry? { try f.ledger().entries.first { $0.key.p == .firstRealAudioRequest } }

    func testB53EveryPassAndTimedUsesConcreteFullMapperWithOneFirstEnvelope() async throws {
        for kind in 0..<8 {
            let f = try fixture(), owner = try f.owner(), probe = TimedNativeProbe(bytes: [[]], starts: [0], ends: [1])
            probe.multilingual = false
            let factory = mapperFactory(f, owner, probe)
            let handle = try await factory.acquire(request: f.request, operation: PendingOperation(name: "first mapper origin"))
            XCTAssertTrue(handle.client is WhisperTranscriber)
            var attempts: [UUID] = []
            probe.hold = {
                let record = try! XCTUnwrap(self.first(f))
                XCTAssertEqual(record.key.p, .firstRealAudioRequest)
                XCTAssertEqual(record.pending?.launch, owner.launch)
                attempts.append(record.pending!.attempt)
                XCTAssertTrue(owner.hasActiveEntry)
            }
            let passes: [RecognitionHandle.Pass] = [.fullFinal, .command, .streamHead("private"), .streamTail("private"), .windowedFinal("private"), .hudPreview, .fullFinal, .fullFinal]
            let result: RecognitionNativeOutcome
            if kind == 6 {
                let timed = await handle.timedFileResult(samples: [Float](repeating: 0.2, count: 8000))
                guard case .pass(let pass) = timed.provenance else { return XCTFail("timed pass") }
                result = pass.native
            } else {
                result = await handle.recognize(kind == 7 ? [0.2] : [Float](repeating: 0.2, count: 8000), pass: passes[kind]).native
            }
            guard case .completed(let evidence) = result else { return XCTFail("Concrete full mapper must complete, including empty text") }
            XCTAssertEqual(evidence.text, "")
            XCTAssertEqual(probe.calls, 1); XCTAssertEqual(attempts.count, 1)
            XCTAssertNil(try first(f)?.pending); XCTAssertEqual(try first(f)?.outcome, .completed)
            let completed = try bytes(f)
            probe.hold = nil
            let fresh = try await factory.acquire(request: f.request, resident: handle.resident, operation: PendingOperation(name: "new permit"))
            XCTAssertEqual(fresh.instance, handle.instance)
            for pass in passes { _ = await fresh.recognize([0.2], pass: pass) }
            XCTAssertEqual(try bytes(f), completed)
            XCTAssertEqual(f.entries, 1)
            probe.hold = nil
        }
    }

    func testB53AutoLanguageMultipleFullCallsStayInsideSamePendingAttempt() async throws {
        let f = try fixture(), owner = try f.owner(), p = TimedNativeProbe(bytes: [[]], starts: [0], ends: [1])
        p.multilingual = true
        var api = WhisperCContext.API()
        api.multilingual = true; api.knowsLanguage = { ["en", "es"].contains($0) }
        api.spokenLanguage = { p.probes += 1; return "es" }
        api.full = { _, _, _ in p.calls += 1; p.hold?(); return 0 }
        let text = strdup("auto native text")!
        defer { free(text) }
        api.count = { 1 }; api.text = { _ in UnsafePointer(text) }
        var factory = f.factory(owner)
        factory.guardedNative = { _, _, permit in try permit.nativeEntry { WhisperCContext(api: api) } }
        var settings = Settings(); settings.whisperModelPath = f.request.modelPath; settings.language = nil
        let handle = try await factory.acquire(request: RecognitionRequest(settings: settings))
        var attempts: [UUID] = []
        p.hold = { attempts.append(try! self.first(f)!.pending!.attempt) }
        _ = await handle.recognize([0.2], pass: .fullFinal)
        XCTAssertGreaterThan(p.calls, 1); XCTAssertEqual(Set(attempts).count, 1)
        XCTAssertEqual(try f.ledger().entries.filter { $0.key.p == .firstRealAudioRequest }.count, 1)
        XCTAssertEqual(try first(f)?.outcome, .completed); p.hold = nil
    }

    func testB53SkipAssemblyAbortAndTimedPreflightNeverFabricateCompletedFirstUse() async throws {
        let f = try fixture(), owner = try f.owner(), p = TimedNativeProbe()
        let handle = try await mapperFactory(f, owner, p).acquire(request: f.request)
        let before = try bytes(f)
        _ = await handle.finalResult(samples: [0], window: nil)
        _ = await handle.commandResult(samples: [0])
        _ = await handle.finalResult(samples: [0], window: handle.window(confirmedText: "owned", cutSample: 1))
        let abort = await handle.recognize([0.2], pass: .hudPreview, shouldAbort: { _ = owner.admissionEpoch; return true })
        XCTAssertEqual(abort.native, .canceled); XCTAssertEqual(p.calls, 0); XCTAssertEqual(try bytes(f), before)
        _ = await handle.timedFileResult(samples: [])
        XCTAssertEqual(p.calls, 0); XCTAssertEqual(try first(f)?.outcome, .returnedFailure)
        XCTAssertNil(try first(f)?.pending)
        let failed = try bytes(f)
        _ = await handle.recognize([0.2], pass: .fullFinal)
        XCTAssertEqual(p.calls, 0); XCTAssertEqual(try bytes(f), failed)
        let fresh = try await mapperFactory(f, owner, p).acquire(request: f.request, resident: handle.resident)
        XCTAssertNotEqual(fresh.instance, handle.instance)
        p.layers = 2; p.vocab = 51_864
        let unsupported = try await mapperFactory(f, owner, p).acquire(request: f.request)
        _ = await unsupported.timedFileResult(samples: [0.2])
        XCTAssertEqual(p.calls, 0); XCTAssertEqual(try first(f)?.outcome, .returnedFailure)
    }

    func testB53NativeOutcomesCancellationAndLatePersistenceKeepReturnedEvidence() async throws {
        for variant in 0..<8 {
            let f = try fixture(), owner = try f.owner(), p = TimedNativeProbe(bytes: [Array("returned".utf8)], starts: [0], ends: [1])
            let op = PendingOperation(name: "real outcome"), handle = try await mapperFactory(f, owner, p).acquire(request: f.request, operation: op)
            var abort = false
            if [1, 2].contains(variant) { p.status = -7 }
            p.pollAbort = [2, 7].contains(variant)
            p.hold = {
                if [2, 3, 7].contains(variant) { abort = true }
                if variant == 4 { op.revoke() }
                if [5, 6].contains(variant) { f.failWrites = true; f.failPoison = variant == 6 }
            }
            let result = await handle.recognize([0.2], pass: .streamHead(""), shouldAbort: { _ = owner.admissionEpoch; return abort })
            if variant == 1 { XCTAssertEqual(result.native, .failed(.nativeDecode)) }
            else if variant == 2 { XCTAssertEqual(result.native, .canceled) }
            else { guard case .completed = result.native else { return XCTFail("Exact status-zero native evidence must survive refusal") } }
            XCTAssertEqual(result.canceled, variant >= 2)
            XCTAssertEqual(result.text, variant == 0 ? "returned" : nil)
            XCTAssertEqual(p.calls, 1); XCTAssertFalse(owner.hasActiveEntry)
            if variant < 5 || variant == 7 {
                XCTAssertNil(try first(f)?.pending)
                XCTAssertEqual(try first(f)?.outcome, variant == 0 ? .completed : (variant == 1 ? .returnedFailure : .canceled))
                let saved = try bytes(f)
                p.hold = nil
                if variant != 0 {
                    _ = await handle.recognize([0.2], pass: .fullFinal)
                    _ = await handle.recognize([0], pass: .warmup)
                    XCTAssertEqual(p.calls, 1); XCTAssertEqual(try bytes(f), saved)
                }
            } else {
                XCTAssertTrue(owner.persistenceFailed)
                XCTAssertEqual(owner.snapshot.status, .trackingUnavailable)
                if variant == 6 { XCTAssertNotNil(try first(f)?.pending) }
                else { XCTAssertTrue(FileManager.default.fileExists(atPath: f.health.appendingPathComponent("quarantine").path)) }
            }
            p.hold = nil
        }
    }

    func testB53EveryFirstBeginAndTerminalBoundaryFailureIsFinite() async throws {
        for point in [PrivatePreparationStorage.Boundary.createTemp, .write, .fileSync, .rename, .directorySync] {
            for terminal in [false, true] {
                let f = try fixture(), owner = try f.owner(), p = TimedNativeProbe(bytes: [[]], starts: [0], ends: [1])
                let handle = try await mapperFactory(f, owner, p).acquire(request: f.request)
                if terminal { p.hold = { f.fail = point } } else { f.fail = point }
                let result = await handle.recognize([0.2], pass: .fullFinal)
                XCTAssertEqual(p.calls, terminal ? 1 : 0)
                if terminal { guard case .completed = result.native else { return XCTFail("Returned native success erased") }; XCTAssertTrue(owner.persistenceFailed) }
                else { XCTAssertEqual(result.native, .failed(.preparationUnavailable)); XCTAssertFalse(owner.persistenceFailed) }
                XCTAssertTrue(result.canceled); XCTAssertFalse(owner.hasActiveEntry)
                f.fail = nil; p.hold = nil
            }
        }
    }

    func testB53LostFirstRetirementReconstructsUnknownOnceAndFirstHoldDefeatsRetry() async throws {
        let f = try fixture()
        do {
            let owner = try f.owner(), p = TimedNativeProbe(bytes: [[]], starts: [0], ends: [1])
            let handle = try await mapperFactory(f, owner, p).acquire(request: f.request)
            p.hold = { f.failWrites = true; f.failPoison = true }
            let result = await handle.recognize([0.2], pass: .fullFinal)
            guard case .completed = result.native else { return XCTFail("Native result") }
            XCTAssertTrue(result.canceled); p.hold = nil
        }
        f.failWrites = false; f.failPoison = false
        do {
            let owner = try f.owner(clean: false)
            XCTAssertEqual(try first(f)?.unresolved, 1)
            let saved = try bytes(f)
            owner.configure(enabled: true, consent: f.consent, selection: f.epoch)
            XCTAssertEqual(try bytes(f), saved)
        }
        try f.seedPending(.firstRealAudioRequest, count: 1)
        let owner = try f.owner(clean: false), factory = f.factory(owner)
        await recognitionAssertThrows(try await factory.acquire(request: f.request))
        let saved = try bytes(f)
        XCTAssertEqual(try first(f)?.unresolved, 2)
        XCTAssertThrowsError(try owner.retryOnce(token: owner.snapshot.token, operation: PendingOperation(name: "retry"), identity: factory.resolve(f.request)))
        XCTAssertEqual(try bytes(f), saved)
        try owner.reset(token: owner.snapshot.token)
        _ = try await factory.acquire(request: f.request, operation: PendingOperation(name: "new origin after Reset"))
    }

    func testB53CompetingClaimsHoldActualExitAndNeverReviveResidentAfterReset() async throws {
        let f = try fixture(), owner = try f.owner(), factory = f.factory(owner)
        let operation = PendingOperation(name: "held first"), handle = try await factory.acquire(request: f.request, operation: operation)
        let competitor = try await factory.acquire(request: f.request, resident: handle.resident, operation: PendingOperation(name: "competing permit"))
        let resident = try XCTUnwrap(handle.resident), entered = expectation(description: "first full held"), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        f.decoding = { entered.fulfill(); gate.wait() }
        let work = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) {
            let result = await handle.recognize([0.2], pass: .streamHead(""))
            guard case .completed = result.native else { return XCTFail("Native return retained") }
            XCTAssertTrue(result.canceled)
        }
        await fulfillment(of: [entered], timeout: 3)
        let pending = try bytes(f)
        recognitionAssertEqual(await competitor.recognize([0.2], pass: .fullFinal).native, .failed(.preparationUnavailable))
        XCTAssertEqual(try bytes(f), pending); XCTAssertEqual(f.decodes, 1)
        operation.revoke()
        let retired = try bytes(f)
        XCTAssertTrue(owner.hasActiveEntry); XCTAssertNil(try first(f)?.pending)
        XCTAssertThrowsError(try owner.reset(token: owner.snapshot.token))
        await recognitionAssertThrows(try await factory.acquire(request: f.request, resident: resident, policy: .readOnlyCatalog))
        gate.signal(); await work.value
        XCTAssertFalse(owner.hasActiveEntry); XCTAssertEqual(try bytes(f), retired)
        f.decoding = nil
        try owner.reset(token: owner.snapshot.token)
        let permit = try XCTUnwrap(owner.authorize(identity: resident.identity, policy: .standard, resident: resident, operation: PendingOperation(name: "new permission")))
        XCTAssertFalse(permit.canBorrow(resident.preparation))
        XCTAssertThrowsError(try permit.constructed(resident.preparation), "Never restamp an old instance")
        let new = try await factory.acquire(request: f.request, resident: resident)
        XCTAssertNotEqual(new.instance, resident.instance)
    }

    func testB53CompletedResidentResetSelectionConsentAndExitedPermitNeverBorrowOldScope() async throws {
        for mutation in 0..<4 {
            let f = try fixture(), owner = try f.owner(), factory = f.factory(owner)
            let operation = PendingOperation(name: "setup"), handle = try await factory.acquire(request: f.request, operation: operation)
            _ = await handle.recognize([0], pass: .warmup)
            _ = await handle.recognize([0.2], pass: .fullFinal)
            let resident = try XCTUnwrap(handle.resident)
            if mutation == 0 { try owner.reset(token: owner.snapshot.token) }
            if mutation == 1 { f.epoch = UUID(); owner.selectionChanged(f.epoch) }
            if mutation == 2 { f.consent = UUID(); try owner.prepareConsent(f.consent); owner.configure(enabled: true, consent: f.consent, selection: f.epoch) }
            if mutation == 3 { operation.finish() }
            let before = try bytes(f), calls = f.decodes
            _ = await handle.recognize([0.2], pass: .fullFinal)
            XCTAssertEqual(f.decodes, calls); XCTAssertEqual(try bytes(f), before)
            if mutation < 3 {
                await recognitionAssertThrows(try await factory.acquire(request: f.request, resident: resident, policy: .readOnlyCatalog))
                let new = try await factory.acquire(request: f.request, resident: resident, operation: PendingOperation(name: "new scope"))
                XCTAssertNotEqual(new.instance, resident.instance)
            } else {
                let new = try await factory.acquire(request: f.request, resident: resident, operation: PendingOperation(name: "fresh permit"))
                XCTAssertEqual(new.instance, resident.instance)
                _ = await new.recognize([0.2], pass: .fullFinal)
                XCTAssertEqual(try bytes(f), before)
            }
        }
    }

    func testB53LegacyVersionsPreserveBytesRefuseResetRetryAndNeedNewConsent() async throws {
        for variant in 0..<5 {
            let f = try fixture()
            try f.seed { ledger, construction, _ in
                if variant > 0 { ledger.entries = [PreparationEntry(key: construction, unresolved: variant == 2 ? 2 : 0,
                    pending: variant == 1 ? PreparationPending(attempt: UUID(), launch: UUID(), operation: UUID(), selection: f.epoch) : nil)] }
                if variant >= 3 {
                    for n in 1..<(variant == 4 ? 9 : 8) {
                        let id = RecognitionIdentity(engine: .whisper, selection: f.request.selection,
                            artifact: .admittedCatalog(id: "legacy\(n)", expectedSHA256: ModelCatalog.default.sha256, expectedBytes: f.generation.bytes),
                            generation: f.generation, runtime: f.runtime, unknownRevisionScope: nil)
                        ledger.entries.append(PreparationEntry(key: try! PreparationKey(identity: id, build: f.build, phase: .nativeConstruction)))
                    }
                }
            }
            let file = f.health.appendingPathComponent("health.json")
            let original = Data(String(decoding: try bytes(f), as: UTF8.self).replacingOccurrences(of: "\"schema\":2", with: "\"schema\":1").utf8)
            try original.write(to: file)
            let legacy = try JSONDecoder().decode(PreparationLedger.self, from: original)
            if variant < 4 { XCTAssertNoThrow(try legacy.validate()) } else { XCTAssertThrowsError(try legacy.validate()) }
            let owner = try f.owner(clean: false), factory = f.factory(owner)
            XCTAssertFalse(owner.persistenceFailed)
            await recognitionAssertThrows(try await factory.acquire(request: f.request))
            XCTAssertThrowsError(try owner.reset(token: owner.snapshot.token))
            XCTAssertThrowsError(try owner.retryOnce(token: owner.snapshot.token, operation: PendingOperation(name: "legacy retry"), identity: factory.resolve(f.request)))
            XCTAssertEqual(try bytes(f), original)
            owner.revokeDraft(); owner.configure(enabled: false, consent: nil, selection: f.epoch)
            XCTAssertEqual(owner.snapshot.status, .off); XCTAssertEqual(try bytes(f), original)
            f.consent = UUID(); try owner.prepareConsent(f.consent)
            owner.configure(enabled: true, consent: f.consent, selection: f.epoch)
            XCTAssertEqual(try f.ledger().schema, 2)
            _ = try await factory.acquire(request: f.request)
        }
        let f = try fixture(); try f.seedPending(.firstRealAudioRequest)
        let old = Data(String(decoding: try bytes(f), as: UTF8.self).replacingOccurrences(of: "\"schema\":2", with: "\"schema\":1").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PreparationLedger.self, from: old).validate())
        let new = try f.ledger()
        XCTAssertFalse(new.schema == 1 && new.entries.count <= 8, "Frozen old validator refuses schema2; no old binary")
    }

    func testB53AdmissionUnavailableDoesNotFabricateRetirementDebtOrEraseBytes() async throws {
        for variant in 0..<5 {
            let f = try fixture()
            do { _ = try f.owner() }
            let file = f.health.appendingPathComponent("health.json")
            switch variant {
            case 0: try FileManager.default.removeItem(at: file)
            case 1: try Data("corrupt".utf8).write(to: file)
            case 2: try Data("{\"schema\":77}".utf8).write(to: file)
            case 3: try Data(repeating: 32, count: 16_385).write(to: file)
            default: try Data("{\"schema\":2,\"consent\":\"bad\"}".utf8).write(to: file)
            }
            let original = try? Data(contentsOf: file), owner = try f.owner(clean: false)
            XCTAssertFalse(owner.persistenceFailed)
            if variant == 2 { XCTAssertThrowsError(try owner.reset(token: owner.snapshot.token)); XCTAssertThrowsError(try owner.prepareConsent(UUID())) }
            owner.revokeDraft(); owner.configure(enabled: false, consent: nil, selection: f.epoch)
            XCTAssertEqual(owner.snapshot.status, .off)
            XCTAssertEqual(try? Data(contentsOf: file), original)
        }
    }

    func testB53VersionSpecificBoundsKeyPrivacyAndSinglePending() async throws {
        let f = try fixture(), identity = try f.factory().resolve(f.request)
        let key = try PreparationKey(identity: identity, build: f.build, phase: .firstRealAudioRequest)
        var ledger = PreparationLedger(consent: f.consent)
        ledger.entries = [PreparationEntry(key: key, unresolved: 2)]
        XCTAssertNoThrow(try ledger.validate())
        ledger.entries[0].unresolved = 3; XCTAssertThrowsError(try ledger.validate())
        ledger.entries[0].unresolved = -1; XCTAssertThrowsError(try ledger.validate())
        ledger.entries[0].unresolved = 0
        let pending = PreparationPending(attempt: UUID(), launch: UUID(), operation: UUID(), selection: UUID())
        ledger.entries[0].pending = pending; ledger.entries[0].consumed = pending.attempt
        XCTAssertThrowsError(try ledger.validate()); ledger.entries[0].consumed = nil
        let other = try PreparationKey(identity: identity, build: f.build, phase: .nativeConstruction)
        ledger.entries.append(PreparationEntry(key: other, pending: pending)); XCTAssertThrowsError(try ledger.validate())
        ledger.entries.removeLast()
        let data = try JSONEncoder().encode(ledger)
        for canary in ["PRIVATE_LANGUAGE", "PRIVATE_PROMPT", "/owned", "process-only", "PRIVATE_ERROR"] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(canary))
        }
        var keyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as? [String: Any])
        keyObject["b"] = NSNumber(value: Int64.max)
        keyObject["t"] = Double.greatestFiniteMagnitude; keyObject["c"] = Double.greatestFiniteMagnitude
        keyObject["i"] = NSNumber(value: UInt64.max)
        var lengths = Set<Int>()
        for quotes in 0...64 {
            keyObject["m"] = String(repeating: "\"", count: 32)
            keyObject["v"] = String(repeating: "\"", count: quotes) + String(repeating: "a", count: 64 - quotes)
            let candidate = try JSONDecoder().decode(PreparationKey.self, from: JSONSerialization.data(withJSONObject: keyObject))
            let size = try JSONEncoder().encode(candidate).count
            if size == 512 { XCTAssertNoThrow(try candidate.validate()); lengths.insert(size) }
            if size == 513 { XCTAssertThrowsError(try candidate.validate()); lengths.insert(size) }
        }
        XCTAssertEqual(lengths, Set([512, 513]))
        do { _ = try f.owner() }
        let clean = try bytes(f), file = f.health.appendingPathComponent("health.json")
        for size in [16_384, 16_385] {
            var padded = clean; padded.append(Data(repeating: 32, count: size - clean.count))
            try padded.write(to: file)
            if size == 16_384 {
                let reader = try f.storage()
                XCTAssertEqual(try reader.read(), padded)
            } else { XCTAssertThrowsError(try f.storage()) }
            XCTAssertEqual(try Data(contentsOf: file), padded)
        }
    }
}

extension RecognitionPreparationTests {
    /// Opt-in only. External control, rather than XCTest success, owns this host's expected forced exit.
    func testB53OptInDisposableFirstRequestOwner() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["B53_HOST_MODE"] == "owner", let path = env["B53_HOST_ROOT"],
              let nonce = env["B53_HOST_NONCE"], let consent = UUID(uuidString: nonce) else {
            throw XCTSkip("B53 disposable fake-native owner requires its separately owned control")
        }
        let root = URL(fileURLWithPath: path)
        let f = try PreparationFixture(root: root, preserveRoot: true)
        f.consent = consent; f.epoch = consent
        f.build = .init(app: consent, native: consent, architecture: "arm64")
        let owner = try f.owner(), p = TimedNativeProbe(bytes: [[]], starts: [0], ends: [1])
        let factory = mapperFactory(f, owner, p)
        let op = PendingOperation(name: "B53 owned fake request")
        let handle = try await factory.acquire(request: f.request, operation: op)
        p.hold = {
            do {
                let entry = try XCTUnwrap(self.first(f)), pending = try XCTUnwrap(entry.pending)
                XCTAssertEqual(pending.launch, owner.launch); XCTAssertEqual(pending.operation, op.id)
                let object = ["nonce": nonce, "pid": String(getpid()), "attempt": pending.attempt.uuidString,
                    "launch": pending.launch.uuidString, "operation": pending.operation.uuidString,
                    "selection": pending.selection.uuidString, "phase": entry.key.p.rawValue]
                let file = root.appendingPathComponent("entered.json")
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: [.withoutOverwriting])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let stream = try FileHandle(forWritingTo: file); try stream.synchronize(); try stream.close()
                let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard directory >= 0 else { throw PreparationRefusal.trackingUnavailable }
                defer { close(directory) }
                guard fsync(directory) == 0 else { throw PreparationRefusal.trackingUnavailable }
                // No timeout can be mistaken for a native return. The exact external owned host is killed once.
                DispatchSemaphore(value: 0).wait()
                XCTFail("Disposable owner must never resume its fake full call")
            } catch { XCTFail("Durable owned handshake failed: \(error)") }
        }
        _ = await handle.recognize([0.2], pass: .fullFinal)
        XCTFail("External control did not terminate its owner")
    }

    func testB53OptInFreshReaderConsumesOneMatchingFirstUnknownOnce() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["B53_HOST_MODE"] == "reader", let path = env["B53_HOST_ROOT"],
              let nonce = env["B53_HOST_NONCE"], let consent = UUID(uuidString: nonce) else {
            throw XCTSkip("B53 fresh reader requires its separately owned control")
        }
        let root = URL(fileURLWithPath: path)
        let f = try PreparationFixture(root: root, existing: true, preserveRoot: true)
        f.consent = consent; f.epoch = consent
        f.build = .init(app: consent, native: consent, architecture: "arm64")
        let handshake = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("entered.json"))) as? [String: String])
        XCTAssertEqual(handshake["nonce"], nonce); XCTAssertEqual(handshake["phase"], PreparationPhase.firstRealAudioRequest.rawValue)
        let original = try XCTUnwrap(first(f)), attempt = try XCTUnwrap(original.pending?.attempt)
        XCTAssertEqual(attempt.uuidString, handshake["attempt"]); XCTAssertEqual(original.unresolved, 0)
        do {
            let reader = try f.owner(clean: false)
            XCTAssertEqual(reader.snapshot.status, .ready)
            let entry = try XCTUnwrap(first(f))
            XCTAssertEqual(entry.key, original.key); XCTAssertEqual(entry.unresolved, 1)
            XCTAssertEqual(entry.consumed, attempt); XCTAssertNil(entry.pending); XCTAssertNil(entry.outcome)
        }
        let consumed = try bytes(f)
        do {
            let second = try f.owner(clean: false)
            XCTAssertEqual(second.snapshot.status, .ready)
            XCTAssertEqual(try first(f)?.unresolved, 1); XCTAssertEqual(try bytes(f), consumed)
        }
        XCTAssertEqual(f.entries, 0); XCTAssertEqual(f.decodes, 0)
        let receipt = ["nonce": nonce, "attempt": attempt.uuidString, "phase": PreparationPhase.firstRealAudioRequest.rawValue,
                       "unresolved": "1", "secondReadIncrement": "0", "nativeEntries": "0"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: root.appendingPathComponent("reader.json"), options: [.withoutOverwriting])
    }
}
