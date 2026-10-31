import Combine
import Darwin
import AppKit
import XCTest
@testable import Parla
@testable import ParlaCore

final class SavedAudioImportLifecycleTests: XCTestCase {
    @MainActor func testTerminationWaitsForActualHeldNativeAndCanceledIntentNeverRevivesReview() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let entered = expectation(description:"fake native entered"), exit = DispatchSemaphore(value:0)
        rig.native.decode = { entered.fulfill(); exit.wait() }
        let url = try rig.source(); rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe()
        await fulfillment(of:[entered],timeout:5)
        var replies:[Bool] = [], clipboard:((Bool)->Void)?, released = 0
        let termination = TerminationCoordinator(clipboard:{clipboard=$0},updater:{$0(true)},
            savedImports:{rig.saved.beginShutdown($0)},cancelSavedImports:{rig.saved.cancelShutdown()},
            cancelClipboard:{released += 1},cancelUpdater:{},reply:{replies.append($0)},failure:{})
        XCTAssertEqual(termination.request(),.terminateLater)
        XCTAssertTrue(replies.isEmpty); XCTAssertTrue(rig.saved.busy)
        clipboard?(false)
        XCTAssertEqual(replies,[false]); XCTAssertEqual(released,1)
        XCTAssertNil(rig.saved.review)
        exit.signal(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
        XCTAssertEqual(rig.saved.rows.count,1)
        try await rig.close()
    }
    @MainActor func testRestartReservationDrainsEvenWithNoHubPreparationParticipant() async throws {
        let rig = try SavedImportRig(); _ = try await rig.run()
        XCTAssertTrue(rig.saved.reserveRestart()); XCTAssertNil(rig.saved.review)
        await rig.saved.drain(); XCTAssertTrue(rig.saved.restartReady())
        rig.saved.releaseRestart(); XCTAssertNil(rig.saved.review)
        let id = try XCTUnwrap(rig.saved.rows.first?.id)
        rig.hub.openSavedAudioImport(id); await rig.saved.drain()
        XCTAssertNotNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
}


extension SavedAudioImportLifecycleTests {
    @MainActor func testDeleteRecordsIntentButDoesNotUnlinkHeldNativeSource() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let entered = expectation(description:"held native"), intent = expectation(description:"synced intent and deleting ledger"), gate = DispatchSemaphore(value:0)
        rig.native.decode = {entered.fulfill(); _ = gate.wait(timeout:.now()+5)}
        let original = try rig.source(); rig.hub.selectAudioImport(original); rig.hub.keepAudioImportAndTranscribe()
        await fulfillment(of:[entered],timeout:5)
        let job = try XCTUnwrap(rig.saved.job), source = try XCTUnwrap(job.token?.source)
        var seen = false
        let observation = rig.saved.$rows.sink {rows in
            if !seen, rows.contains(where:{$0.id == job.id && $0.deleting}) {seen = true; intent.fulfill()}
        }
        rig.hub.deleteSavedAudioImport(job.id)
        await fulfillment(of:[intent],timeout:5); observation.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath:rig.saved.store.storage.root.appendingPathComponent(source.uuidString.lowercased()+".source.wav").path))
        XCTAssertTrue(rig.saved.busy); XCTAssertNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
        rig.faults.reached = nil; gate.signal(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertTrue(rig.saved.rows.isEmpty,rig.saved.message ?? "no status")
        XCTAssertEqual(try Data(contentsOf:original),retainedSyntheticWAV())
        try await rig.close()
    }
    @MainActor func testActualAppRestartParticipantWaitsForNativeAndReleasesRejectedClaim() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let entered = expectation(description:"held native"), gate = DispatchSemaphore(value:0)
        rig.native.decode = {entered.fulfill(); _ = gate.wait(timeout:.now()+5)}
        let original = try rig.source(); rig.hub.selectAudioImport(original); rig.hub.keepAudioImportAndTranscribe()
        await fulfillment(of:[entered],timeout:5)
        let participants = SavedRestartRig(rig)
        var claims = 0
        let restart = Task { @MainActor in await participants.claim {claims += 1; return false} }
        await Task.yield(); XCTAssertEqual(claims,0)
        gate.signal(); let allowed = await restart.value
        XCTAssertFalse(allowed); XCTAssertEqual(claims,1); XCTAssertNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
        rig.native.decode = nil
        let id = try XCTUnwrap(rig.saved.rows.first?.id)
        rig.hub.retrySavedAudioImport(id); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.native.calls.count,2); XCTAssertNotNil(rig.saved.review?.accepted)
        try await rig.close()
    }
    @MainActor func testConcreteTerminationJoinsResultReadAndSuppressesRevokedOpen() async throws {
        let rig = try SavedImportRig(); _ = try await rig.run(); rig.hub.discardAudioImport()
        let entered = expectation(description:"held result read"), gate = DispatchSemaphore(value:0)
        rig.faults.reached = {if $0 == .payloadRead {entered.fulfill(); _ = gate.wait(timeout:.now()+5)} }
        rig.hub.openSavedAudioImport(try XCTUnwrap(rig.saved.rows.first?.id))
        await fulfillment(of:[entered],timeout:5)
        var replies:[Bool] = []; let replied = expectation(description:"result reader quit reply")
        let termination = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(true)},savedImports:{rig.saved.beginShutdown($0)},cancelSavedImports:{rig.saved.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0); replied.fulfill()},failure:{})
        XCTAssertEqual(termination.request(),.terminateLater); XCTAssertTrue(replies.isEmpty)
        rig.faults.reached = nil; gate.signal(); await rig.saved.drain(); await fulfillment(of:[replied],timeout:5)
        XCTAssertEqual(replies,[true]); XCTAssertNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
}


