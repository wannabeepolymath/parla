import Combine
import Darwin
import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

final class MeetingHubCompositionTests: XCTestCase {
    @MainActor func testColdGuardIsTwoStageReentrantRefusalAndWriterSpanning() throws {
        let r = try MeetingHubRig(capability:false); defer { r.release() }
        var sequence: [String] = []
        let result = try r.controller.withExportProtection(validateDestination:{ _ in
            sequence.append("validate")
            XCTAssertThrowsError(try r.controller.withExportProtection(validateDestination:{_ in XCTFail()},perform:{XCTFail()}))
        },perform:{ sequence.append("write"); XCTAssertFalse(r.controller.reserveRestart()); return 19 })
        XCTAssertEqual(result,19); XCTAssertEqual(sequence,["validate","write"])
        XCTAssertTrue(r.bottom.descriptors.isEmpty); XCTAssertEqual(r.bottom.payloadReads,0); XCTAssertEqual(r.engine.queries.value,0)
    }
    @MainActor func testColdNamespaceAppearingDuringValidatorRefusesWriter() throws {
        let r = try MeetingHubRig(capability:false); defer { r.release() }; var writes = 0
        XCTAssertThrowsError(try r.controller.withExportProtection(validateDestination:{_ in
            let parent = r.bottom.descriptors.values.first { $0.node.name == "p10" }!.node
            let node = LifecycleMeetingBottom.Node(name:"meeting",inode:999,directory:true); parent.children["meeting"] = node
        },perform:{writes += 1}))
        XCTAssertEqual(writes,0); XCTAssertTrue(r.bottom.descriptors.isEmpty)
    }
    @MainActor func testWriterThrowAndOverdueActualReturnNeverClaimSuccess() throws {
        enum Expected: Error { case writer }
        for late in [false,true] {
            let r = try MeetingHubRig(capability:false); defer { r.release() }; var actual = 0
            XCTAssertThrowsError(try r.controller.withExportProtection(validateDestination:{_ in},perform:{
                actual += 1; if late { r.bottom.tick = 31 } else { throw Expected.writer }
            }))
            XCTAssertEqual(actual,1); XCTAssertTrue(r.bottom.descriptors.isEmpty)
        }
    }
    @MainActor func testColdUnknownCloseWithNoSessionRetainsLifecycleVeto() async throws {
        let r = try MeetingHubRig(capability:false); defer { r.release() }; r.bottom.closeFailureAt = 1
        XCTAssertThrowsError(try r.controller.withExportProtection(validateDestination:{_ in},perform:{}))
        XCTAssertFalse(r.controller.reserveRestart()); r.controller.reserveShutdown()
        guard await hubComplete({let ready = await r.controller.drainRestart(); XCTAssertFalse(ready)}) else { return }
        r.controller.cancelShutdown(); r.controller.openPage(); XCTAssertNil(r.controller.model.metadata)
    }
    @MainActor func testPermissionActualCallbackVetoesRestartUntilReturnAndNeverCaptures() async throws {
        let r = try MeetingHubRig(); defer { r.release() }; r.permission = .undetermined
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertTrue(r.controller.reserveRestart()); XCTAssertFalse(r.controller.restartReady())
        let callback = r.pendingPermission; r.pendingPermission = nil; callback?(true)
        guard await hubComplete({let ready = await r.controller.drainRestart(); XCTAssertTrue(ready)}) else { return }
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0); r.controller.releaseRestart()
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; XCTAssertEqual(r.engine.starts.value,0)
    }
    @MainActor func testKnownDetachOtherParticipantRejectAndExplicitReentryPreserveOccupancy() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startAndSave()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        guard await hubEntered([r.engine.started]) else { return }
        r.engine.emit([Float](repeating:0.5,count:8000)); r.controller.stopAndSave(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        let session = r.controller.model.metadata!.session; XCTAssertTrue(r.controller.reserveRestart())
        guard await hubComplete({let ready = await r.controller.drainRestart(); XCTAssertTrue(ready)}) else { return }
        r.controller.releaseRestart() // a later updater/participant refusal releases intent only
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.controller.model.metadata?.session,session); r.controller.startAndSave(); XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.enqueues,0)
    }
    @MainActor func testEmittedPreparationFactsIgnoreTokensProgressAndRevokeOnRealChange() throws {
        let r = try MeetingHubRig(capability:false); defer { r.release() }
        var apple = AppleSpeechSnapshot(); apple.phase = .ready; apple.locale = "en-US"; apple.refusal = nil
        r.controller.applePreparationChanged(apple); apple.token = UUID(); apple.phase = .checking; r.controller.applePreparationChanged(apple)
        var parakeet = ParakeetSnapshot(); parakeet.phase = .ready; parakeet.refusal = nil
        r.controller.parakeetPreparationChanged(parakeet); parakeet.token = UUID(); parakeet.bytes = 123; r.controller.parakeetPreparationChanged(parakeet)
        r.controller.revokePreparation(.appleSpeech); r.controller.revokePreparation(.parakeet)
        XCTAssertEqual(r.engine.queries.value,0); XCTAssertEqual(r.bottom.calls,0); XCTAssertEqual(r.enqueues,0)
    }
}


extension MeetingHubCompositionTests {
    @MainActor func testIndependentlyHeldMetadataAndStartJoinThroughRestartCancel() async throws {
        for kind in ["metadata","start"] {
            let r = try MeetingHubRig(); defer {r.release()}
            if kind == "start" {r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}}
            let entered = expectation(description:"\(kind) entered actual bottom")
            let held = HubCheckpointHold(entered:entered,match:{ op,name in kind == "metadata" ? op == "cold-acquire" : op == "write" && name == "owner.json" })
            defer {held.latch.open()};r.bottom.observe = held.observe
            if kind == "metadata" {r.controller.openPage()} else {r.controller.startAndSave()}
            guard await hubEntered([entered]) else {return}
            XCTAssertTrue(r.controller.reserveRestart()); XCTAssertFalse(r.controller.restartReady())
            let drain = HubRestartDrain(r.controller); guard await hubEntered([drain.entered]) else {return}
            XCTAssertFalse(drain.returned); r.controller.releaseRestart(); held.latch.open()
            guard await hubEntered([drain.exited]) else {return}
            XCTAssertEqual(drain.allowed,false)
            guard await hubComplete({await r.controller.drainActions()}) else {return}
            XCTAssertFalse(r.controller.restartReady()); XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0); XCTAssertFalse(held.latch.timedOut)
        }
    }
    @MainActor func testHeldAcceptedReadRevokesClipboardThenJoinsThroughQuit() async throws {
        let r = try MeetingHubRig();defer {r.release()}
        r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.startAndSave();guard await hubComplete({await r.controller.drainActions()}) else {return}
        guard await hubEntered([r.engine.started]) else {return}
        r.engine.emit([Float](repeating:0.5,count:8000));r.controller.stopAndSave();guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.transcribeRemaining();guard await hubComplete({await r.controller.drainActions()}) else {return}
        let entered = expectation(description:"accepted text hash read entered")
        let held = HubCheckpointHold(entered:entered,match:{$0 == "read-open" && $1?.hasSuffix(".raw.txt") == true});defer {held.latch.open()}
        r.bottom.observe = held.observe;r.controller.copyText()
        guard await hubEntered([entered]) else {return}
        r.controller.reserveShutdown();XCTAssertFalse(r.controller.restartReady());held.latch.open()
        guard await hubComplete({let ready = await r.controller.drainRestart();XCTAssertTrue(ready)}) else {return}
        XCTAssertTrue(r.copies.isEmpty);XCTAssertFalse(held.latch.timedOut)
    }
    @MainActor func testDurableDeleteAndExpiryHoldReadinessThroughActualUnlink() async throws {
        for expiry in [false,true] {
            let r = try MeetingHubRig();defer {r.release()}
            r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
            r.controller.startAndSave();guard await hubComplete({await r.controller.drainActions()}) else {return}
            guard await hubEntered([r.engine.started]) else {return}
            r.engine.emit([Float](repeating:0.5,count:8000));r.controller.stopAndSave();guard await hubComplete({await r.controller.drainActions()}) else {return}
            let entered = expectation(description:"bounded unlink actually entered")
            let held = HubCheckpointHold(entered:entered,match:{$0 == "unlink" && $1?.hasSuffix(".source.wav") == true});defer {held.latch.open()}
            r.bottom.observe = held.observe
            if expiry {r.clock = r.controller.model.metadata!.expires;r.controller.openPage()}
            else {let confirmation = r.controller.deleteConfirmation!;r.controller.deleteConfirmed(session:confirmation.session,intent:confirmation.intent)}
            guard await hubEntered([entered]) else {return}
            r.controller.reserveShutdown();XCTAssertFalse(r.controller.restartReady())
            let drain = HubRestartDrain(r.controller);guard await hubEntered([drain.entered]) else {return}
            XCTAssertFalse(drain.returned);held.latch.open()
            guard await hubEntered([drain.exited]) else {return}
            XCTAssertEqual(drain.allowed,true)
            XCTAssertTrue(r.bottom.descriptors.isEmpty);XCTAssertEqual(r.enqueues,0);XCTAssertFalse(held.latch.timedOut)
        }
    }
    @MainActor func testEveryCombinedGuardWriterFalseThrowReentrancyAndLateReturn() throws {
        // Shared guard fault cases only. The actual HubModel caller selectors below qualify each action family.
        for family in ["history","vocabulary","diagnostics","transientSubtitles","savedText"] {
            for outcome in ["written","earlyFalse","throws","late"] {
                let r = try MeetingHubRig(capability:false);defer {r.release()};var calls = 0
                do {
                    let written = try r.controller.withExportProtection(validateDestination:{_ in
                        XCTAssertThrowsError(try r.controller.withExportProtection(validateDestination:{_ in},perform:{}))
                    },perform:{() throws -> Bool in
                        if outcome == "earlyFalse" {return false}
                        calls += 1
                        if outcome == "throws" {throw MeetingSession.Failure.unavailable}
                        if outcome == "late" {r.bottom.tick = 31}
                        return true
                    })
                    XCTAssertTrue(outcome == "written" || outcome == "earlyFalse",family)
                    XCTAssertEqual(written,outcome == "written",family)
                } catch {XCTAssertTrue(outcome == "throws" || outcome == "late",family)}
                XCTAssertEqual(calls,outcome == "earlyFalse" ? 0 : 1,family);XCTAssertTrue(r.bottom.descriptors.isEmpty,family)
            }
        }
    }
}


