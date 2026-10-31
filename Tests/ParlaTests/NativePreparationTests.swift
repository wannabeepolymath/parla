import AppKit
import Darwin
import XCTest
@testable import ParlaCore
@testable import Parla

final class PreparationAppFaults {
    var settings = false, journal = false, build = false
    var settingsWrites = 0, journalWrites = 0, buildReads = 0
}
@MainActor final class PreparationAppRig {
    let root: URL, health: URL
    let faults = PreparationAppFaults(), probe = FoundationNativeProbe()
    let store: SettingsStore, hub: HubModel, owner: NativePreparation
    var chain: Task<Void, Never>?, resident: RecognitionResident?
    var publications = 0, generalSaves = 0, passiveSaves = 0
    let epoch = UUID(), consent = UUID()
    init(enabled: Bool = true, persisted: ((Data) throws -> Data?)? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wave4c1-app-" + UUID().uuidString)
        self.root = root; health = root.appendingPathComponent("health")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try recordWave4BFixture(root, "created")
        let faults = self.faults, health = self.health, build = PreparationBuild(app: UUID(), native: UUID(), architecture: "arm64")
        let core = RecognitionPreparation(storage: {
            try PrivatePreparationStorage(root: health) { point in
                if point == .createTemp { faults.journalWrites += 1 }
                if faults.journal, point != .read { throw PreparationRefusal.trackingUnavailable }
            }
        }, build: {
            faults.buildReads += 1
            if faults.build { throw PreparationRefusal.unsupportedSelection }
            return build
        })
        owner = NativePreparation(core: core, catalogSelection: { RecognitionFactory.ownedModel(path: $0.modelPath, directory: URL(fileURLWithPath: "/owned")) != nil })
        store = SettingsStore(url: root.appendingPathComponent("settings.json"), credentials: testCredentialStore(), atomicWrite: { data, url in
            faults.settingsWrites += 1
            if faults.settings { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        hub = HubModel(store: store, history: HistoryStore(url: root.appendingPathComponent("history.json")),
            recordings: RecordingStore(directory: root.appendingPathComponent("recordings")))
        hub.modelSelectionEpoch = epoch
        var settings = Settings(); settings.whisperModelPath = "/owned/" + ModelCatalog.default.filename
        settings.cleanupEnabled = false; settings.recoveryAudioEnabled = false
        if enabled { try core.prepareConsent(consent); settings.nativePreparationSafeStartEnabled = true; settings.nativePreparationConsent = consent }
        try store.save(settings)
        if let persisted {
            let file = health.appendingPathComponent("health.json")
            if let bytes = try persisted(Data(contentsOf: file)) { try bytes.write(to: file) }
            else { try FileManager.default.removeItem(at: file) }
        }
        owner.configure(settings, epoch: epoch)
        probe.generation = .init(bytes: ModelCatalog.default.bytes, modified: 7)
        probe.multilingual = false; probe.outputs = [.init(status: 0)]
        hub.onPreparationDraftDisabled = { [unowned owner] in owner.revokeDraft() }
        hub.onPreparationConsent = { [unowned owner] in try owner.prepareConsent($0) }
        hub.onPreparationBeforeSave = { [unowned owner] in try owner.beforeSave($0) }
        hub.onPreparationSaved = { [unowned owner, unowned hub] in owner.configure($0, epoch: hub.modelSelectionEpoch) }
        hub.onPreparationSaveFailed = { [unowned owner] in if owner.core.isEnabled { owner.revokeDraft() } }
        hub.onPreparationSelection = { [unowned owner] in owner.changedSelection($0, request: $1) }
        hub.onPreparationAction = { [unowned owner] in owner.act($0, token: $1) }
        hub.onSaved = { [unowned self] in generalSaves += 1 }
        hub.onMouseBindingSaved = { [unowned self] in passiveSaves += 1 }
        owner.onChange = { [unowned hub] in hub.preparationSnapshot = $0 }
        owner.factory = { [unowned self] in factory }
        owner.resident = { [unowned self] in await MainActor.run { self.resident } }
        owner.publishResident = { [unowned self] handle in await MainActor.run { self.resident = handle.resident; self.publications += 1 } }
        owner.enqueue = { [unowned self] operation, work in
            chain = PendingOperationQueue.enqueue(previous: chain, operation: operation, completes: true, work: work,
                finished: { [unowned owner] in await MainActor.run { owner.refresh() } })
        }
        hub.refreshPreparationConfiguration()
    }
    var factory: RecognitionFactory {
        var value = probe.factory(); let bottom = value.native
        value.preparation = owner.core
        let store = store, core = owner.core
        value.preparationPermission = { let settings = store.load(); return store.lastError == nil && core.matchesSavedPermission(settings) }
        value.guardedNative = { path, compute, token in
            guard compute == .nativeDefaults else { throw PreparationRefusal.unsupportedSelection }
            return try token.nativeEntry { try bottom(path, compute) }
        }
        return value
    }
    var request: RecognitionRequest { RecognitionRequest(settings: store.load()) }
    func close() async throws {
        await chain?.value
        probe.construct = nil; probe.decode = nil; resident = nil
        try FileManager.default.removeItem(at: root)
        try recordWave4BFixture(root, "removed")
    }
}

@MainActor final class NativePreparationTests: XCTestCase {
    func testActualHubConsentBeforeFlagAndPassiveMixedNetZeroSavesNeverStartSetup() async throws {
        let r = try PreparationAppRig(enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.health.path))
        r.hub.setPreparationEnabled(true); r.hub.flushPendingSave()
        XCTAssertTrue(r.store.load().nativePreparationSafeStartEnabled)
        let ledger = try JSONDecoder().decode(PreparationLedger.self, from: Data(contentsOf: r.health.appendingPathComponent("health.json")))
        XCTAssertEqual(ledger.consent, r.store.load().nativePreparationConsent)
        XCTAssertEqual(r.generalSaves, 0); XCTAssertEqual(r.faults.buildReads, 0); XCTAssertTrue(r.probe.paths.isEmpty)
        r.hub.settings.canceledCaptureUndoEnabled = true; r.hub.settings.clipboardReceiptRestoreEnabled = true
        r.hub.settings.keepLastOriginalEnabled = true; r.hub.flushPendingSave()
        r.hub.setPreparationEnabled(false); r.hub.setPreparationEnabled(true); r.hub.setPreparationEnabled(false); r.hub.flushPendingSave()
        XCTAssertFalse(r.store.load().nativePreparationSafeStartEnabled)
        XCTAssertEqual(r.generalSaves, 0); XCTAssertTrue(r.probe.paths.isEmpty)
        r.hub.settings.showHudAlways.toggle(); r.hub.flushPendingSave()
        XCTAssertEqual(r.generalSaves, 1)
        try await r.close()
    }
    func testSaveFailureNeverClaimsProtectedAndOldConsentCannotRevive() async throws {
        let r = try PreparationAppRig(enabled: false)
        r.faults.settings = true
        r.hub.setPreparationEnabled(true); r.hub.flushPendingSave()
        XCTAssertFalse(r.store.load().nativePreparationSafeStartEnabled)
        XCTAssertNotNil(r.hub.saveError); XCTAssertNotEqual(r.owner.snapshot.status, .ready)
        await recognitionAssertThrows(try await r.factory.acquire(request: r.request))
        XCTAssertTrue(r.probe.paths.isEmpty)
        r.faults.settings = false
        r.hub.setPreparationEnabled(false); r.hub.flushPendingSave()
        r.hub.setPreparationEnabled(true); r.hub.flushPendingSave()
        XCTAssertEqual(r.owner.snapshot.status, .ready)
        try await r.close()
    }
    func testActualTokenMenuAndRetryActionPreparesOnlyOnceAndNeverResumesOrigin() async throws {
        let r = try PreparationAppRig(), token = r.owner.snapshot.token
        let actions = NativePreparationMenuActions { action, token in r.owner.act(action, token: token) }
        let menu = NSMenuItem(); menu.representedObject = NativePreparationMenuRoute(.retry, token)
        actions.invoke(menu); actions.invoke(menu)
        await r.chain?.value
        XCTAssertEqual(r.probe.paths.count, 1); XCTAssertEqual(r.probe.calls.count, 1)
        XCTAssertEqual(r.probe.calls[0].samples, [Float](repeating: 0, count: 16_000)); XCTAssertNil(r.probe.calls[0].prompt)
        XCTAssertEqual(r.publications, 1); XCTAssertEqual(r.generalSaves, 0)
        let data = try Data(contentsOf: r.health.appendingPathComponent("health.json")), writes = r.faults.journalWrites
        for _ in 0..<30 { _ = r.owner.snapshot; _ = r.hub.preparationSnapshot; _ = r.owner.cachedRefusal }
        XCTAssertEqual(r.faults.journalWrites, writes)
        XCTAssertEqual(try Data(contentsOf: r.health.appendingPathComponent("health.json")), data)
        let stale = r.owner.snapshot.token
        r.hub.settings.whisperModelPath = "/owned/" + ModelCatalog.all[1].filename
        r.owner.act(.retry, token: stale)
        XCTAssertEqual(r.probe.paths.count, 1)
        r.hub.flushPendingSave()
        try await r.close()
    }
    func testRetryUnsupportedBuildSurfacesCurrentRefusalWithoutEnqueueOrNativeEntry() async throws {
        let r = try PreparationAppRig(), token = r.owner.snapshot.token
        let writes = r.faults.journalWrites
        r.faults.build = true
        r.owner.act(.retry, token: token)
        XCTAssertEqual(r.owner.snapshot.status, .unsupportedSelection)
        XCTAssertEqual(r.hub.preparationSnapshot.refusal, .unsupportedSelection)
        XCTAssertEqual(r.owner.cachedRefusal, .unsupportedSelection)
        XCTAssertNil(r.chain); XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertTrue(r.probe.calls.isEmpty)
        XCTAssertEqual(r.faults.buildReads, 1); XCTAssertEqual(r.faults.journalWrites, writes)
        let refused = r.owner.snapshot
        r.owner.act(.retry, token: token)
        XCTAssertEqual(r.owner.snapshot, refused); XCTAssertEqual(r.faults.buildReads, 1)
        try await r.close()
    }
    func testEnabledPreparationWorkIsOffMainAndOneBarrierThroughActualExit() async throws {
        let r = try PreparationAppRig(), entered = expectation(description: "constructor off main"), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        r.probe.construct = { XCTAssertFalse(Thread.isMainThread); entered.fulfill(); gate.wait() }
        let operation = PendingOperation(name: "Setup"), factory = r.factory, request = r.request
        let first = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true, work: {
            do { _ = try await RecognitionAcquisition.prepareOffMain(request: request, resident: nil, factory: factory, operation: operation) } catch { }
        })
        r.chain = first
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(r.owner.core.hasActiveEntry)
        let secondEntered = expectation(description: "next serial work")
        r.chain = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "later"), work: { secondEntered.fulfill() })
        r.hub.setPreparationEnabled(false)
        XCTAssertThrowsError(try r.owner.beforeSave(r.hub.settings))
        XCTAssertTrue(r.owner.core.hasActiveEntry); XCTAssertEqual(r.probe.releases, 0)
        gate.signal(); await r.chain?.value
        await fulfillment(of: [secondEntered], timeout: 2)
        r.hub.flushPendingSave()
        XCTAssertFalse(r.store.load().nativePreparationSafeStartEnabled)
        XCTAssertEqual(r.probe.releases, 1); XCTAssertEqual(r.probe.calls.count, 0)
        try await r.close()
    }
    func testActualQuitParticipantWaitsNativeExitAndPreservesClipboardFailureHold() async throws {
        let r = try PreparationAppRig(), clipboard = ExperimentRig()
        XCTAssertTrue(clipboard.paste())
        let originalProvider = clipboard.current.provider
        let entered = expectation(description: "held warmup"), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        r.probe.decode = { entered.fulfill(); gate.wait() }
        let request = r.request, factory = r.factory, operation = PendingOperation(name: "Setup")
        r.chain = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true, work: {
            do { _ = try await RecognitionAcquisition.prepareOffMain(request: request, resident: nil, factory: factory, operation: operation) } catch { }
        })
        await fulfillment(of: [entered], timeout: 5)
        var update: ((Bool) -> Void)?, replies: [Bool] = []
        let replied = expectation(description: "once-only failed quit")
        let coordinator = TerminationCoordinator(clipboard: clipboard.delivery.beginShutdown, updater: { update = $0 },
            preparation: { r.owner.beginShutdown(chain: { r.chain }, reply: $0) }, cancelPreparation: r.owner.cancelShutdown,
            cancelClipboard: clipboard.delivery.cancelShutdown, cancelUpdater: {},
            reply: { replies.append($0); replied.fulfill() }, failure: {})
        XCTAssertEqual(coordinator.request(), .terminateLater)
        XCTAssertTrue(r.owner.core.hasActiveEntry)
        let ledger = try JSONDecoder().decode(PreparationLedger.self, from: Data(contentsOf: r.health.appendingPathComponent("health.json")))
        XCTAssertEqual(ledger.entries.last?.outcome, .cleanQuit); XCTAssertNil(ledger.entries.last?.pending)
        XCTAssertTrue(clipboard.current.provider === originalProvider)
        update?(true); XCTAssertTrue(replies.isEmpty)
        clipboard.board.writeResults = [false]; clipboard.fire(clipboard.timers[0])
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [false]); XCTAssertTrue(clipboard.delivery.restoreFailed); XCTAssertTrue(clipboard.delivery.isRestorePending)
        await recognitionAssertThrows(try await r.factory.acquire(request: request, operation: operation))
        gate.signal(); await r.chain?.value
        XCTAssertEqual(r.probe.releases, 1)
        // Old grant stays revoked after canceled quit. Only a fresh deliberate operation can prepare again.
        r.probe.decode = nil
        _ = try await r.factory.acquire(request: request, operation: PendingOperation(name: "fresh"))
        update?(true); XCTAssertEqual(replies, [false])
        try await r.close()
    }
    func testPreparationPersistenceFailureVetoesRealCoordinatorWithoutClipboardBlame() async throws {
        let r = try PreparationAppRig(), entered = expectation(description: "held constructor"), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        r.probe.construct = { entered.fulfill(); gate.wait() }
        let factory = r.factory, request = r.request
        r.chain = Task { _ = try? await Task.detached { try await factory.acquire(request: request) }.value }
        await fulfillment(of: [entered], timeout: 5)
        r.faults.journal = true
        let replied = expectation(description: "preparation persistence veto"), coordinator = TerminationCoordinator(
            clipboard: { $0(true) }, updater: { $0(true) }, preparation: { r.owner.beginShutdown(chain: { r.chain }, reply: $0) },
            cancelPreparation: r.owner.cancelShutdown, cancelClipboard: {}, cancelUpdater: {},
            reply: { XCTAssertFalse($0); replied.fulfill() }, failure: { XCTAssertTrue(r.owner.core.persistenceFailed) })
        XCTAssertEqual(coordinator.request(), .terminateLater)
        XCTAssertEqual(r.owner.snapshot.status, .trackingUnavailable)
        gate.signal(); await r.chain?.value
        await fulfillment(of: [replied], timeout: 2)
        r.faults.journal = false
        try await r.close()
    }
    func testRestartReservationActualUpdaterFailureOrderAndIndependentQuitStayClosed() async throws {
        for independentQuit in [false, true] {
            let r = try PreparationAppRig(), update = UpdateTerminationIntent()
            let operation = PendingOperation(name: "old"), handle = try await r.factory.acquire(request: r.request, operation: operation)
            XCTAssertTrue(r.owner.core.reserveRestart())
            if independentQuit { r.owner.core.beginQuit() }
            var replied = false
            update.request(waitingForInstall: true, committing: true, cancelInstall: {}, reply: { _ in
                replied = true
                XCTAssertEqual(r.owner.cachedRefusal(for: r.request), independentQuit ? .revoked : nil)
            })
            XCTAssertTrue(update.installFailed(releaseRestart: { r.owner.core.releaseRestart() }))
            XCTAssertTrue(replied); XCTAssertFalse(handle.preparationIsCurrent)
            do {
                _ = try await r.factory.acquire(request: r.request, operation: PendingOperation(name: "new"))
                XCTAssertFalse(independentQuit)
            } catch { XCTAssertTrue(independentQuit) }
            if independentQuit { await recognitionAssertThrows(try await r.factory.acquire(request: r.request)); r.owner.core.cancelQuit() }
            _ = try await r.factory.acquire(request: r.request, operation: PendingOperation(name: "deliberate after cancellation"))
            try await r.close()
        }
    }
    func testTryoutFiniteRefusalCompletesEmptyAndEvalHasZeroAppNamespaceAccess() async throws {
        let r = try PreparationAppRig()
        r.owner.core.revokeDraft()
        var reason: PreparationRefusal?
        recognitionAssertEqual(await RecognitionAcquisition.tryout(samples: [Float](repeating: 0.2, count: 8000), request: r.request,
            resident: nil, factory: r.factory, refused: { reason = $0 }), "")
        XCTAssertNotNil(reason); XCTAssertTrue(r.probe.paths.isEmpty)
        let data = try Data(contentsOf: r.health.appendingPathComponent("health.json")), builds = r.faults.buildReads
        let eval = EvalRecognition()
        try await eval.acquire(needsASR: true, request: { r.request }, factory: r.probe.factory())
        _ = await eval.transcribe([0.2], prompt: nil); eval.release()
        XCTAssertEqual(r.faults.buildReads, builds)
        XCTAssertEqual(try Data(contentsOf: r.health.appendingPathComponent("health.json")), data)
        try await r.close()
    }
}