extension SavedAudioImportLifecycleTests {
    @MainActor func testEagerMetadataIOJoinsTerminationWithNoNewHubOrPreparation() async throws {
        let rig = try SavedImportRig(); rig.now = Date(); _ = try await rig.run()
        rig.saved.invalidate(); await rig.saved.drain(); try rig.saved.store.close()
        let entered = expectation(description:"eager metadata held"), gate = DispatchSemaphore(value:0)
        var system = SavedAudioImportStorage.System(), held = false, payloads = 0
        system.checkpoint = {
            if $0 == .payloadRead {payloads += 1}
            if $0 == .metadataRead && !held {held = true; entered.fulfill(); _ = gate.wait(timeout:.now()+5)}
        }
        let eager = SavedAudioImportOwner(root:rig.saved.store.storage.root,system:system,clock:{rig.now})
        await fulfillment(of:[entered],timeout:5)
        var replies:[Bool] = []; let replied = expectation(description:"eager metadata quit reply")
        let termination = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(true)},savedImports:{eager.beginShutdown($0)},cancelSavedImports:{eager.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0); replied.fulfill()},failure:{})
        XCTAssertEqual(termination.request(),.terminateLater); XCTAssertTrue(replies.isEmpty)
        gate.signal(); await eager.drain(); await fulfillment(of:[replied],timeout:5)
        XCTAssertEqual(replies,[true]); XCTAssertEqual(payloads,0); XCTAssertNil(eager.review)
        try eager.store.close(); try await rig.close()
    }
    @MainActor func testNoncancellableConstructorKeepsTheSharedLaneUntilActualExit() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let entered = expectation(description:"held constructor"), gate = DispatchSemaphore(value:0)
        rig.native.construct = {entered.fulfill(); _ = gate.wait(timeout:.now()+5)}
        let original = try rig.source(); rig.hub.selectAudioImport(original); rig.hub.keepAudioImportAndTranscribe()
        await fulfillment(of:[entered],timeout:5)
        let factory = rig.native.factory()
        rig.hub.onAudioImport = {job,done in
            let next = AudioImportExecution.enqueue(previous:rig.chain,admission:rig.admission,job:job,store:rig.settings,load:{request in
                try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:factory,operation:job.operation,selectionEpoch:job.selectionEpoch,preparationEpoch:job.preparationEpoch)
            },done:done)
            if let next {rig.chain = next}
        }
        let next = rig.root.appendingPathComponent("next.wav"); try retainedSyntheticWAV().write(to:next)
        rig.hub.selectAudioImport(next); rig.hub.startAudioImport(); await Task.yield()
        XCTAssertEqual(rig.native.paths.count,1); XCTAssertTrue(rig.native.calls.isEmpty)
        rig.native.construct = nil; gate.signal(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertEqual(rig.native.paths.count,2); XCTAssertEqual(rig.native.calls.count,1); XCTAssertEqual(rig.native.peakLive,1)
        XCTAssertNil(rig.saved.review); XCTAssertNotNil(rig.transient.review)
        try await rig.close()
    }
}