extension MeetingHubCompositionTests {
    @MainActor func testR1SynchronousOtherParticipantFalseBeforeMeetingActorTurnStillCloses() async throws {
        let r = try MeetingHubRig(); defer {r.release()}
        guard await hubSaved(r) else {return}
        let saved = try XCTUnwrap(r.controller.model.metadata)
        var replies: [Bool] = [], cancels = 0
        let termination = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(false)},
            meeting:{r.controller.beginShutdown($0)},cancelMeeting:{cancels += 1;r.controller.cancelShutdown()},
            cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0)},failure:{},onIntent:{r.controller.reserveShutdown()})
        XCTAssertEqual(termination.request(),.terminateCancel)
        XCTAssertEqual(cancels,1); XCTAssertTrue(replies.isEmpty)
        // No drainRestart caller is supplied by this test after synchronous cancellation.
        guard await hubModel(r.controller, {$0.state == .detached && !$0.busy}) else {return}
        XCTAssertTrue(r.bottom.descriptors.isEmpty); XCTAssertFalse(r.controller.restartReady())
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.controller.model.metadata?.session,saved.session)
        var writes = 0
        try r.controller.withExportProtection(validateDestination:{_ in},perform:{writes += 1})
        XCTAssertEqual(writes,1); XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.enqueues,0)
        r.controller.startAndSave(); XCTAssertEqual(r.engine.starts.value,1)
    }
    @MainActor func testR1RawReserveReleaseWithoutAnyDrainCallerObservesKnownClose() async throws {
        let r = try MeetingHubRig(); defer {r.release()}
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertTrue(r.controller.reserveRestart()); r.controller.releaseRestart()
        guard await hubModel(r.controller, {$0.state == .detached && !$0.busy}) else {return}
        XCTAssertTrue(r.bottom.descriptors.isEmpty); XCTAssertFalse(r.controller.restartReady())
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.meetingStores.count,2)
        var wrote = false; try r.controller.withExportProtection(validateDestination:{_ in},perform:{wrote = true})
        XCTAssertTrue(wrote); XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0)
    }
    @MainActor func testLaterParticipantFalseAfterDetachAndStaleReplyCannotSettleNewIntent() async throws {
        let r = try MeetingHubRig(); defer {r.release()}
        guard await hubSaved(r) else {return}
        let session = try XCTUnwrap(r.controller.model.metadata?.session)
        var updater: [(Bool) -> Void] = [], replies: [Bool] = [], meetingReplies = 0
        let firstMeeting = XCTestExpectation(description:"first meeting Begin actually returned ready")
        let secondMeeting = XCTestExpectation(description:"second meeting Begin actually returned ready")
        let termination = TerminationCoordinator(clipboard:{$0(true)},updater:{updater.append($0)},
            meeting:{callback in r.controller.beginShutdown { ready in
                meetingReplies += 1; XCTAssertTrue(ready); callback(ready)
                if meetingReplies == 1 {firstMeeting.fulfill()} else if meetingReplies == 2 {secondMeeting.fulfill()}
            }},cancelMeeting:{r.controller.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0)},failure:{},onIntent:{r.controller.reserveShutdown()})
        XCTAssertEqual(termination.request(),.terminateLater)
        guard await hubEntered([firstMeeting]) else {return}
        XCTAssertTrue(r.bottom.descriptors.isEmpty); XCTAssertTrue(r.controller.restartReady()); XCTAssertTrue(replies.isEmpty)
        let stale = updater[0]; stale(false); XCTAssertEqual(replies,[false]); XCTAssertFalse(r.controller.restartReady())
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.controller.model.metadata?.session,session)
        XCTAssertEqual(termination.request(),.terminateLater)
        stale(true); stale(false); XCTAssertEqual(replies,[false]); XCTAssertTrue(termination.isPending)
        guard await hubEntered([secondMeeting]) else {return}
        XCTAssertTrue(termination.isPending); updater[1](false)
        XCTAssertEqual(replies,[false,false]); XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.enqueues,0)
    }
    @MainActor func testPermissionDrainIsActuallyPendingUntilTrackedDeliveryReturns() async throws {
        let r = try MeetingHubRig(); defer {r.release()}; r.permission = .undetermined
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.startAndSave(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        let callback = try XCTUnwrap(r.pendingPermission); r.pendingPermission = nil
        // Independent fail-safe for the callback lifetime as well as defer on every branch.
        let gate = HubOwnedLatch(); defer {gate.open();callback(false)}
        let delivered = XCTestExpectation(description:"test-owned permission delivery returned")
        DispatchQueue.global().async {gate.hold();callback(true);delivered.fulfill()}
        XCTAssertTrue(r.controller.reserveRestart()); let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered]) else {return}
        XCTAssertFalse(drain.returned); XCTAssertFalse(r.controller.restartReady()); XCTAssertEqual(r.meetingStores.count,1)
        r.controller.releaseRestart(); gate.open()
        guard await hubEntered([delivered,drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,false); XCTAssertFalse(gate.timedOut); XCTAssertEqual(r.engine.starts.value,0)
        guard await hubModel(r.controller, {$0.state == .detached && !$0.busy}) else {return}
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.engine.starts.value,0)
    }
    @MainActor func testActualAcquisitionAndConsumerIntervalsHoldEnteredLifecycleDrain() async throws {
        for acquisition in [true,false] {
            let r = try MeetingHubRig(),gate = HubOwnedLatch(); defer {gate.open();r.release()}
            let entered = XCTestExpectation(description:acquisition ? "real load entered" : "real recognizer consumer entered")
            if acquisition {r.acquisitionGate = gate;r.acquisitionEntered = entered}
            else {r.consumerGate = gate;r.consumerEntered = entered}
            guard await hubSaved(r) else {return}
            r.controller.transcribeRemaining(); guard await hubEntered([entered]) else {return}
            XCTAssertEqual(r.enqueues,1); let job = try XCTUnwrap(r.recognitionJobs.first)
            XCTAssertFalse(job.operation.hasExited)
            XCTAssertTrue(r.controller.reserveRestart()); let drain = HubRestartDrain(r.controller)
            guard await hubEntered([drain.entered]) else {return}
            XCTAssertFalse(drain.returned); XCTAssertFalse(r.controller.restartReady()); XCTAssertFalse(r.bottom.descriptors.isEmpty)
            r.controller.releaseRestart(); gate.open()
            guard await hubEntered([drain.exited]) else {return}
            XCTAssertEqual(drain.allowed,false); XCTAssertTrue(job.operation.hasExited); XCTAssertFalse(gate.timedOut)
            XCTAssertEqual(r.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,0)
            XCTAssertTrue(r.copies.isEmpty); XCTAssertEqual(r.engine.starts.value,1)
        }
    }
    @MainActor func testHeldAcceptedReadForLeaveDeleteSettingsAndSecurityCannotPublishOrCopy() async throws {
        enum Revocation: CaseIterable {case leave,delete,settings,security}
        for reason in Revocation.allCases {
            let r = try MeetingHubRig(); defer {r.release()}
            guard await hubSaved(r) else {return}
            r.controller.transcribeRemaining(); guard await hubComplete({await r.controller.drainActions()}) else {return}
            let accepted = try XCTUnwrap(r.controller.model.metadata?.chunks.first?.accepted)
            let entered = XCTestExpectation(description:"accepted text actual read for \(reason)")
            let held = HubCheckpointHold(entered:entered,match:{$0 == "read-open" && $1?.hasSuffix(".raw.txt") == true})
            defer {held.latch.open()}; r.bottom.observe = held.observe
            if reason == .delete {r.controller.openSavedText()} else {r.controller.copyText()}
            guard await hubEntered([entered]) else {return}
            switch reason {
            case .leave:r.controller.leavePage()
            case .delete:
                let confirmation = try XCTUnwrap(r.controller.deleteConfirmation)
                r.controller.deleteConfirmed(session:confirmation.session,intent:confirmation.intent)
            case .settings:
                var settings = r.settings.current;settings.language = "fr";r.settings.current = settings;r.changedSettings()
            case .security:r.securityAllowed = false
            }
            XCTAssertTrue(r.copies.isEmpty)
            held.latch.open()
            guard await hubComplete({await r.controller.drainActions()}) else {return}
            // The named trigger alone must suppress the completed read, before lifecycle cleanup.
            XCTAssertTrue(r.copies.isEmpty);XCTAssertNil(r.controller.model.text);XCTAssertFalse(held.latch.timedOut)
            if reason != .delete {XCTAssertEqual(r.controller.model.metadata?.chunks.first?.accepted,accepted)}
            r.controller.reserveShutdown();let drain = HubRestartDrain(r.controller)
            guard await hubEntered([drain.entered,drain.exited]) else {return}
            XCTAssertEqual(drain.allowed,true)
        }
    }
}