private actor PreparationQueueGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
extension NativePreparationTests {
    func testQueuedPreparationCannotReviveAfterCanceledQuitKeepOrSavedOptOut() async throws {
        for action in 0..<3 {
            let r = try PreparationAppRig(), gate = PreparationQueueGate()
            r.chain = Task { await gate.wait() }
            if action == 1 {
                r.owner.act(.retry, token: r.owner.snapshot.token)
                r.owner.act(.keep, token: r.owner.snapshot.token)
            } else {
                let request = r.request, factory = r.factory, frozen = r.owner.core.admissionEpoch
                r.chain = PendingOperationQueue.enqueue(previous: r.chain, operation: PendingOperation(name: "queued setup"), work: {
                    do {
                        _ = try await RecognitionAcquisition.prepareOffMain(request: request, resident: nil, factory: factory,
                            operation: PendingOperation(name: "old queued"), preparationEpoch: frozen)
                        XCTFail("old work revived")
                    } catch { }
                })
                if action == 0 { r.owner.core.beginQuit(); r.owner.core.cancelQuit() }
                else { r.hub.setPreparationEnabled(false); r.hub.flushPendingSave() }
            }
            await gate.release(); await r.chain?.value
            XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertTrue(r.probe.calls.isEmpty); XCTAssertEqual(r.publications, 0)
            // Only a newly made request can now proceed; saved opt-out has no guard I/O.
            _ = try await r.factory.acquire(request: r.request, operation: PendingOperation(name: "fresh deliberate"))
            XCTAssertEqual(r.probe.paths.count, 1)
            try await r.close()
        }
    }
    func testExternalMalformedOrConsentChangedConfigurationFailsClosedAtRealFactory() async throws {
        let r = try PreparationAppRig()
        try Data("{\"nativePreparationSafeStartEnabled\":\"bad\"}".utf8).write(to: r.store.url)
        await recognitionAssertThrows(try await r.factory.acquire(request: r.request))
        XCTAssertTrue(r.probe.paths.isEmpty); XCTAssertNotNil(r.store.lastError)
        XCTAssertNotEqual(r.owner.core.snapshot.status, .ready)
        try await r.close()
    }
    func testEarlyCustomSelectionIsUnsupportedWithoutModelOrBuildProbe() async throws {
        let r = try PreparationAppRig()
        r.hub.settings.whisperModelPath = "/custom/ggml-base.en.bin"
        XCTAssertEqual(r.owner.snapshot.status, .unsupportedSelection)
        XCTAssertEqual(r.faults.buildReads, 0); XCTAssertTrue(r.probe.paths.isEmpty)
        r.hub.flushPendingSave()
        try await r.close()
    }
}