extension SavedAudioImportLifecycleTests {
    @MainActor func testSynchronousSavedWriterIsAnActualTerminationBorrow() async throws {
        let rig = try SavedImportRig(); _ = try await rig.run()
        var replies:[Bool] = []
        let replied = expectation(description:"joined writer and quit continuation")
        let termination = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(true)},savedImports:{rig.saved.beginShutdown($0)},cancelSavedImports:{rig.saved.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0); replied.fulfill()},failure:{})
        rig.hub.audioImportExportPanel = {_ in rig.root.appendingPathComponent("out.txt")}
        rig.hub.historyExportWriter = {data,_ in
            XCTAssertFalse(rig.saved.restartReady())
            XCTAssertEqual(termination.request(),.terminateLater); XCTAssertTrue(replies.isEmpty)
            rig.written.append(data)
        }
        rig.hub.exportSavedAudioImportText(); await rig.saved.drain()
        await fulfillment(of:[replied],timeout:5)
        XCTAssertEqual(rig.written,[Data("native original".utf8)]); XCTAssertEqual(replies,[true]); XCTAssertNil(rig.saved.review)
        try await rig.close()
    }
}

/// These are the same concrete participant types passed by AppDelegate. All
/// external storage/native bottoms remain inert unless a test explicitly uses one.
@MainActor final class SavedRestartRig {
    let rig: SavedImportRig
    let apple = AppleOwnerRig()
    let parakeet: ParakeetPreparation
    let experimental = ExperimentalHistoryRetryOwner()
    let reservation = ImportRestartReservation()
    var releaseFinal:() -> Void = {}
    init(_ rig: SavedImportRig) {
        self.rig = rig
        parakeet = ParakeetPreparation(storage: .init(root:rig.root.appendingPathComponent("unused-parakeet")))
    }
    func claim(_ final: () async -> Bool) async -> Bool {
        await AppDelegate.withSavedImportRestart(rig.saved,parakeet:parakeet,apple:apple.owner,
            local:rig.admission,experimental:experimental,chain:{self.rig.chain},reservation:reservation,releaseClaim:releaseFinal,claim:final)
    }
    func release() {
        reservation.release()
    }
}