/// Future filesystem use is confined to this logged, owned fixture. No fixture is
/// created by artifact authoring. Failure to create/close/remove throws, never attests OS support.
private final class HubRestartFixture {
    let root: URL, device: dev_t, inode: ino_t
    init() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil));defer {free(physical)}
        root = URL(fileURLWithPath:String(cString:physical),isDirectory:true).appendingPathComponent("meeting-test-completion-\(UUID().uuidString.lowercased())")
        guard mkdir(root.path,0o700) == 0 else {throw MeetingSession.Failure.unavailable}
        var info = stat();guard lstat(root.path,&info) == 0,info.st_uid == getuid(),info.st_mode & 0o7777 == 0o700 else {throw MeetingSession.Failure.unavailable}
        device = info.st_dev;inode = info.st_ino
        try recordWave4BFixture(root,"created")
        let stamp = try JSONSerialization.data(withJSONObject:["uid":info.st_uid,"device":info.st_dev,"inode":info.st_ino,"mode":info.st_mode,"birthSec":info.st_birthtimespec.tv_sec,"birthNS":info.st_birthtimespec.tv_nsec,"mtimeSec":info.st_mtimespec.tv_sec,"mtimeNS":info.st_mtimespec.tv_nsec],options:[.sortedKeys])
        try recordWave4BFixture(root,"identity:"+String(decoding:stamp,as:UTF8.self))
    }
    func removeAfterClose() throws {
        var info = stat();guard lstat(root.path,&info) == 0,info.st_dev == device,info.st_ino == inode,info.st_uid == getuid() else {throw MeetingSession.Failure.stale}
        try recordWave4BFixture(root,"closed")
        try FileManager.default.removeItem(at:root)
        try recordWave4BFixture(root,"removed")
    }
}
extension MeetingHubCompositionTests {
    @MainActor func testActualSavedImportRestartRejectsClaimAndRetainsSuccessfulClaimUntilOutcome() async throws {
        for accept in [false,true] {
            let fixture = try HubRestartFixture(),r = try MeetingHubRig();defer {r.release()}
            guard await hubSaved(r) else {return}
            let session = try XCTUnwrap(r.controller.model.metadata?.session)
            let saved = SavedAudioImportOwner(root:fixture.root.appendingPathComponent("saved-imports"))
            let apple = AppleOwnerRig()
            let parakeet = ParakeetPreparation(inputs:.closed,storage:.init(root:fixture.root.appendingPathComponent("unused-parakeet")),
                trust:.init(host:{XCTFail("restart cannot query host")},read:{_,_ in XCTFail("restart cannot read trust");throw MeetingSession.Failure.unavailable},signature:{_,_ in XCTFail("restart cannot query signature")}),
                app:URL(fileURLWithPath:"/virtual/unused-app"),worker:.init(launch:{_ in XCTFail("restart cannot launch helper");throw MeetingSession.Failure.unavailable}))
            let local = LocalCleanupAdmission(),experimental = ExperimentalHistoryRetryOwner(),reservation = ImportRestartReservation()
            var claims = 0,claimReleases = 0,parakeetReleases = 0
            let releaseSub = parakeet.$snapshot.dropFirst().sink {_ in
                if !parakeet.admissionClosed {
                    parakeetReleases += 1
                    XCTAssertFalse(apple.owner.admissionClosed,"first acquired participant releases last")
                    XCTAssertFalse(r.controller.restartReady(),"meeting receipt already released before Parakeet")
                    XCTAssertTrue(local.reserveRestart());local.releaseRestart()
                    XCTAssertTrue(experimental.reserveRestart());experimental.releaseRestart()
                    XCTAssertTrue(saved.reserveRestart());saved.releaseRestart()
                }
            };defer {releaseSub.cancel()}
            guard await hubComplete({
                await saved.drain()
                let claimed = await AppDelegate.withSavedImportRestart(saved,parakeet:parakeet,apple:apple.owner,local:local,experimental:experimental,
                    chain:{nil},reservation:reservation,meeting:r.controller,releaseClaim:{
                        claimReleases += 1
                        XCTAssertTrue(r.controller.restartReady(),"claim releases first, while matching meeting receipt is still retained")
                        XCTAssertTrue(apple.owner.admissionClosed);XCTAssertTrue(parakeet.admissionClosed)
                    },claim:{
                        claims += 1;XCTAssertTrue(r.controller.restartReady());XCTAssertTrue(r.bottom.descriptors.isEmpty)
                        XCTAssertTrue(apple.owner.admissionClosed);XCTAssertTrue(parakeet.admissionClosed)
                        return accept
                    })
                XCTAssertEqual(claimed,accept);XCTAssertEqual(claims,1)
                if accept {
                    XCTAssertTrue(reservation.isHeld);XCTAssertTrue(r.controller.restartReady());XCTAssertEqual(claimReleases,0)
                    reservation.release();reservation.release();XCTAssertEqual(claimReleases,1)
                } else {XCTAssertFalse(reservation.isHeld);XCTAssertEqual(claimReleases,0)}
                XCTAssertFalse(r.controller.restartReady());XCTAssertFalse(apple.owner.admissionClosed);XCTAssertFalse(parakeet.admissionClosed)
                XCTAssertEqual(parakeetReleases,1)
                XCTAssertTrue(saved.reserveRestart());saved.releaseRestart() // rejected/retained-then-released admission is reusable
                r.controller.openPage();await r.controller.drainActions()
                XCTAssertEqual(r.controller.model.metadata?.session,session);XCTAssertEqual(r.engine.starts.value,1);XCTAssertEqual(r.enqueues,0)
                await saved.drain()
                do {try saved.store.close();try fixture.removeAfterClose()} catch {XCTFail("owned fixture close/removal failed: \(error)")}
            }) else {return}
        }
        // Actual receipt owner reverses arbitrary acquired receipts and consumes them once.
        // Combined with the helper case above this observes its claim-first boundary and once-only behavior.
        let receipt = ImportRestartReservation();var order: [String] = []
        receipt.retain(["parakeet","apple","local","experimental","saved","meeting","claim"].map {name in {order.append(name)}})
        receipt.release();receipt.release()
        XCTAssertEqual(order,["claim","meeting","saved","experimental","local","apple","parakeet"])
    }
}