extension NativePreparationTests {
    func testRetainedAppAcquisitionCannotReturnUnpreparedOrHeldResident() async throws {
        let r = try PreparationAppRig(), request = r.request, factory = r.factory
        let handle = try await factory.acquire(request: request)
        recognitionAssertNil(await r.owner.retainedResident(request: request, resident: handle.resident, factory: factory))
        XCTAssertEqual(r.probe.paths.count, 1); XCTAssertTrue(r.probe.calls.isEmpty)
        _ = await handle.recognize([0], pass: .warmup)
        recognitionAssertNil(await r.owner.retainedResident(request: request, resident: handle.resident, factory: factory))
        _ = await handle.recognize([0.2], pass: .fullFinal)
        recognitionAssertNotNil(await r.owner.retainedResident(request: request, resident: handle.resident, factory: factory))
        r.owner.core.revokeDraft()
        recognitionAssertNil(await r.owner.retainedResident(request: request, resident: handle.resident, factory: factory))
        XCTAssertEqual(r.probe.paths.count, 1); XCTAssertEqual(r.probe.calls.count, 2)
        try await r.close()
    }
    func testFailedRetirementCannotBecomeSavedOptOutUntilExplicitOwnedResetSucceeds() async throws {
        let r = try PreparationAppRig()
        r.probe.construct = { r.faults.journal = true }
        await recognitionAssertThrows(try await r.factory.acquire(request: r.request))
        XCTAssertTrue(r.owner.core.persistenceFailed)
        r.hub.setPreparationEnabled(false); r.hub.flushPendingSave()
        XCTAssertTrue(r.store.load().nativePreparationSafeStartEnabled)
        XCTAssertNotNil(r.hub.saveError); XCTAssertNotEqual(r.owner.snapshot.status, .off)
        r.probe.construct = nil; r.faults.journal = false
        let owedBytes = try? Data(contentsOf: r.health.appendingPathComponent("quarantine"))
        XCTAssertThrowsError(try r.owner.prepareConsent(UUID()), "Explicit reconsent cannot bypass the required owned Reset")
        XCTAssertEqual(try? Data(contentsOf: r.health.appendingPathComponent("quarantine")), owedBytes)
        r.owner.act(.reset, token: r.owner.snapshot.token)
        r.hub.savePreparationDraft()
        XCTAssertFalse(r.store.load().nativePreparationSafeStartEnabled); XCTAssertEqual(r.owner.snapshot.status, .off)
        try await r.close()
    }
}