extension SavedAudioImportLifecycleTests {
    @MainActor func testProductionRestartGraphReservesEveryParticipantBeforeHeldSavedIODrains() async throws {
        for holdNative in [false,true] {
            let rig = try SavedImportRig(); await rig.ready()
            let entered = expectation(description:"concrete saved work held"), gate = DispatchSemaphore(value:0)
            if holdNative {rig.native.decode = {entered.fulfill(); _ = gate.wait(timeout:.now()+5)}}
            else {rig.faults.event = {boundary,name in if boundary == .write, name?.hasSuffix(".source.pending") == true {entered.fulfill(); _ = gate.wait(timeout:.now()+5)}}}
            let url = try rig.source(); rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe()
            await fulfillment(of:[entered],timeout:5)
            let participants = SavedRestartRig(rig), reserved = expectation(description:"last synchronous reservation acquired")
            var observed = false, claims = 0
            let observer = rig.saved.$message.sink {value in
                if !observed, value?.contains("restart") == true {observed = true; reserved.fulfill()}
            }
            let task = Task { @MainActor in await participants.claim {claims += 1; return false} }
            await fulfillment(of:[reserved],timeout:5); observer.cancel()
            XCTAssertTrue(participants.parakeet.admissionClosed); XCTAssertTrue(participants.apple.owner.admissionClosed)
            XCTAssertFalse(participants.experimental.admits)
            let other = PendingOperation(name:"restart admission witness")
            XCTAssertFalse(rig.admission.admit(other)); XCTAssertEqual(claims,0)
            rig.hub.retrySavedAudioImport(rig.saved.job!.id); XCTAssertEqual(rig.native.calls.count,holdNative ? 1 : 0)
            rig.faults.event = nil; gate.signal()
            let allowed = await task.value; XCTAssertFalse(allowed)
            XCTAssertFalse(participants.parakeet.admissionClosed); XCTAssertFalse(participants.apple.owner.admissionClosed)
            XCTAssertTrue(participants.experimental.admits); XCTAssertTrue(rig.admission.admit(other))
            rig.admission.exited(other); other.finish()
            XCTAssertEqual(claims,1); XCTAssertNil(rig.saved.review)
            try await rig.close()
        }
    }
    @MainActor func testPartialRestartAcquisitionUnwindsOnlyItsAcquiredSet() async throws {
        for blocked in 0..<5 {
            let rig = try SavedImportRig(); await rig.ready(); let p = SavedRestartRig(rig)
            let reserve: [() -> Bool] = [{p.parakeet.reserveRestart()},{p.apple.owner.reserveRestart()},{rig.admission.reserveRestart()},{p.experimental.reserveRestart()},{rig.saved.reserveRestart()}]
            let release: [() -> Void] = [{p.parakeet.releaseRestart()},{p.apple.owner.releaseRestart()},{rig.admission.releaseRestart()},{p.experimental.releaseRestart()},{rig.saved.releaseRestart()}]
            XCTAssertTrue(reserve[blocked]())
            var claims = 0; let allowed = await p.claim {claims += 1; return true}
            XCTAssertFalse(allowed); XCTAssertEqual(claims,0)
            for i in 0..<5 {
                if i == blocked {XCTAssertFalse(reserve[i](),"preexisting reservation was released")}
                else {XCTAssertTrue(reserve[i](),"acquired participant leaked: \(i)"); release[i]()}
            }
            release[blocked](); try await rig.close()
        }
    }
    @MainActor func testSafeStartFinalStableChainAndUpdaterFailureReleaseUseConcreteComposition() async throws {
        for enabled in [false,true] {
            let rig = try SavedImportRig(); _ = try await rig.run(); let participants = SavedRestartRig(rig)
            let memory = SavedPreparationMemory()
            let core = RecognitionPreparation(storage:{memory},build:{.init(app:UUID(),native:UUID(),architecture:"arm64")})
            let native = NativePreparation(core:core), consent = UUID(), epoch = UUID()
            participants.releaseFinal = {core.releaseRestart()}
            if enabled {try core.prepareConsent(consent)}
            var settings = try rig.settings.savedRetrySnapshot(); settings.nativePreparationSafeStartEnabled = enabled; settings.nativePreparationConsent = enabled ? consent : nil
            native.configure(settings,epoch:epoch)
            let rejected = await participants.claim {
                await native.claimRestart(chain:{rig.chain},allowed:{false},claimOther:{true},rejected:{})
            }
            XCTAssertFalse(rejected); XCTAssertFalse(participants.parakeet.admissionClosed)
            XCTAssertFalse(participants.apple.owner.admissionClosed); XCTAssertTrue(participants.experimental.admits)
            let allowed = await participants.claim {
                await native.claimRestart(chain:{rig.chain},allowed:{rig.saved.restartReady() && participants.apple.owner.restartReady() && participants.parakeet.restartReady()},claimOther:{true},rejected:{})
            }
            XCTAssertTrue(allowed)
            let update = UpdateTerminationIntent(); var released = 0
            XCTAssertFalse(update.installFailed {
                released += 1; participants.release()
            })
            XCTAssertEqual(released,1); XCTAssertTrue(participants.experimental.admits)
            // A later failed install notification owns no participant. In
            // particular it cannot clear an unrelated new reservation.
            XCTAssertTrue(participants.apple.owner.reserveRestart())
            _ = update.installFailed {participants.release()}
            XCTAssertTrue(participants.apple.owner.admissionClosed); participants.apple.owner.releaseRestart()
            XCTAssertFalse(participants.parakeet.admissionClosed); XCTAssertFalse(participants.apple.owner.admissionClosed)
            rig.hub.openSavedAudioImport(try XCTUnwrap(rig.saved.rows.first?.id)); await rig.saved.drain()
            XCTAssertNotNil(rig.saved.review); XCTAssertEqual(rig.native.calls.count,1)
            try await rig.close()
        }
    }
    @MainActor func testEagerPendingReadyUnavailableAndConstructorClockAreExplicit() async throws {
        let rig = try SavedImportRig(); _ = try await rig.run()
        let id = try XCTUnwrap(rig.saved.rows.first?.id)
        rig.saved.invalidate(); await rig.saved.drain(); try rig.saved.store.close()
        let entered = expectation(description:"metadata bootstrap held"), gate = DispatchSemaphore(value:0)
        var held = false, payloads = 0; var system = SavedAudioImportStorage.System()
        system.checkpoint = {boundary in
            if boundary == .payloadRead {payloads += 1}
            if boundary == .metadataRead && !held {held = true; entered.fulfill(); _ = gate.wait(timeout:.now()+5)}
        }
        let owner = SavedAudioImportOwner(root:rig.saved.store.storage.root,system:system,clock:{rig.now})
        rig.transient.savedImports = owner
        await fulfillment(of:[entered],timeout:5)
        XCTAssertEqual(owner.metadataReadiness,.pending); XCTAssertThrowsError(try owner.protection())
        rig.hub.openSavedAudioImport(id); XCTAssertNil(owner.review)
        rig.hub.diagnosticPanel = {_ in rig.root.appendingPathComponent("pending.json")}; rig.hub.prepareDiagnostics(); rig.hub.exportDiagnostics()
        XCTAssertTrue(rig.written.isEmpty); XCTAssertEqual(payloads,0)
        gate.signal(); await owner.drain()
        XCTAssertEqual(owner.metadataReadiness,.ready); XCTAssertEqual(owner.rows.count,1) // injected clock precedes maintenance
        rig.hub.openSavedAudioImport(id); await owner.drain(); XCTAssertNotNil(owner.review)
        XCTAssertEqual(payloads,1); XCTAssertEqual(rig.native.calls.count,1)
        owner.invalidate(); try owner.store.close()
        let unknown = rig.saved.store.storage.root.appendingPathComponent("unknown"); try Data([79]).write(to:unknown)
        let unavailable = SavedAudioImportOwner(root:rig.saved.store.storage.root,clock:{rig.now}); await unavailable.drain()
        XCTAssertEqual(unavailable.metadataReadiness,.unavailable); XCTAssertThrowsError(try unavailable.protection())
        XCTAssertEqual(try Data(contentsOf:unknown),Data([79])); try unavailable.store.close()
        try await rig.close()
    }
    @MainActor func testHeldOriginalReadCancelDeleteAndQuitKeepDescriptorUntilActualExit() async throws {
        for action in 0..<3 {
            let rig = try SavedImportRig(); await rig.ready()
            let entered = expectation(description:"actual original read held"), gate = DispatchSemaphore(value:0)
            var stops = 0, held = false
            rig.transient.sourceAccess.start = {_ in true}; rig.transient.sourceAccess.stop = {_ in stops += 1}
            rig.transient.sourceAccess.read = {fd,bytes,count in
                if !held {held = true; XCTAssertFalse(Thread.isMainThread, "Saved original IO must leave the actor before reading"); entered.fulfill(); _ = gate.wait(timeout:.now()+2)}
                return Darwin.read(fd,bytes,count)
            }
            let url = try rig.source(); rig.hub.selectAudioImport(url)
            let source = try XCTUnwrap(rig.transient.source)
            rig.hub.keepAudioImportAndTranscribe(); await fulfillment(of:[entered],timeout:5)
            var replies:[Bool] = []; let replied = action == 2 ? expectation(description:"quit joined original read") : nil
            if action == 0 {rig.hub.cancelSavedAudioImport()}
            if action == 1 {rig.hub.deleteSavedAudioImport(try XCTUnwrap(rig.saved.job?.id))}
            if action == 2 {rig.saved.beginShutdown {replies.append($0); replied?.fulfill()}}
            XCTAssertFalse(source.isClosed); XCTAssertEqual(stops,0); XCTAssertTrue(rig.native.paths.isEmpty)
            gate.signal(); await rig.chain?.value; await rig.saved.drain()
            if action == 2 {await fulfillment(of:[try XCTUnwrap(replied)],timeout:5); XCTAssertEqual(replies,[true]); rig.saved.cancelShutdown()}
            XCTAssertTrue(source.isClosed); XCTAssertEqual(stops,1); XCTAssertTrue(rig.native.paths.isEmpty)
            XCTAssertNil(rig.saved.review); XCTAssertEqual(try Data(contentsOf:url),retainedSyntheticWAV())
            try await rig.close()
        }
    }
    @MainActor func testHeldResultAndHistoryIntentAreJoinedAndCannotPublishAfterRevocation() async throws {
        for historyPhase in [false,true] {
            let rig = try SavedImportRig(); await rig.ready()
            if historyPhase {_ = try await rig.run()}
            let entered = expectation(description:"owned publication held"), gate = DispatchSemaphore(value:0)
            var held = false
            rig.faults.event = {boundary,name in
                let target = historyPhase ? name == "manifest.next" : name?.hasSuffix(".result.pending") == true
                if boundary == .write && target && !held {held = true; entered.fulfill(); _ = gate.wait(timeout:.now()+5)}
            }
            if historyPhase {rig.hub.saveSavedAudioImportHistory()}
            else {let url = try rig.source(); rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe()}
            await fulfillment(of:[entered],timeout:5)
            var replies:[Bool] = []; let replied = expectation(description:"held publication exit")
            rig.saved.beginShutdown {replies.append($0); replied.fulfill()}
            XCTAssertTrue(replies.isEmpty); XCTAssertFalse(rig.saved.restartReady()); XCTAssertNil(rig.saved.review)
            rig.faults.event = nil; gate.signal(); await rig.chain?.value; await rig.saved.drain()
            await fulfillment(of:[replied],timeout:5)
            XCTAssertEqual(replies.count,1); XCTAssertNil(rig.saved.review); XCTAssertTrue(rig.history.entries.isEmpty)
            rig.saved.cancelShutdown(); try await rig.close()
        }
    }
}