extension MeetingHubCompositionTests {
    @MainActor func testActualAppleWillSetRecheckPreservesHeldAuthorityAndRefusalCannotReviveIt() async throws {
        for refuse in [false,true] {
            let r = try MeetingHubRig(),consumer = HubOwnedLatch(),preparation = HubOwnedLatch()
            defer {consumer.open();preparation.open();r.release()}
            let apple = AppleOwnerRig()
            apple.reserved = ["en-US"]
            apple.memory.data = try AppleSpeechReservationRecord(entries:[.init(locale:"en-US",state:.owned,prepared:true)]).encoded()
            var saved = r.settings.current;saved.recognitionEngine = .appleSpeech;saved.appleSpeechLocale = "en-US";r.settings.current = saved
            var beforeAssignment = false,sawChecking = false,sawWaiting = false
            let subscription = apple.owner.$snapshot.sink {emitted in
                beforeAssignment = beforeAssignment || emitted != apple.owner.snapshot
                sawChecking = sawChecking || emitted.phase == .checking
                sawWaiting = sawWaiting || emitted.phase == .waiting
                r.controller.applePreparationChanged(emitted) // emitted value, never owner's old @Published storage
            }
            defer {subscription.cancel()}
            apple.configure();guard await hubComplete({await apple.chain?.value}) else {return}
            XCTAssertEqual(apple.owner.snapshot.phase,.ready)
            let entered = XCTestExpectation(description:"actual Apple-selected meeting consumer held")
            r.consumerGate = consumer;r.consumerEntered = entered
            guard await hubSaved(r) else {return}
            r.controller.transcribeRemaining();guard await hubEntered([entered]) else {return}
            let job = try XCTUnwrap(r.recognitionJobs.first)
            XCTAssertTrue(job.context.authority.current)
            let prepEntered = XCTestExpectation(description:"read-only recheck queued worker entered")
            apple.owner.enqueue = {operation,work,finished in
                apple.chain = PendingOperationQueue.enqueue(previous:apple.chain,operation:operation,completes:true,work:{
                    prepEntered.fulfill();await preparation.wait();await work()
                },finished:finished)
            }
            apple.owner.act(.recheck,locale:"en-US",token:apple.owner.snapshot.token)
            guard await hubEntered([prepEntered]) else {return}
            XCTAssertTrue(sawWaiting);XCTAssertTrue(job.context.authority.current);XCTAssertFalse(job.operation.shouldAbort)
            if refuse {apple.installed = false}
            preparation.open();guard await hubComplete({await apple.chain?.value}) else {return}
            XCTAssertTrue(beforeAssignment);XCTAssertTrue(sawChecking)
            XCTAssertEqual(job.context.authority.current,!refuse)
            if refuse {
                XCTAssertEqual(apple.owner.snapshot.refusal,.assetsUnavailable)
                apple.installed = true
                // Restore through a real ready publication; revoked authority stays revoked.
                apple.owner.enqueue = {operation,work,finished in apple.chain = PendingOperationQueue.enqueue(previous:apple.chain,operation:operation,completes:true,work:work,finished:finished)}
                apple.owner.act(.recheck,locale:"en-US",token:apple.owner.snapshot.token)
                guard await hubComplete({await apple.chain?.value}) else {return}
                XCTAssertEqual(apple.owner.snapshot.phase,.ready);XCTAssertFalse(job.context.authority.current)
            }
            consumer.open();guard await hubComplete({await r.controller.drainActions()}) else {return}
            XCTAssertEqual(r.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,refuse ? 0 : 1)
            XCTAssertEqual(r.enqueues,1);XCTAssertTrue(r.copies.isEmpty);XCTAssertFalse(consumer.timedOut);XCTAssertFalse(preparation.timedOut)
        }
    }
    @MainActor func testHeldFrozenConfigurationChangesAndRevertsNeverRestartRecognition() async throws {
        enum Edit: CaseIterable {case locale,model,filter,invalid}
        for edit in Edit.allCases {
            let r = try MeetingHubRig(),gate = HubOwnedLatch();defer {gate.open();r.release()}
            var saved = r.settings.current
            if edit == .locale {saved.recognitionEngine = .appleSpeech;saved.appleSpeechLocale = "en-US"
                r.controller.applePreparationChanged(.init(phase:.ready,locale:"en-US"))
            } else {saved.recognitionEngine = .parakeet;saved.parakeetModelID = ParakeetWire.model
                var ready = ParakeetSnapshot();ready.phase = .ready;ready.refusal = nil;r.controller.parakeetPreparationChanged(ready)
            }
            r.settings.current = saved
            let entered = XCTestExpectation(description:"frozen configuration has actual consumer")
            r.consumerGate = gate;r.consumerEntered = entered
            guard await hubSaved(r) else {return}
            r.controller.transcribeRemaining();guard await hubEntered([entered]) else {return}
            let job = try XCTUnwrap(r.recognitionJobs.first)
            var changed = saved
            switch edit {case .locale:changed.appleSpeechLocale = "fr-FR";case .model:changed.parakeetModelID = "different";case .filter:changed.parakeetLanguageFilter = "pl";case .invalid:changed.recognitionEngine = .invalid}
            r.settings.current = changed;r.changedSettings()
            XCTAssertFalse(job.context.authority.current);XCTAssertTrue(job.operation.shouldAbort);XCTAssertFalse(job.operation.hasExited)
            r.settings.current = saved;r.changedSettings();XCTAssertFalse(job.context.authority.current)
            r.controller.reserveShutdown();let drain = HubRestartDrain(r.controller)
            guard await hubEntered([drain.entered]) else {return}
            XCTAssertFalse(drain.returned);gate.open();guard await hubEntered([drain.exited]) else {return}
            XCTAssertEqual(drain.allowed,true);XCTAssertEqual(r.enqueues,1);XCTAssertTrue(job.operation.hasExited)
            XCTAssertEqual(r.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,0);XCTAssertFalse(gate.timedOut)
        }
    }
    @MainActor func testRealParakeetReadyRepublishChangesTokenWithoutRevokingHeldCurrencyAndMapsFacts() async throws {
        let p = try G2aRig(),r = try MeetingHubRig(),gate = HubOwnedLatch();defer {gate.open();r.release()}
        p.settings.inputDeviceUID = "first";p.settings.whisperModelPath = "/virtual/model"
        var identity = stat();guard lstat(p.root.path,&identity) == 0,identity.st_uid == getuid() else {throw MeetingSession.Failure.unavailable}
        let device = identity.st_dev,inode = identity.st_ino
        let stamp = try JSONSerialization.data(withJSONObject:["uid":identity.st_uid,"device":identity.st_dev,"inode":identity.st_ino,"mode":identity.st_mode,"birthSec":identity.st_birthtimespec.tv_sec,"birthNS":identity.st_birthtimespec.tv_nsec,"mtimeSec":identity.st_mtimespec.tv_sec,"mtimeNS":identity.st_mtimespec.tv_nsec],options:[.sortedKeys])
        try recordWave4BFixture(p.root,"identity:"+String(decoding:stamp,as:UTF8.self))
        var willSet = false
        let subscription = p.owner.$snapshot.sink {emitted in
            willSet = willSet || emitted != p.owner.snapshot;r.controller.parakeetPreparationChanged(emitted)
        };defer {subscription.cancel()}
        let child = G2aChild()
        guard await hubComplete({do {try await p.install();try await p.prepare(child)} catch {XCTFail("fake preparation failed")}}) else {return}
        let emittedRequest = await child.native.request
        let request = try XCTUnwrap(emittedRequest)
        let observed = RecognitionIdentity(engine:.parakeet,selection:.parakeet(model:ParakeetWire.model,filter:"pl"),artifact:.parakeet(request.identity),generation:nil,runtime:nil,unknownRevisionScope:request.identity.session)
        let row = try MeetingRecognitionExecution.observedProvenance(identity:observed,id:UUID(),generation:1)
        XCTAssertEqual(row.engine,.parakeet);XCTAssertEqual(row.artifact,.unknown);XCTAssertEqual(row.model,ParakeetWire.model);XCTAssertEqual(row.filter,"pl")
        XCTAssertEqual(row.helperDigest,"");XCTAssertEqual(row.releaseDigest,"");XCTAssertEqual(row.sdkRevision,"");XCTAssertEqual(row.modelRevision,"")
        XCTAssertEqual(row.verification,"");XCTAssertNil(row.fileGeneration);XCTAssertEqual(row.expectedBytes,0)
        let requested = try MeetingRecognitionExecution.requestedProvenance(request:.init(settings:p.settings),id:UUID(),generation:1)
        XCTAssertEqual(requested.model,ParakeetWire.model);XCTAssertEqual(requested.filter,"pl");XCTAssertEqual(requested.artifact,.unknown)
        var selected = p.settings;selected.inputDeviceUID = "first";selected.whisperModelPath = "/virtual/model"
        r.settings.current = selected
        let entered = XCTestExpectation(description:"actual Parakeet-selected meeting consumer entered")
        r.consumerGate = gate;r.consumerEntered = entered
        guard await hubSaved(r) else {return};r.controller.transcribeRemaining();guard await hubEntered([entered]) else {return}
        let job = try XCTUnwrap(r.recognitionJobs.first),old = p.owner.snapshot.token
        p.owner.configure(p.settings)
        XCTAssertNotEqual(p.owner.snapshot.token,old);XCTAssertEqual(p.owner.snapshot.phase,.ready);XCTAssertTrue(willSet)
        XCTAssertTrue(job.context.authority.current);XCTAssertFalse(job.operation.shouldAbort)
        var cosmetic = p.owner.snapshot;cosmetic.token = UUID();cosmetic.bytes = 123;cosmetic.total = 456;cosmetic.canPrepare.toggle()
        r.controller.parakeetPreparationChanged(cosmetic)
        XCTAssertTrue(job.context.authority.current);XCTAssertFalse(job.operation.shouldAbort)
        // Actual Hub draft callback plus real owner will-set publisher: typed refusal/ready-scope loss revokes.
        let ui = try HubExportRig(meeting:r);ui.hub.bindParakeet(p.owner)
        ui.hub.onParakeetDraftChanged()
        XCTAssertEqual(p.owner.snapshot.refusal,.configuration);XCTAssertFalse(job.context.authority.current)
        p.owner.configure(p.settings,valid:true);XCTAssertFalse(job.context.authority.current)
        gate.open();guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,0);XCTAssertEqual(r.enqueues,1)
        guard await hubComplete({do {try await ui.close()} catch {XCTFail("Hub-owned fixture close failed")}}) else {return}
        guard await hubComplete({
            XCTAssertTrue(p.owner.reserveRestart());let ready = await p.owner.drainRestart(chain:{p.chain});XCTAssertTrue(ready)
            do {
                var closing = stat();guard lstat(p.root.path,&closing) == 0,closing.st_dev == device,closing.st_ino == inode,closing.st_uid == getuid() else {throw MeetingSession.Failure.stale}
                try recordWave4BFixture(p.root,"closed");try FileManager.default.removeItem(at:p.root);try recordWave4BFixture(p.root,"removed")
            } catch {XCTFail("owned fake preparation fixture cleanup failed")}
        }) else {return}
        XCTAssertFalse(gate.timedOut)
    }
}