extension NativePreparationTests {
    func testB53ActualHubLegacyConsentRequiresOffOnAndAdmissionFaultCanSaveOff() async throws {
        for variant in 0..<4 {
            let r = try PreparationAppRig(persisted: { original in
                switch variant {
                case 0: return Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"schema\":2", with: "\"schema\":1").utf8)
                case 1: return Data("{\"schema\":99}".utf8)
                case 2: return Data("invalid".utf8)
                default: return nil
                }
            })
            let file = r.health.appendingPathComponent("health.json"), original = try? Data(contentsOf: file)
            XCTAssertFalse(r.owner.core.persistenceFailed)
            if variant == 0 {
                XCTAssertEqual(r.owner.snapshot.refusal, .consentRequired)
                r.owner.changedSelection(UUID(), request: r.request)
                XCTAssertEqual(r.owner.snapshot.refusal, .consentRequired)
                r.owner.act(.keep, token: r.owner.snapshot.token)
                XCTAssertEqual(r.owner.snapshot.refusal, .consentRequired)
            }
            let oldConsent = r.store.load().nativePreparationConsent
            let writes = r.faults.journalWrites
            r.owner.act(.retry, token: r.owner.snapshot.token)
            if variant == 0 { r.owner.act(.reset, token: r.owner.snapshot.token) }
            XCTAssertNil(r.chain); XCTAssertTrue(r.probe.paths.isEmpty)
            XCTAssertEqual(r.faults.journalWrites, writes)
            r.hub.setPreparationEnabled(false); r.hub.flushPendingSave()
            XCTAssertFalse(r.store.load().nativePreparationSafeStartEnabled); XCTAssertNil(r.hub.saveError)
            XCTAssertEqual(try? Data(contentsOf: file), original)
            if variant == 0 {
                r.hub.setPreparationEnabled(true); r.hub.flushPendingSave()
                XCTAssertNotEqual(r.store.load().nativePreparationConsent, oldConsent)
                XCTAssertEqual(r.owner.snapshot.status, .ready)
                XCTAssertEqual(try JSONDecoder().decode(PreparationLedger.self, from: Data(contentsOf: file)).schema, 2)
                XCTAssertTrue(r.probe.paths.isEmpty)
            }
            try await r.close()
        }
    }

    func testB53ProductionSetupExitedPermitAndNewRealAcquisitionUseSameResident() async throws {
        let r = try PreparationAppRig(), setup = PendingOperation(name: "setup"), factory = r.factory, request = r.request
        let prepared = try await RecognitionAcquisition.prepareOffMain(request: request, resident: nil, factory: factory, operation: setup)
        setup.finish()
        let warm = try Data(contentsOf: r.health.appendingPathComponent("health.json")), writes = r.faults.journalWrites
        _ = await prepared.recognize([0.2], pass: .fullFinal)
        XCTAssertEqual(r.probe.calls.count, 1); XCTAssertEqual(r.faults.journalWrites, writes)
        recognitionAssertNil(await r.owner.retainedResident(request: request, resident: prepared.resident, factory: factory))
        let current = try await RecognitionAcquisition.acquire(request: request, resident: prepared.resident, factory: factory,
            operation: PendingOperation(name: "ordinary fresh origin"))
        XCTAssertEqual(current.instance, prepared.instance)
        _ = await current.recognize([0.2], pass: .fullFinal)
        XCTAssertEqual(r.probe.calls.count, 2); XCTAssertNotEqual(try Data(contentsOf: r.health.appendingPathComponent("health.json")), warm)
        recognitionAssertNotNil(await r.owner.retainedResident(request: request, resident: current.resident, factory: factory))
        try await r.close()
    }

    func testB53HeldFirstRealRetiresButLifecycleQueueAndNativeOwnerStayUntilReturn() async throws {
        for action in 0..<5 {
            let r = try PreparationAppRig(), operation = PendingOperation(name: "first ordinary request")
            let handle = try await r.factory.acquire(request: r.request, operation: operation)
            let entered = expectation(description: "held real request"), gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            r.probe.decode = { entered.fulfill(); gate.wait() }
            var returned: RecognitionPassResult?, successor = false
            r.chain = PendingOperationQueue.enqueue(previous: nil, operation: operation, completes: true) {
                returned = await handle.recognize([0.2], pass: .streamHead(""))
            }
            await fulfillment(of: [entered], timeout: 3)
            let first = r.chain
            r.chain = PendingOperationQueue.enqueue(previous: first, operation: PendingOperation(name: "successor")) { successor = true }
            if action == 0 { operation.revoke() }
            if action == 1 { r.hub.setPreparationEnabled(false) }
            if action == 2 { r.owner.changedSelection(UUID(), request: r.request) }
            if action == 3 { r.owner.core.beginQuit() }
            if action == 4 { XCTAssertTrue(r.owner.core.reserveRestart()) }
            XCTAssertTrue(r.owner.core.hasActiveEntry); XCTAssertFalse(operation.hasExited); XCTAssertFalse(successor)
            let bytes = try Data(contentsOf: r.health.appendingPathComponent("health.json"))
            let ledger = try JSONDecoder().decode(PreparationLedger.self, from: bytes)
            XCTAssertNil(ledger.entries.last?.pending); XCTAssertEqual(ledger.entries.last?.key.p, .firstRealAudioRequest)
            XCTAssertThrowsError(try r.owner.core.reset(token: r.owner.core.snapshot.token))
            gate.signal(); await r.chain?.value
            let result = try XCTUnwrap(returned)
            guard case .completed = result.native else { return XCTFail("Returned evidence retained after lifecycle revoke") }
            XCTAssertTrue(result.canceled); XCTAssertTrue(successor); XCTAssertFalse(r.owner.core.hasActiveEntry)
            XCTAssertEqual(try Data(contentsOf: r.health.appendingPathComponent("health.json")), bytes)
            try await r.close()
        }
    }

    func testB53ProductionPreviewPhaseOnlyStopAndFreshFinalHaveDistinctFirstAttempts() async throws {
        let r = try PreparationAppRig(), op = PendingOperation(name: "preview then final")
        var settings = r.store.load(); settings.streamPreviewEnabled = true; settings.recognitionPreviewModelID = ModelCatalog.default.id
        let plan = try XCTUnwrap(RecognitionPreviewPlan(settings: settings, final: r.request, generation: 1,
            operationID: op.id, ordinaryPhysical: true, directory: URL(fileURLWithPath: "/owned")))
        var capturing = true, drafts = 0
        let preview = RecognitionPreviewCapture(plan: plan, operation: op, factory: r.factory, selectionEpoch: r.epoch,
            preparationEpoch: r.owner.core.admissionEpoch, capturing: { capturing },
            suffix: { _ in RecognitionPreviewSuffix(copying: [Float](repeating: 0.2, count: 32_000)) }, secure: { false },
            publish: { if case .draft = $0 { drafts += 1 } }, clear: {}, releaseAliases: {}, clock: { 0 }, pause: { capturing = false })
        r.probe.decode = { plan.phase.revoke() } // parent operation stays live; phase predicate reads admissionEpoch
        await preview.run()
        XCTAssertFalse(op.shouldAbort); XCTAssertEqual(drafts, 0)
        let before = try JSONDecoder().decode(PreparationLedger.self, from: Data(contentsOf: r.health.appendingPathComponent("health.json")))
        let attempt = try XCTUnwrap(before.entries.first { $0.key.p == .firstRealAudioRequest }?.consumed)
        XCTAssertEqual(before.entries.last?.outcome, .canceled)
        r.probe.decode = nil
        let final = try await preview.acquireFinal()
        _ = await final.finalResult(samples: [Float](repeating: 0.2, count: 8000), window: nil)
        let after = try JSONDecoder().decode(PreparationLedger.self, from: Data(contentsOf: r.health.appendingPathComponent("health.json")))
        XCTAssertNotEqual(after.entries.last?.consumed, attempt); XCTAssertEqual(after.entries.last?.outcome, .completed)
        XCTAssertEqual(r.probe.paths.count, 2); XCTAssertEqual(r.probe.calls.count, 2)
        try await r.close()
    }
}