private final class SavedPreparationMemory: PreparationStorage {
    var data: Data?
    func read() throws -> Data? {data}
    func replace(_ value:Data,authorized:() -> Bool) throws {
        guard authorized() else {throw PreparationRefusal.revoked}; data = value
    }
    func reset(_ value:Data) throws {data = value}
    func quarantine() throws {throw PreparationRefusal.trackingUnavailable}
}

private final class SavedHeldApple: AppleSpeechSession {
    let base = AppleOriginSession(), released = G2aLatch()
    let entered = XCTestExpectation(description:"saved Apple collector held")
    func converter(samples:[Float]) async throws -> AppleSpeechConverter {try await base.converter(samples:samples)}
    func collect(ready:@escaping () -> Void,_ emit:@escaping (AppleSpeechEvent) throws -> Void) async throws {
        ready(); entered.fulfill(); await released.wait(); try await base.collect(ready:{},emit)
    }
    func analyze(_ input:AppleSpeechInput) async throws -> AppleSpeechTime? {try await base.analyze(input)}
    func finalize(through:AppleSpeechTime) async throws {try await base.finalize(through:through)}
    func cancelAndFinish() async {await released.wait(); await base.cancelAndFinish()}
}
extension SavedAudioImportLifecycleTests {
    @MainActor func testCancelBeforeDequeueClosesUnborrowedSelectionAndNeverCreatesSavedPayload() async throws {
        let rig = try SavedImportRig(); await rig.ready()
        let gate = RecognitionTestLatch(), entered = expectation(description:"shared predecessor held")
        let predecessor = PendingOperation(name:"saved predecessor")
        rig.chain = PendingOperationQueue.enqueue(previous:nil,operation:predecessor,completes:true,work:{entered.fulfill(); await gate.wait()})
        await fulfillment(of:[entered],timeout:5)
        let url = try rig.source(); rig.hub.selectAudioImport(url); let source = try XCTUnwrap(rig.transient.source)
        rig.hub.keepAudioImportAndTranscribe(); let job = try XCTUnwrap(rig.saved.job)
        rig.hub.cancelSavedAudioImport()
        XCTAssertTrue(source.isClosed); XCTAssertFalse(job.operation.hasExited); XCTAssertEqual(rig.originalReads,0)
        XCTAssertTrue(rig.native.paths.isEmpty); XCTAssertEqual(rig.faults.factoryEntries,0)
        gate.signal(); await rig.chain?.value; await rig.saved.drain()
        XCTAssertTrue(job.operation.hasExited); XCTAssertTrue(rig.saved.rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:rig.saved.store.storage.root.path))
        _ = try await rig.run(); XCTAssertNotNil(rig.saved.review?.accepted); XCTAssertEqual(rig.native.calls.count,1)
        try await rig.close()
    }
    @MainActor func testSavedAppleWorkerExitHoldsDeleteAndDuplicateQuitUntilActualJoin() async throws {
        let rig = try SavedImportRig(); await rig.ready(); let apple = AppleOwnerRig(), session = SavedHeldApple()
        apple.configure(); await apple.wait(); await apple.prepare()
        try rig.settings.save(apple.saved); rig.hub.refreshAudioImportConfiguration()
        rig.factoryProvider = {
            RecognitionFactory(appleBottom:.init(available:{},session:{_ in session}),appleInstalledUse:{locale,operation in
                try await apple.owner.installedUse(locale,operation:operation)
            },native:{_,_ in XCTFail("Apple fell back to Whisper"); throw CancellationError()},runtime:{.init(nativeVersion:"fake",buildScope:"fake")},metadata:{_ in nil},admit:{_,_ in XCTFail("Apple entered file admission")})
        }
        rig.enter = {await MainActor.run {apple.owner.deliberateEntry()}}
        let watchdog = Task {do {try await Task.sleep(nanoseconds:5_000_000_000)} catch {return}; XCTFail("Apple hold watchdog expired before explicit release"); await session.released.signal()}
        defer {watchdog.cancel()}
        let url = try rig.source(); rig.hub.selectAudioImport(url); rig.hub.keepAudioImportAndTranscribe()
        await fulfillment(of:[session.entered],timeout:5)
        let token = try XCTUnwrap(rig.saved.job?.token)
        let owned = rig.saved.store.storage.root.appendingPathComponent(token.source.uuidString.lowercased()+".source.wav")
        let deleting = expectation(description:"saved Apple delete intent accepted"); var seen = false
        let observer = rig.saved.$rows.sink {rows in if !seen && rows.contains(where:{$0.id == token.job && $0.deleting}) {seen = true; deleting.fulfill()}}
        rig.hub.deleteSavedAudioImport(token.job); await fulfillment(of:[deleting],timeout:5); observer.cancel()
        XCTAssertTrue(apple.owner.hasWork); XCTAssertTrue(FileManager.default.fileExists(atPath:owned.path))
        var replies:[Bool] = []; let replied = expectation(description:"Apple and deletion actually joined")
        let quit = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(true)},localCleanup:{rig.admission.beginShutdown(chain:{rig.chain},reply:$0)},cancelLocalCleanup:{rig.admission.cancelShutdown()},savedImports:{rig.saved.beginShutdown($0)},cancelSavedImports:{rig.saved.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0); replied.fulfill()},failure:{})
        XCTAssertEqual(quit.request(),.terminateLater); XCTAssertEqual(quit.request(),.terminateLater)
        XCTAssertTrue(replies.isEmpty); XCTAssertTrue(apple.owner.hasWork)
        await session.released.signal(); await rig.chain?.value; await rig.saved.drain(); await fulfillment(of:[replied],timeout:5)
        XCTAssertEqual(replies,[true]); XCTAssertFalse(apple.owner.hasWork); XCTAssertTrue(rig.saved.rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.path)); XCTAssertEqual(try Data(contentsOf:url),retainedSyntheticWAV())
        XCTAssertTrue(rig.native.paths.isEmpty); try await rig.close()
    }
}