extension MeetingHubCompositionTests {
    @MainActor func testActualDeadlineExpiryKeepsDeletionAndEnteredRestartDrainPendingUntilUnlinkReturns() async throws {
        let r = try MeetingHubRig();defer {r.release()}
        // Expiry can unlink a sealed saved source; an unsubmitted live tail is deliberately discarded.
        guard await hubSaved(r) else {return}
        let saved = try XCTUnwrap(r.controller.model.metadata)
        XCTAssertEqual(saved.chunks.filter {$0.stage == .sealed}.count,1)
        XCTAssertTrue(r.controller.reserveRestart());let retirement = HubRestartDrain(r.controller)
        guard await hubEntered([retirement.entered,retirement.exited]) else {return}
        XCTAssertEqual(retirement.allowed,true);r.controller.releaseRestart()
        let entered = XCTestExpectation(description:"deadline-requested expiry reached actual sealed source unlink")
        let held = HubCheckpointHold(entered:entered,match:{$0 == "unlink" && $1?.hasSuffix(".source.wav") == true})
        defer {held.latch.open()};r.bottom.observe = held.observe
        var calls = 0
        r.controllerWall = {
            calls += 1
            if calls == 1 {return r.clock} // metadata reentry remains unexpired
            if calls == 2 {return saved.expires} // arm the real deadline with zero remaining delay
            r.clock = saved.expires;return saved.expires // authoritative expiry is observed at the callback
        }
        r.controller.openPage()
        guard await hubEntered([entered]) else {return}
        XCTAssertEqual(r.engine.starts.value,1);XCTAssertEqual(r.enqueues,0)
        XCTAssertTrue(r.controller.model.metadata?.expired == true || r.controller.model.metadata?.deleting == true)
        r.controller.reserveShutdown();let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered]) else {return}
        XCTAssertFalse(drain.returned);XCTAssertFalse(r.controller.restartReady());XCTAssertFalse(r.bottom.descriptors.isEmpty)
        held.latch.open();guard await hubEntered([drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,true);XCTAssertTrue(r.bottom.descriptors.isEmpty);XCTAssertFalse(held.latch.timedOut)
        XCTAssertTrue(r.copies.isEmpty)
    }
    @MainActor func testActualDeadlineRevokesHeldAcceptedCopyBeforeReadReturnAndJoinsIt() async throws {
        for expireStoreDuringRead in [false,true] {
            let r = try MeetingHubRig();defer {r.release()}
            guard await hubSaved(r) else {return}
            r.controller.transcribeRemaining();guard await hubComplete({await r.controller.drainActions()}) else {return}
            let saved = try XCTUnwrap(r.controller.model.metadata),expiry = saved.expires
            XCTAssertNotNil(saved.chunks.first?.accepted)
            XCTAssertTrue(r.controller.reserveRestart());let retirement = HubRestartDrain(r.controller)
            guard await hubEntered([retirement.entered,retirement.exited]) else {return}
            XCTAssertEqual(retirement.allowed,true);r.controller.releaseRestart()
            let deadlineEntered = XCTestExpectation(description:"real single deadline entered owner expiry evaluator")
            var calls = 0
            r.controllerWall = {
                calls += 1
                if calls == 1 {return r.clock}
                if calls == 2 {return expiry-2_000_000_000} // real two-second Task.sleep
                if calls == 3 {
                    if expireStoreDuringRead {r.clock = expiry}
                    deadlineEntered.fulfill()
                }
                return expiry
            }
            r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
            XCTAssertEqual(calls,2)
            let entered = XCTestExpectation(description:"accepted copy actual read entered before deadline")
            let held = HubCheckpointHold(entered:entered,match:{$0 == "read-open" && $1?.hasSuffix(".raw.txt") == true})
            defer {held.latch.open()};r.bottom.observe = held.observe
            r.controller.copyText();guard await hubEntered([entered]) else {return}
            guard await hubEntered([deadlineEntered]) else {return}
            XCTAssertTrue(r.copies.isEmpty);XCTAssertNil(r.controller.model.text)
            held.latch.open()
            guard await hubComplete({await r.controller.drainActions()}) else {return}
            // Timer intent alone rejects completed read publication before any shutdown fence.
            XCTAssertTrue(r.copies.isEmpty);XCTAssertNil(r.controller.model.text);XCTAssertFalse(held.latch.timedOut)
            if !expireStoreDuringRead {
                // Keep the entered read's authoritative store clock stable to isolate timer revocation.
                XCTAssertEqual(r.controller.model.metadata?.chunks.first?.accepted,saved.chunks.first?.accepted)
                // After actual read/expiry-action exit, advance storage time for separate clean expiry cleanup.
                r.clock = expiry;r.controller.openPage()
                guard await hubComplete({await r.controller.drainActions()}) else {return}
            }
            r.controller.reserveShutdown();let drain = HubRestartDrain(r.controller)
            guard await hubEntered([drain.entered,drain.exited]) else {return}
            if expireStoreDuringRead {
                // Authoritative expiry invalidating an entered storage read deliberately quarantines it.
                XCTAssertEqual(drain.allowed,false);XCTAssertFalse(r.controller.restartReady())
                XCTAssertFalse(r.bottom.descriptors.isEmpty)
            } else {
                XCTAssertEqual(drain.allowed,true);XCTAssertTrue(r.bottom.descriptors.isEmpty)
            }
        }
    }
}


private final class HubInertMicrophone: MicrophoneTestCapturing {
    func start(operation:UUID,lease:CaptureAdmission.Lease) throws {XCTFail("export cannot start microphone");throw MeetingSession.Failure.unavailable}
    func snapshot(operation:UUID) -> MicrophoneCaptureSnapshot? {XCTFail("export cannot snapshot microphone");return nil}
    func stop(operation:UUID) -> [Float] {XCTFail("export cannot stop microphone");return []}
    func clear(operation:UUID) {XCTFail("export cannot clear microphone")}
}
/// Literal C API getters, not a native Whisper constructor. Produces one actual
/// timing-mapper cue through the same import queue/review route as production.
private final class HubSubtitleNative: @unchecked Sendable {
    private let text: UnsafeMutablePointer<CChar>
    init() {
        let bytes = Array("Literal cue".utf8CString);text = .allocate(capacity:bytes.count)
        for (index,byte) in bytes.enumerated() {text[index] = byte}
    }
    deinit {text.deallocate()}
    func factory() -> RecognitionFactory {
        RecognitionFactory(native:{[self] _,_ in
            var api = WhisperCContext.API();api.multilingual = true;api.knowsLanguage = {_ in true}
            api.spokenLanguage = {"en"};api.full = {_,_,_ in 0};api.count = {1}
            api.text = {[self] _ in UnsafePointer(text)};api.start = {_ in 0};api.end = {_ in 10};api.release = {}
            return WhisperCContext(api:api)
        },runtime:{.init(nativeVersion:"literal-fake",buildScope:"meeting-test")},metadata:{_ in nil},admit:{_,_ in})
    }
}
@MainActor private final class HubExportRig {
    let fixture: HubRestartFixture, meeting: MeetingHubRig, hub: HubModel
    let audio = AudioImportOwner(), native = HubSubtitleNative(), admission = LocalCleanupAdmission()
    let saved: SavedAudioImportOwner, sourceURL: URL
    var chain: Task<Void,Never>?, writes: [(Data,URL)] = [], panels = 0
    var destination: URL, writerError = false, writerHook: (() -> Void)?
    var observationTimedOut = false
    init(capability: Bool = false,meeting supplied: MeetingHubRig? = nil) throws {
        fixture = try HubRestartFixture()
        if let supplied {meeting = supplied} else {meeting = try MeetingHubRig(capability:capability)}
        let root = fixture.root, settings = meeting.store
        sourceURL = root.appendingPathComponent("original.wav")
        try retainedSyntheticWAV().write(to:sourceURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:sourceURL.path)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("recordings"),withIntermediateDirectories:false)
        destination = root.appendingPathComponent("safe.txt")
        saved = SavedAudioImportOwner(root:root.appendingPathComponent("saved-imports"),clock:{Date(timeIntervalSince1970:2_000_000)})
        audio.savedImports = saved;audio.security = {false};audio.sourceAccess.start = {_ in false}
        audio.sourceAccess.stop = {_ in XCTFail("unacquired source scope stopped")};audio.sourceAccess.metadata = {_,_ in}
        let microphone = MicrophoneTestController(capture:HubInertMicrophone(),allowed:{false},permission:{false},now:{0},schedule:{_,_ in {}})
        let history = HistoryStore(url:root.appendingPathComponent("history.json"),persistence:.init(writeAtomically:{_,_ in XCTFail("export cannot mutate history");throw MeetingSession.Failure.unavailable}))
        let recordings = RecordingStore(directory:root.appendingPathComponent("recordings"),keepAll:false,
            access:{_ in XCTFail("export cannot access recording")},writer:{_,_ in XCTFail("export cannot write audio");throw MeetingSession.Failure.unavailable},remover:{_ in XCTFail("export cannot remove recording")})
        hub = HubModel(store:settings,history:history,clipboard:{_ in XCTFail("export is not Copy")},recordings:recordings,
            shortcutLabels:ShortcutLabels(center:NotificationCenter(),snapshot:{ShortcutDisplayFormatter {_ in nil}}),diagnostics:DiagnosticStore(),
            microphoneTest:microphone,audioImport:audio,meetingHub:meeting.controller)
        hub.audioImportExportPanel = {[unowned self] _ in panels += 1;return destination}
        hub.historyExportPanel = {[unowned self] _ in panels += 1;return destination}
        hub.vocabularyExportPanel = {[unowned self] in panels += 1;return destination}
        hub.diagnosticPanel = {[unowned self] _ in panels += 1;return destination}
        let write: (Data,URL) throws -> Void = {[unowned self] bytes,url in
            writerHook?();writes.append((bytes,url));if writerError {throw MeetingSession.Failure.unavailable}
        }
        hub.historyExportWriter = write;hub.vocabularyExportWriter = write;hub.diagnosticWriter = write
        hub.onAudioImport = {[unowned self] job,done in
            let next = AudioImportExecution.enqueue(previous:chain,admission:admission,job:job,store:settings,load:{[self] request in
                try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:native.factory(),operation:job.operation,selectionEpoch:job.selectionEpoch,preparationEpoch:job.preparationEpoch)
            },done:done);if let next {chain = next}
        }
        saved.enqueue = {[unowned self] job,done in
            let next = SavedAudioImportExecution.enqueue(previous:chain,admission:admission,store:saved.store,job:job,settings:settings,
                now:{Date(timeIntervalSince1970:2_000_000)},load:{[self] request in
                    try await RecognitionAcquisition.acquire(request:request,resident:nil,factory:native.factory(),operation:job.operation,selectionEpoch:job.authority.selectionEpoch,preparationEpoch:job.authority.preparationEpoch)
                },done:done);if let next {chain = next};return next
        }
    }
    func transientReview() async throws {
        hub.selectAudioImport(sourceURL);hub.startTimedAudioImport();await chain?.value
        guard audio.review?.segments != nil else {throw MeetingSession.Failure.unavailable}
    }
    func savedReview() async throws {
        await saved.drain();hub.selectAudioImport(sourceURL);hub.keepAudioImportAndTranscribe();await chain?.value;await saved.drain()
        guard saved.review?.accepted != nil else {throw MeetingSession.Failure.unavailable}
    }
    func close() async throws {
        audio.invalidate(nil);saved.invalidate();await chain?.value;await saved.drain();try saved.store.close()
        meeting.controller.reserveShutdown();guard await meeting.controller.drainRestart() else {throw MeetingSession.Failure.unavailable}
        try fixture.removeAfterClose()
    }
}
@MainActor private enum HubFailedCallerResources {
    private static var retained: [HubExportRig] = []
    static func retain(_ r: HubExportRig) {
        guard !retained.contains(where:{$0 === r}) else {return}
        retained.append(r);r.meeting.controller.leavePage()
        // Unknown actual exit: retain ownership and log it, never join a new held task after timeout.
        do {try recordWave4BFixture(r.fixture.root,"retained:unobserved-test-exit")} catch {XCTFail("could not log retained fixture")}
    }
}
extension MeetingHubCompositionTests {
    @MainActor private func withCallers(capability: Bool = false,_ action: @escaping (HubExportRig) async throws -> Void) async throws {
        let r = try HubExportRig(capability:capability)
        var budgetExpired = false
        let completed = await hubComplete({
            do {
                await r.saved.drain()
                _ = try r.saved.protection() // positive callers require completed saved-storage metadata
                try await action(r)
            } catch {XCTFail("actual caller setup/action failed: \(error)")}
            guard !budgetExpired,!r.observationTimedOut else {HubFailedCallerResources.retain(r);return}
            do {try await r.close()} catch {XCTFail("actual caller owned fixture cleanup failed: \(error)");HubFailedCallerResources.retain(r)}
        })
        if !completed {budgetExpired = true;HubFailedCallerResources.retain(r)}
    }
    @MainActor func testActualHistoryVocabularyAndDiagnosticsActionsSuccessProtectionRefusalAndThrow() async throws {
        try await withCallers {r in
            enum Caller: CaseIterable {case history,vocabulary,diagnostics}
            for caller in Caller.allCases {
                func prepare() {
                    switch caller {
                    case .history:r.hub.historyExport = .init(scope:"literal saved review",entries:[.init(date:Date(timeIntervalSince1970:0),raw:"Literal history")])
                    case .vocabulary:break
                    case .diagnostics:r.hub.prepareDiagnostics()
                    }
                }
                func run() {
                    switch caller {case .history:r.hub.exportHistory(content:.original,format:.text);case .vocabulary:r.hub.exportVocabulary();case .diagnostics:r.hub.exportDiagnostics()}
                }
                func success() -> Bool {
                    switch caller {case .history:return r.hub.historyExportMessage?.hasPrefix("Exported ") == true
                    case .vocabulary:return r.hub.transferMessage == "Exported words, snippets, and replacements."
                    case .diagnostics:return r.hub.diagnosticMessage == "Diagnostics exported."}
                }
                let ext = caller == .history ? "txt" : "json"
                prepare();r.destination = r.fixture.root.appendingPathComponent("safe.\(ext)")
                r.writerHook = {
                    XCTAssertFalse(r.meeting.controller.reserveRestart());XCTAssertFalse(r.meeting.bottom.descriptors.isEmpty)
                    do {
                        try r.meeting.controller.withExportProtection(validateDestination:{_ in},perform:{})
                        XCTFail("Reentrant export protection must refuse before the writer enters.")
                    } catch { }
                }
                let before = r.writes.count;run();XCTAssertEqual(r.writes.count,before+1);XCTAssertTrue(success());XCTAssertTrue(r.meeting.bottom.descriptors.isEmpty)
                prepare();r.destination = r.meeting.bottom.rootURL.appendingPathComponent("blocked.\(ext)");run()
                XCTAssertEqual(r.writes.count,before+1);XCTAssertFalse(success());XCTAssertTrue(r.meeting.bottom.descriptors.isEmpty)
                prepare();r.destination = r.fixture.root.appendingPathComponent("throw.\(ext)");r.writerError = true;run();r.writerError = false
                XCTAssertEqual(r.writes.count,before+2);XCTAssertFalse(success());XCTAssertTrue(r.meeting.bottom.descriptors.isEmpty)
            }
            XCTAssertEqual(r.panels,9);XCTAssertEqual(r.meeting.engine.starts.value,0);XCTAssertEqual(r.meeting.bottom.payloadReads,0)
        }
    }
    @MainActor func testActualVTTAndSRTActionsSuccessMeetingRefusalAndFinalCurrentFalse() async throws {
        try await withCallers {r in
            for srt in [false,true] {
                try await r.transientReview()
                let run = {if srt {r.hub.exportAudioImportSRT()} else {r.hub.exportAudioImportVTT()}}
                let ext = srt ? "srt" : "vtt",before = r.writes.count
                r.destination = r.fixture.root.appendingPathComponent("safe.\(ext)")
                r.writerHook = {XCTAssertFalse(r.meeting.controller.reserveRestart());XCTAssertFalse(r.meeting.bottom.descriptors.isEmpty)}
                run();XCTAssertEqual(r.writes.count,before+1)
                XCTAssertTrue(r.audio.message?.hasPrefix("Exported current native segments") == true)
                XCTAssertTrue(String(decoding:r.writes.last!.0,as:UTF8.self).contains("Literal cue"))
                r.destination = r.meeting.bottom.rootURL.appendingPathComponent("blocked.\(ext)");run()
                XCTAssertEqual(r.writes.count,before+1);XCTAssertFalse(r.audio.message?.hasPrefix("Exported current native segments") == true)
                r.destination = r.fixture.root.appendingPathComponent("throw.\(ext)");r.writerError = true;run();r.writerError = false
                XCTAssertEqual(r.writes.count,before+2);XCTAssertEqual(r.audio.message,"Couldn’t export. Choose a writable location and explicitly try again; this review is still available.")
                r.destination = r.fixture.root.appendingPathComponent("stale.\(ext)")
                var injected = false
                r.meeting.bottom.observe = {op,_ in if op == "protection-before-final",!injected {injected = true;r.audio.invalidate("final-current revoked")}}
                run();r.meeting.bottom.observe = nil
                XCTAssertTrue(injected);XCTAssertEqual(r.writes.count,before+2);XCTAssertEqual(r.audio.message,"final-current revoked")
                XCTAssertTrue(r.meeting.bottom.descriptors.isEmpty)
            }
        }
    }
    @MainActor func testActualSavedTextActionBeginRefusalAllowIOFalseExactEndAndThrow() async throws {
        try await withCallers {r in
            try await r.savedReview()
            let id = try XCTUnwrap(r.saved.rows.first?.id)
            func reopen() async throws {r.hub.openSavedAudioImport(id);await r.saved.drain();guard r.saved.review != nil else {throw MeetingSession.Failure.unavailable}}
            let success = "Raw text exported. The saved job and independent History are unchanged."
            r.destination = r.fixture.root.appendingPathComponent("safe.txt")
            var io: [Bool] = []
            let sub = r.saved.$ioBusy.dropFirst().sink {value in
                io.append(value)
            };defer {sub.cancel()}
            r.writerHook = {XCTAssertTrue(r.saved.ioBusy);XCTAssertFalse(r.meeting.controller.reserveRestart());XCTAssertFalse(r.meeting.bottom.descriptors.isEmpty)}
            r.hub.exportSavedAudioImportText();XCTAssertEqual(r.writes.count,1);XCTAssertEqual(io,[true,false]);XCTAssertEqual(r.saved.message,success)
            io = [];r.destination = r.meeting.bottom.rootURL.appendingPathComponent("blocked.txt");r.hub.exportSavedAudioImportText()
            XCTAssertEqual(r.writes.count,1);XCTAssertTrue(io.isEmpty);XCTAssertNotEqual(r.saved.message,success)
            r.destination = r.fixture.root.appendingPathComponent("begin-refused.txt")
            var injected = false
            r.meeting.bottom.observe = {op,_ in if op == "protection-before-final",!injected {injected = true;r.saved.invalidate("revoked before beginOutputIO")}}
            r.hub.exportSavedAudioImportText();r.meeting.bottom.observe = nil
            XCTAssertTrue(injected);XCTAssertEqual(r.writes.count,1);XCTAssertTrue(io.isEmpty);XCTAssertEqual(r.saved.message,"revoked before beginOutputIO")
            sub.cancel();try await reopen()
            io = []
            let during = r.saved.$ioBusy.dropFirst().sink {value in io.append(value);if value {r.saved.invalidate("revoked after beginOutputIO")}}
            r.hub.exportSavedAudioImportText();during.cancel()
            XCTAssertEqual(io,[true,false]);XCTAssertEqual(r.writes.count,1);XCTAssertEqual(r.saved.message,"revoked after beginOutputIO");XCTAssertFalse(r.saved.ioBusy)
            try await reopen();io = []
            let throwing = r.saved.$ioBusy.dropFirst().sink {io.append($0)};defer {throwing.cancel()}
            r.writerError = true;r.hub.exportSavedAudioImportText();r.writerError = false
            XCTAssertEqual(r.writes.count,2);XCTAssertEqual(io,[true,false]);XCTAssertFalse(r.saved.ioBusy)
            XCTAssertEqual(r.saved.message,"Couldn’t export. Retry export writes this same current raw text without transcription.")
            XCTAssertTrue(r.meeting.bottom.descriptors.isEmpty)
        }
    }
    @MainActor func testActualCallerGuardKeepsIncumbentProtectionUnionAndSavedMemberIdentity() async throws {
        try await withCallers {r in
            try await r.savedReview()
            let projection = try r.saved.protection()
            let member = try XCTUnwrap(projection.files.first)
            let hardlink = r.fixture.root.appendingPathComponent("protected-hardlink.txt")
            guard link(r.sourceURL.path,hardlink.path) == 0 else {throw MeetingSession.Failure.unavailable}
            let recordingAlias = r.fixture.root.appendingPathComponent("recordings-alias")
            let sourceAlias = r.fixture.root.appendingPathComponent("original-alias.wav")
            try FileManager.default.createSymbolicLink(at:recordingAlias,withDestinationURL:r.hub.recordingDirectory)
            try FileManager.default.createSymbolicLink(at:sourceAlias,withDestinationURL:r.sourceURL)
            var writes = 0
            let old = [recordingAlias.appendingPathComponent("new.txt"),sourceAlias,r.hub.store.url,r.hub.history.url,r.hub.recordingDirectory.appendingPathComponent("new.txt"),r.sourceURL,r.saved.store.storage.root.appendingPathComponent("new.txt"),member,hardlink]
            for destination in old {
                XCTAssertThrowsError(try r.hub.withValidatedExportDestination(destination,fileExtension:destination.pathExtension,perform:{writes += 1}))
            }
            XCTAssertEqual(writes,0)
            try r.hub.withValidatedExportDestination(r.fixture.root.appendingPathComponent("safe-union.txt"),fileExtension:"txt",perform:{writes += 1})
            XCTAssertEqual(writes,1);XCTAssertEqual(r.meeting.bottom.payloadReads,0)
        }
    }
}


extension MeetingHubCompositionTests {
    @MainActor func testR3ActualHubAppleRecheckHookPreservesActiveAuthorityWhileMutationCancelAndDraftRevoke() async throws {
        enum Hook: CaseIterable {case recheck,prepare,cancel,draft}
        for hook in Hook.allCases {
            try await withCallers(capability:true) {r in
                let consumer = HubOwnedLatch(),preparation = HubOwnedLatch();defer {consumer.open();preparation.open()}
                let apple = AppleOwnerRig();apple.reserved = ["en-US"]
                apple.memory.data = try AppleSpeechReservationRecord(entries:[.init(locale:"en-US",state:.owned,prepared:true)]).encoded()
                var saved = r.meeting.settings.current;saved.recognitionEngine = .appleSpeech;saved.appleSpeechLocale = "en-US";r.meeting.settings.current = saved
                var willSet = false
                let sub = apple.owner.$snapshot.sink {emitted in
                    willSet = willSet || emitted != apple.owner.snapshot;r.meeting.controller.applePreparationChanged(emitted)
                };defer {sub.cancel()}
                apple.configure();await apple.chain?.value
                XCTAssertEqual(apple.owner.snapshot.phase,.ready)
                r.hub.bindAppleSpeech(apple.owner) // actual production Hub action/cancel/draft closures
                let consumerEntered = XCTestExpectation(description:"actual held meeting consumer for real Hub hook")
                r.meeting.consumerGate = consumer;r.meeting.consumerEntered = consumerEntered
                guard await self.hubSaved(r.meeting) else {r.observationTimedOut = true;throw MeetingSession.Failure.unavailable}
                r.meeting.controller.transcribeRemaining();guard await self.hubEntered([consumerEntered]) else {r.observationTimedOut = true;throw MeetingSession.Failure.unavailable}
                let job = try XCTUnwrap(r.meeting.recognitionJobs.first),token = apple.owner.snapshot.token
                if hook == .recheck || hook == .prepare {
                    let prepEntered = XCTestExpectation(description:"actual Hub action queued preparation worker")
                    apple.owner.enqueue = {operation,work,finished in
                        apple.chain = PendingOperationQueue.enqueue(previous:apple.chain,operation:operation,completes:true,work:{prepEntered.fulfill();await preparation.wait();await work()},finished:finished)
                    }
                    r.hub.onAppleSpeechAction(hook == .recheck ? .recheck : .prepare,"en-US",token)
                    guard await self.hubEntered([prepEntered]) else {r.observationTimedOut = true;throw MeetingSession.Failure.unavailable}
                    XCTAssertEqual(apple.owner.snapshot.phase,.waiting)
                    XCTAssertEqual(job.context.authority.current,hook == .recheck)
                    XCTAssertEqual(job.operation.shouldAbort,hook != .recheck)
                    if hook == .prepare {apple.owner.cancel(token:apple.owner.snapshot.token)}
                    preparation.open();await apple.chain?.value
                } else if hook == .cancel {r.hub.onAppleSpeechCancel(token)}
                else {r.hub.onAppleSpeechDraftChanged()}
                XCTAssertEqual(job.context.authority.current,hook == .recheck);XCTAssertTrue(willSet)
                consumer.open();await r.meeting.controller.drainActions()
                XCTAssertEqual(r.meeting.controller.model.metadata?.chunks.filter {$0.accepted != nil}.count,hook == .recheck ? 1 : 0)
                XCTAssertEqual(r.meeting.enqueues,1);XCTAssertTrue(r.meeting.copies.isEmpty)
                XCTAssertFalse(consumer.timedOut);XCTAssertFalse(preparation.timedOut)
            }
        }
    }
}


extension MeetingHubCompositionTests {
    @MainActor func testHeldActualControllerStreamWriterKeepsEnteredDrainPendingAndCancellationCannotRevive() async throws {
        let r = try MeetingHubRig();defer {r.release()}
        r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.startAndSave();guard await hubComplete({await r.controller.drainActions()}) else {return}
        guard await hubEntered([r.engine.started]) else {return}
        let entered = XCTestExpectation(description:"production-bound controller stream writer actually entered")
        let held = HubCheckpointHold(entered:entered,match:{$0 == "write" && $1?.hasSuffix(".source.pending") == true})
        defer {held.latch.open()};r.bottom.observe = held.observe
        for offset in stride(from:0,to:480_000,by:8_192) {r.engine.emit(Array(repeating:0.5,count:min(8_192,480_000-offset)))}
        guard await hubEntered([entered]) else {return}
        let late = try XCTUnwrap(r.engine.copied)
        XCTAssertTrue(r.controller.reserveRestart());let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered]) else {return}
        XCTAssertFalse(drain.returned);XCTAssertFalse(r.controller.restartReady())
        r.controller.releaseRestart();late(AdapterEngine.pcm([1]))
        held.latch.open();guard await hubEntered([drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,false);XCTAssertFalse(held.latch.timedOut)
        XCTAssertEqual(r.engine.starts.value,1);XCTAssertEqual(r.enqueues,0);XCTAssertTrue(r.copies.isEmpty)
        XCTAssertTrue(r.bottom.descriptors.isEmpty)
        r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
        XCTAssertEqual(r.engine.starts.value,1);XCTAssertNotNil(r.controller.model.metadata)
    }
}


/// Thread-safe observations only; the MainActor continues owning every production action.
private final class HubSynchronousObservation: @unchecked Sendable {
    private let lock = NSLock();private var queuedValue = false
    let entered = DispatchSemaphore(value:0),workerExit = XCTestExpectation(description:"independent synchronous-guard observer returned")
    func queued() {lock.withLock {queuedValue = true}}
    var didQueue: Bool {lock.withLock {queuedValue}}
}
extension MeetingHubCompositionTests {
    @MainActor func testActualHistoryProtectionAndWriterHoldTheirAtomicTurnUntilIndependentRelease() async throws {
        for holdProtection in [false,true] {
            try await withCallers {r in
                await r.saved.drain()
                let gate = HubOwnedLatch(),observation = HubSynchronousObservation();defer {gate.open()}
                let enteredDrain = XCTestExpectation(description:"queued lifecycle actually entered after synchronous guard")
                let returnedDrain = XCTestExpectation(description:"queued lifecycle actually returned after synchronous guard")
                var callerReturned = false
                r.destination = r.fixture.root.appendingPathComponent("atomic.txt")
                r.hub.historyExport = .init(scope:"literal",entries:[.init(raw:"Literal history")])
                DispatchQueue.global().async {
                    guard observation.entered.wait(timeout:.now()+2) == .success else {XCTFail("actual synchronous entry not observed");gate.open();observation.workerExit.fulfill();return}
                    DispatchQueue.main.async {
                        XCTAssertTrue(callerReturned,"queued quit cannot enter while protection/writer still owns the MainActor turn")
                        XCTAssertTrue(r.meeting.bottom.descriptors.isEmpty)
                        enteredDrain.fulfill()
                        r.meeting.controller.beginShutdown {ready in XCTAssertTrue(ready);returnedDrain.fulfill()}
                    }
                    observation.queued();gate.open();observation.workerExit.fulfill()
                }
                if holdProtection {
                    var first = true
                    r.meeting.bottom.observe = {op,_ in if first,op == "protection-entry" {first = false;observation.entered.signal();gate.hold()}}
                } else {
                    r.writerHook = {
                        XCTAssertFalse(r.meeting.controller.restartReady());XCTAssertFalse(r.meeting.controller.reserveRestart())
                        observation.entered.signal();gate.hold();XCTAssertTrue(observation.didQueue)
                    }
                }
                r.hub.exportHistory(content:.original,format:.text);callerReturned = true;r.meeting.bottom.observe = nil
                XCTAssertTrue(gate.entered);XCTAssertTrue(observation.didQueue);XCTAssertEqual(r.writes.count,1)
                guard await self.hubEntered([observation.workerExit,enteredDrain,returnedDrain]) else {r.observationTimedOut = true;throw MeetingSession.Failure.unavailable}
                XCTAssertFalse(gate.timedOut);XCTAssertTrue(r.meeting.controller.restartReady())
            }
        }
    }
}


extension MeetingHubCompositionTests {
    @MainActor func testRawShutdownRefusesNewIntentWhileCanceledPermissionDriverRemains() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.permission = .undetermined
        r.controller.openPage()
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        r.controller.startAndSave()
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        let callback = try XCTUnwrap(r.pendingPermission); r.pendingPermission = nil
        defer { callback(false) }
        r.controller.reserveShutdown(); r.controller.releaseRestart()
        var overlap: [Bool] = []
        r.controller.beginShutdown { overlap.append($0) }
        // A retained A driver cannot be adopted by a newly minted raw B intent.
        XCTAssertEqual(overlap,[false]); XCTAssertFalse(r.controller.restartReady())
        XCTAssertFalse(r.controller.reserveRestart()); XCTAssertTrue(r.controller.model.busy)
        callback(false)
        guard await hubModel(r.controller, { $0.state == .detached && !$0.busy }) else { return }
        XCTAssertEqual(overlap,[false]); XCTAssertTrue(r.bottom.descriptors.isEmpty)
        r.controller.openPage()
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        var writes = 0
        try r.controller.withExportProtection(validateDestination:{ _ in },perform:{ writes += 1 })
        XCTAssertEqual(writes,1); XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0)
    }
    @MainActor func testCanceledDeferredReplyStaysFalseBeforeLaterNoOwnerIntentSucceeds() async throws {
        let r = try MeetingHubRig(capability:false); defer { r.release() }
        let oldReply = expectation(description:"old canceled reply returned")
        var old: [Bool] = []
        r.controller.beginShutdown { old.append($0); oldReply.fulfill() }
        r.controller.releaseRestart()
        guard await hubEntered([oldReply]) else { return }
        guard await hubModel(r.controller, { !$0.busy }) else { return }
        XCTAssertEqual(old,[false]); XCTAssertFalse(r.controller.restartReady())
        let newReply = expectation(description:"later exact intent returned")
        var current: [Bool] = []
        r.controller.beginShutdown { current.append($0); newReply.fulfill() }
        guard await hubEntered([newReply]) else { return }
        XCTAssertEqual(old,[false]); XCTAssertEqual(current,[true]); XCTAssertTrue(r.controller.restartReady())
        XCTAssertEqual(r.bottom.calls,0); XCTAssertEqual(r.engine.queries.value,0)
        r.controller.releaseRestart()
    }
}
