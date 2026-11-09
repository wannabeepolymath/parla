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
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startConsentedRecording()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertTrue(r.controller.reserveRestart()); XCTAssertFalse(r.controller.restartReady())
        let callback = r.pendingPermission; r.pendingPermission = nil; callback?(true)
        guard await hubComplete({let ready = await r.controller.drainRestart(); XCTAssertTrue(ready)}) else { return }
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.enqueues,0); r.controller.releaseRestart()
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; XCTAssertEqual(r.engine.starts.value,0)
    }
    @MainActor func testKnownDetachOtherParticipantRejectAndExplicitReentryPreserveOccupancy() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }; r.controller.startConsentedRecording()
        guard await hubComplete({await r.controller.drainActions()}) else { return }
        guard await hubEntered([r.engine.started]) else { return }
        r.engine.emit([Float](repeating:0.5,count:8000)); r.controller.stopAndSave(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        let session = r.controller.model.metadata!.session; XCTAssertTrue(r.controller.reserveRestart())
        guard await hubComplete({let ready = await r.controller.drainRestart(); XCTAssertTrue(ready)}) else { return }
        r.controller.releaseRestart() // a later updater/participant refusal releases intent only
        r.controller.openPage(); guard await hubComplete({await r.controller.drainActions()}) else { return }
        XCTAssertEqual(r.controller.model.metadata?.session,session); r.controller.startConsentedRecording(); XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.enqueues,0)
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
            if kind == "metadata" {r.controller.openPage()} else {r.controller.startConsentedRecording()}
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
        r.controller.startConsentedRecording();guard await hubComplete({await r.controller.drainActions()}) else {return}
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
            r.controller.startConsentedRecording();guard await hubComplete({await r.controller.drainActions()}) else {return}
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
        r.controller.startConsentedRecording(); XCTAssertEqual(r.engine.starts.value,1)
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
        r.controller.startConsentedRecording(); guard await hubComplete({await r.controller.drainActions()}) else {return}
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
            r.clock = try XCTUnwrap(r.controller.model.metadata?.rawExpires)
            r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
            XCTAssertTrue(r.controller.model.metadata?.chunks.allSatisfy(\.audioRemoved) == true)
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
                    case .vocabulary:return r.hub.transferMessage == "Exported."
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
                XCTAssertEqual(r.writes.count,before+2);XCTAssertEqual(r.audio.message,"Couldn’t export. Choose another location and try again.")
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
            let success = "Text exported."
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
            XCTAssertEqual(r.saved.message,"Couldn’t export. Choose another location and try again.")
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
        r.controller.startConsentedRecording();guard await hubComplete({await r.controller.drainActions()}) else {return}
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
        r.controller.startConsentedRecording()
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

extension MeetingHubCompositionTests {
    @MainActor func testApplicationActualProducerBodyCleanupAndWriterOwnStop() async throws {
        let r = try HubApplicationRig();defer {r.release()}
        guard await r.start(self),let backend = r.backends.first else {return}
        let writerEntered = expectation(description:"application durable writer entered")
        let writer = HubCheckpointHold(entered:writerEntered,match:{$0 == "write" && $1?.hasSuffix(".source.pending") == true})
        defer {writer.latch.open();r.bottom.observe = nil};r.heldGates.append(writer.latch);r.bottom.observe = writer.observe
        r.controller.stopAndSave()
        // Observe this trigger's own port/fence before any restart or drain can mask it.
        guard await r.observe(self,[backend.stopRequested]) else {return}
        let ingress = try XCTUnwrap(backend.ingress)
        XCTAssertFalse(ingress.facts.open);XCTAssertTrue(ingress.facts.bodyEntered);XCTAssertEqual(try backend.latePCM(),0)
        XCTAssertEqual(r.controller.applicationState,.retiring)
        let stop = r.operation { [controller = r.controller] in await controller.drainActions();return true }
        guard await r.observe(self,[stop.entered]) else {return};XCTAssertNil(stop.result)
        XCTAssertFalse(backend.didComplete);XCTAssertFalse(r.controller.acceptSourceChoice(.microphone))
        backend.bodyExit.open();guard await r.observe(self,[backend.cleanupEntered]) else {return}
        XCTAssertFalse(ingress.facts.bodyEntered);XCTAssertFalse(ingress.facts.ended);XCTAssertNil(stop.result)
        backend.cleanup.open();guard await r.joinedActual(self,backend),await r.observe(self,[writerEntered]) else {return}
        XCTAssertNil(stop.result);XCTAssertFalse(r.controller.restartReady());XCTAssertEqual(r.controller.applicationState,.retiring)
        writer.latch.open();guard await r.finish(self,stop) else {return}
        XCTAssertEqual(r.controller.applicationState,.retiredPermissionUnknown);XCTAssertEqual(backend.stops,1);XCTAssertFalse(writer.latch.timedOut)
        guard await r.detach(self) else {return}
    }
    @MainActor func testPageAndWindowRevocationRequireFreshApplicationConsent() async throws {
        for window in [false,true] {
            for validationHeld in [false,true] {
                let r = try HubApplicationRig();defer {r.release()}
                guard await r.open(self) else {return}
                XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
                let challenge = try XCTUnwrap(r.controller.prepareApplicationStart())
                if validationHeld {r.validation = HubOwnedLatch();r.validationEntered = expectation(description:"app validation actually entered")}
                r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true)
                if validationHeld {guard let entry = r.validationEntered,await r.observe(self,[entry]) else {return}}
                else {guard await r.drain(self),let backend = r.backends.first,await r.observe(self,[backend.entered]) else {return}}
                let backend = try XCTUnwrap(r.backends.first)
                XCTAssertFalse(r.controller.acceptSourceChoice(.microphone))
                if window {r.controller.windowClosed()} else {r.controller.leavePage()}
                XCTAssertNil(r.controller.prepareApplicationStart());r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true)
                if !validationHeld {
                    guard await r.observe(self,[backend.stopRequested]) else {return}
                    XCTAssertFalse(try XCTUnwrap(backend.ingress).facts.open);XCTAssertTrue(try XCTUnwrap(backend.ingress).facts.bodyEntered)
                }
                let drain = r.operation { [controller = r.controller] in await controller.drainActions();return true }
                guard await r.observe(self,[drain.entered]) else {return};XCTAssertNil(drain.result)
                if validationHeld {r.validation?.open()}
                else {backend.bodyExit.open();backend.cleanup.open();guard await r.joinedActual(self,backend) else {return}}
                guard await r.finish(self,drain) else {return}
                XCTAssertEqual(backend.starts,validationHeld ? 0 : 1);XCTAssertEqual(r.factories,1)
                guard await r.open(self) else {return}
                r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true);XCTAssertEqual(r.factories,1)
                if validationHeld {
                    let fresh = try XCTUnwrap(r.controller.prepareApplicationStart());XCTAssertNotEqual(fresh.pageLifetime,challenge.pageLifetime)
                    r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:false)
                } else {XCTAssertNil(r.controller.prepareApplicationStart());XCTAssertNotNil(r.controller.model.metadata)}
                guard await r.detach(self) else {return}
            }
        }
    }
    @MainActor func testQuitRestartUpdaterJoinApplicationActualWorkWithoutRevival() async throws {
        enum Trigger: CaseIterable {case quit,quitAccept,restart,restartAccept,updater,updaterAccept}
        for trigger in Trigger.allCases {
            let r = try HubApplicationRig();defer {r.release()};guard await r.start(self),let backend = r.backends.first else {return}
            let writerEntered = expectation(description:"trigger-owned application writer entered")
            let writer = HubCheckpointHold(entered:writerEntered,match:{$0 == "write" && $1?.hasSuffix(".source.pending") == true})
            defer {writer.latch.open();r.bottom.observe = nil};r.heldGates.append(writer.latch);r.bottom.observe = writer.observe
            var operation: HubApplicationOperation?, termination: TerminationCoordinator?, replies: [Bool] = []
            var fixture: HubRestartFixture?, saved: SavedAudioImportOwner?, claims = 0, releases = 0
            let reservation = ImportRestartReservation()
            let quitReply = trigger == .quitAccept ? expectation(description:"actual termination reply after application retirement") : nil
            switch trigger {
            case .quit,.quitAccept:
                let value = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(trigger == .quitAccept)},meeting:{r.controller.beginShutdown($0)},
                    cancelMeeting:{r.controller.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0);quitReply?.fulfill()},failure:{},
                    onIntent:{r.controller.reserveShutdown()})
                termination = value;XCTAssertEqual(value.request(),trigger == .quitAccept ? .terminateLater : .terminateCancel)
            case .restart,.restartAccept:
                XCTAssertTrue(r.controller.reserveRestart())
                operation = r.operation { [controller = r.controller] in await controller.drainRestart() }
            case .updater,.updaterAccept:
                let root = try HubRestartFixture();fixture = root;r.auxiliaryRoots.append(root.root)
                let imports = SavedAudioImportOwner(root:root.root.appendingPathComponent("saved-imports"));saved = imports
                let apple = AppleOwnerRig(),local = LocalCleanupAdmission(),experimental = ExperimentalHistoryRetryOwner()
                let parakeet = ParakeetPreparation(inputs:.closed,storage:.init(root:root.root.appendingPathComponent("unused-parakeet")),
                    trust:.init(host:{XCTFail("app restart queried host")},read:{_,_ in XCTFail("app restart read trust");throw MeetingSession.Failure.unavailable},
                        signature:{_,_ in XCTFail("app restart queried signature")}),app:URL(fileURLWithPath:"/virtual/unused-app"),
                    worker:.init(launch:{_ in XCTFail("app restart launched helper");throw MeetingSession.Failure.unavailable}))
                operation = r.operation {
                    await imports.drain()
                    return await AppDelegate.withSavedImportRestart(imports,parakeet:parakeet,apple:apple.owner,local:local,experimental:experimental,
                        chain:{nil},reservation:reservation,meeting:r.controller,releaseClaim:{releases += 1;XCTAssertTrue(r.controller.restartReady())},claim:{
                            claims += 1;XCTAssertTrue(r.controller.restartReady());XCTAssertTrue(r.bottom.descriptors.isEmpty);return trigger == .updaterAccept
                        })
                }
            }
            // No generic Stop precedes the trigger-specific acquisition/fence observation.
            guard await r.observe(self,[backend.stopRequested]) else {return}
            let ingress = try XCTUnwrap(backend.ingress)
            XCTAssertFalse(ingress.facts.open);XCTAssertTrue(ingress.facts.bodyEntered);XCTAssertFalse(backend.didComplete)
            XCTAssertNil(r.controller.prepareApplicationStart());XCTAssertFalse(r.controller.acceptSourceChoice(.microphone))
            if let operation {guard await r.observe(self,[operation.entered]) else {return};XCTAssertNil(operation.result)}
            if trigger == .restart {r.controller.releaseRestart();XCTAssertFalse(r.controller.restartReady());XCTAssertFalse(r.controller.reserveRestart())}
            backend.bodyExit.open();guard await r.observe(self,[backend.cleanupEntered]) else {return}
            XCTAssertFalse(ingress.facts.ended);XCTAssertEqual(r.controller.applicationState,.retiring)
            backend.cleanup.open();guard await r.joinedActual(self,backend),await r.observe(self,[writerEntered]) else {return}
            XCTAssertNil(operation?.result);XCTAssertFalse(r.controller.restartReady());writer.latch.open()
            if let operation {guard await r.finish(self,operation) else {return};XCTAssertEqual(operation.result,trigger == .updaterAccept || trigger == .restartAccept)}
            if trigger == .quitAccept {
                let reply = try XCTUnwrap(quitReply)
                guard await r.observe(self,[reply]) else {return}
                XCTAssertEqual(replies,[true]);r.controller.releaseRestart()
            }
            if trigger == .restartAccept {XCTAssertTrue(r.controller.restartReady());r.controller.releaseRestart()}
            if trigger == .updaterAccept {
                XCTAssertTrue(reservation.isHeld);XCTAssertTrue(r.controller.restartReady());XCTAssertEqual(releases,0)
                reservation.release();reservation.release();XCTAssertEqual(releases,1);XCTAssertFalse(r.controller.restartReady())
            }
            guard await r.state(self,{$0.state == .detached && !$0.busy}) else {return}
            XCTAssertEqual(r.controller.applicationState,.retiredPermissionUnknown);XCTAssertEqual(backend.starts,1);XCTAssertEqual(replies,trigger == .quitAccept ? [true] : [])
            if trigger == .updater || trigger == .updaterAccept {
                XCTAssertEqual(claims,1);XCTAssertEqual(releases,trigger == .updaterAccept ? 1 : 0);XCTAssertFalse(reservation.isHeld)
                if let saved,let fixture {try saved.store.close();try fixture.removeAfterClose();r.auxiliaryRoots.removeAll()}
            }
            withExtendedLifetime(termination) {}
            r.controller.releaseRestart();guard await r.open(self) else {return}
            XCTAssertNil(r.controller.prepareApplicationStart());XCTAssertEqual(r.factories,1)
            guard await r.detach(self) else {return}
            XCTAssertFalse(writer.latch.timedOut)
        }
        let receipt = ImportRestartReservation();var order: [String] = []
        receipt.retain(["parakeet","apple","local","experimental","saved","meeting","claim"].map {name in {order.append(name)}})
        receipt.release();receipt.release();XCTAssertEqual(order,["claim","meeting","saved","experimental","local","apple","parakeet"])
    }
    @MainActor func testApplicationDeleteExpiryAndColdMetadataNeverRestartCapture() async throws {
        for expiry in [false,true] {
            let r = try HubApplicationRig();defer {r.release()};guard await r.start(self),let backend = r.backends.first else {return}
            r.controller.stopAndSave();backend.bodyExit.open();backend.cleanup.open()
            guard await r.joinedActual(self,backend),await r.drain(self),await r.detach(self),await r.open(self) else {return}
            XCTAssertEqual(r.factories,1);XCTAssertNil(r.controller.prepareApplicationStart())
            let unlinked = expectation(description:"application saved source unlink actually entered")
            let held = HubCheckpointHold(entered:unlinked,match:{$0 == "unlink" && $1?.hasSuffix(".source.wav") == true})
            defer {held.latch.open();r.bottom.observe = nil};r.heldGates.append(held.latch);r.bottom.observe = held.observe
            if expiry {r.clock = try XCTUnwrap(r.controller.model.metadata).expires;r.controller.openPage()}
            else {let deletion = try XCTUnwrap(r.controller.deleteConfirmation);r.controller.deleteConfirmed(session:deletion.session,intent:deletion.intent)}
            guard await r.observe(self,[unlinked]) else {return}
            XCTAssertTrue(r.bottom.events.contains {$0.0 == "intent-durable"})
            XCTAssertNil(r.controller.prepareApplicationStart());XCTAssertEqual(r.factories,1)
            r.controller.reserveShutdown();let draining = r.operation { [controller = r.controller] in await controller.drainRestart() }
            guard await r.observe(self,[draining.entered]) else {return};XCTAssertNil(draining.result)
            held.latch.open();guard await r.finish(self,draining) else {return}
            XCTAssertEqual(draining.result,true);XCTAssertEqual(r.factories,1);XCTAssertFalse(held.latch.timedOut);XCTAssertTrue(r.bottom.descriptors.isEmpty)
        }
    }
    @MainActor func testApplicationUnknownOwnedCleanupRetainsExactPortWithoutJoining() async throws {
        let r = try HubApplicationRig();defer {r.release()};r.unknownRetirement = true
        guard await r.start(self),let backend = r.backends.first else {return}
        r.controller.reserveShutdown();r.controller.releaseRestart()
        guard await r.observe(self,[backend.stopRequested]) else {return}
        backend.bodyExit.open();backend.cleanup.open()
        // Intentionally no source-completion observer, task.value, drainActions or teardown drain.
        guard await r.state(self,{$0.state == .unavailable}) else {return}
        XCTAssertEqual(r.controller.applicationState,.heldOrUnavailable)
        XCTAssertFalse(r.controller.restartReady());XCTAssertNil(r.controller.prepareApplicationStart())
        XCTAssertFalse(r.controller.acceptSourceChoice(.microphone));XCTAssertEqual(r.factories,1);XCTAssertEqual(backend.starts,1)
        XCTAssertFalse(try XCTUnwrap(backend.ingress).facts.producerFinished)
        HubApplicationFailureResources.retain(r) // deliberate unknown disposition retains exact owner/port/tasks
    }
}

extension MeetingHubCompositionTests {
    @MainActor func testInjectedIngressLossAndDuplicateEvidenceOnlyRetireTheFrozenRun() async throws {
        let r = try HubApplicationRig();defer {r.release()};guard await r.start(self),let backend = r.backends.first else {return}
        let consent = try XCTUnwrap(r.attempts.first?.consent),ingress = try XCTUnwrap(backend.ingress)
        // Scalar injected loss reaches the accepted ingress observer. Detection of native
        // route/format/permission loss remains in the unchanged Core, not in this fake.
        ingress.revoke()
        guard await r.observe(self,[backend.stopRequested]) else {return}
        XCTAssertFalse(ingress.facts.open);XCTAssertTrue(ingress.facts.bodyEntered);XCTAssertEqual(try backend.latePCM(),0)
        r.controller.applicationSourceInvalidated(consent);r.controller.applicationSourceInvalidated(consent)
        r.controller.whisperPreparationChanged(UUID());r.controller.focusChanged()
        XCTAssertNil(r.controller.prepareApplicationStart());XCTAssertEqual(r.factories,1);XCTAssertFalse(backend.didComplete)
        backend.bodyExit.open();backend.cleanup.open()
        guard await r.joinedActual(self,backend),await r.drain(self) else {return}
        XCTAssertEqual(r.controller.applicationState,.retiredPermissionUnknown)
        r.controller.applicationSourceInvalidated(consent);XCTAssertEqual(r.factories,1)
        XCTAssertNil(r.controller.prepareApplicationStart());XCTAssertEqual(backend.starts,1)
        guard await r.detach(self) else {return}
    }
}

extension MeetingHubCompositionTests {
    @MainActor func testApplicationDeleteAndImmediateDeadlineRevokeBeforeActualSourceExit() async throws {
        for expiry in [false,true] {
            let r = try HubApplicationRig();defer {r.release()};guard await r.open(self) else {return}
            XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
            let durable = expectation(description:"application delete intent is durable while source remains held")
            let intent = HubCheckpointHold(entered:durable,match:{ operation,_ in operation == "intent-durable" })
            defer {intent.latch.open();r.bottom.observe = nil};r.heldGates.append(intent.latch);r.bottom.observe = intent.observe
            if expiry {
                let expires = r.clock + MeetingSession.RecordingPolicy.transcriptRetention
                var reads = 0
                r.wallOverride = {
                    reads += 1
                    if reads == 1 {return expires} // arm the existing single deadline with zero remaining delay
                    r.clock = expires;return expires // expiry evaluation observes the same frozen time
                }
            }
            let factory = expectation(description:"exact application factory entered");r.factoryEntered = factory
            let challenge = try XCTUnwrap(r.controller.prepareApplicationStart())
            r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:true)
            guard await r.observe(self,[factory]),let backend = r.backends.first,await r.observe(self,[backend.entered]) else {return}
            if !expiry {
                guard await r.drain(self) else {return}
                let delete = try XCTUnwrap(r.controller.deleteConfirmation)
                r.controller.deleteConfirmed(session:delete.session,intent:delete.intent)
            }
            guard await r.observe(self,[backend.stopRequested,durable]) else {return}
            let ingress = try XCTUnwrap(backend.ingress)
            XCTAssertFalse(ingress.facts.open);XCTAssertTrue(ingress.facts.bodyEntered);XCTAssertEqual(try backend.latePCM(),0)
            XCTAssertFalse(backend.didComplete);XCTAssertNil(r.controller.prepareApplicationStart());XCTAssertFalse(r.controller.acceptSourceChoice(.microphone))
            let deleting = r.operation { [controller = r.controller] in await controller.drainActions();return true }
            guard await r.observe(self,[deleting.entered]) else {return};XCTAssertNil(deleting.result)
            intent.latch.open();backend.bodyExit.open();guard await r.observe(self,[backend.cleanupEntered]) else {return}
            XCTAssertFalse(backend.didComplete);XCTAssertNil(deleting.result)
            backend.cleanup.open();guard await r.joinedActual(self,backend),await r.finish(self,deleting) else {return}
            XCTAssertNil(r.controller.model.metadata);XCTAssertEqual(r.factories,1);XCTAssertFalse(intent.latch.timedOut)
            XCTAssertFalse(r.bottom.events.contains {$0.0 == "write" && $0.1?.hasSuffix(".source.pending") == true},"revoked unsubmitted tail cannot be published")
            let fresh = try XCTUnwrap(r.controller.prepareApplicationStart());XCTAssertNotEqual(challenge.id,fresh.id)
            r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:false)
            guard await r.detach(self) else {return}
        }
    }
}

/// Virtual storage checkpoint only; the original store operation remains held until true return.
private final class AccessCheckpointHold: @unchecked Sendable {
    let latch = HubOwnedLatch()
    let entered = XCTestExpectation(description:"access terminal/delete storage actually entered")
    let returned = XCTestExpectation(description:"access terminal/delete storage actually returned")
    private let lock = NSLock(), match: (String,String?) -> Bool
    private var used = false
    init(match: @escaping (String,String?) -> Bool) { self.match = match }
    func observe(_ operation: String,_ name: String?) {
        let take = lock.withLock { () -> Bool in guard !used,match(operation,name) else { return false }; used = true; return true }
        if take { entered.fulfill(); latch.hold(); returned.fulfill() }
    }
}
extension MeetingHubCompositionTests {
    @MainActor func testAccessSelfRetirementJoinsOwnerEvenWithoutPCM() async throws {
        for early in [false,true] {
            let r = try HubApplicationRig(); defer { r.release() }
            guard let backend = await r.accessBegin(self,early:early) else { return }
            let terminal = AccessCheckpointHold(match:{$0 == "encode-ledger" && $1 == "manifest.next"})
            defer { terminal.latch.open(); r.bottom.observe = nil }; r.heldGates.append(terminal.latch); r.bottom.observe = terminal.observe
            if !early { guard await r.accessDisposition(self,backend) else { return } }
            guard await r.observe(self,[backend.stopRequested]) else { return }
            let actual = try XCTUnwrap(backend.task), cached = try XCTUnwrap(r.controller.applicationAccessOutcome), outcome = cached.outcome
            XCTAssertEqual(cached.consent,r.attempts.last?.consent)
            XCTAssertEqual(actual,backend.forwarded); XCTAssertEqual(outcome,backend.accessOutcome)
            XCTAssertEqual(outcome.permission,.unknown); XCTAssertFalse(backend.didComplete)
            XCTAssertFalse(r.controller.acceptSourceChoice(.microphone)); XCTAssertEqual(r.factories,1)
            XCTAssertEqual(r.controller.applicationState,.retiring); XCTAssertFalse(terminal.latch.entered)
            let ingress = try XCTUnwrap(backend.ingress)
            XCTAssertTrue(ingress.facts.ended); XCTAssertEqual(ingress.facts.accepted,0); XCTAssertEqual(ingress.facts.copies,0)
            XCTAssertNil(ingress.readyPermit); XCTAssertTrue(ingress.facts.settled)
            backend.accessTail.open()
            guard await r.observe(self,[backend.accessTail.returned]),await r.joinedActual(self,backend),await r.observe(self,[terminal.entered]) else { return }
            XCTAssertEqual(backend.task,actual); XCTAssertTrue(r.controller.model.busy)
            XCTAssertFalse(r.controller.acceptSourceChoice(.microphone)); XCTAssertEqual(r.controller.applicationState,.retiring)
            terminal.latch.open(); guard await r.observe(self,[terminal.returned]),await r.state(self,{$0.state == .stopped && !$0.busy}) else { return }
            XCTAssertFalse(terminal.latch.timedOut); XCTAssertEqual(r.controller.applicationState,.retiredPermissionUnknown)
            let metadata = try XCTUnwrap(r.controller.model.metadata)
            XCTAssertTrue(metadata.chunks.isEmpty); XCTAssertFalse(r.bottom.names.contains {$0.hasSuffix(".source.wav") || $0.hasSuffix(".source.pending")})
            XCTAssertNil(r.controller.prepareApplicationStart()); XCTAssertNil(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract))
            XCTAssertEqual(r.factories,1); guard await r.accessDetach(self) else { return }
        }
    }
    @MainActor func testAccessAttemptLifecycleNeverResumesOrInventsExit() async throws {
        enum Trigger: CaseIterable { case stop, page, window, quit, canceledQuit, restart, canceledRestart, updaterIntent, delete, expiry }
        for trigger in Trigger.allCases {
            let r = try HubApplicationRig(); defer { r.release() }
            r.observationContext = "access lifecycle \(trigger)"
            guard let backend = await r.accessBegin(self,afterOpen: {
                if trigger == .expiry {
                    let expires = r.clock + MeetingSession.RecordingPolicy.transcriptRetention
                    var reads = 0
                    r.wallOverride = {
                        reads += 1
                        if reads == 1 { return expires } // scheduling does not advance the store creation clock
                        r.clock = expires; return expires // the deadline callback observes the frozen expiry
                    }
                }
            }) else { return }
            let attempt = try XCTUnwrap(r.attempts.first), key = try XCTUnwrap(backend.accessKey), exact = try XCTUnwrap(backend.task)
            if trigger != .expiry { guard await r.state(self,{$0.state == .recording && !$0.busy}) else { return } }
            var operation: HubApplicationOperation?, termination: TerminationCoordinator?, replies: [Bool] = []
            let reply = trigger == .quit ? XCTestExpectation(description:"quit reply after actual ownership exit") : nil
            switch trigger {
            case .stop: r.controller.stopAndSave()
            case .page: r.controller.leavePage()
            case .window: r.controller.windowClosed()
            case .quit,.canceledQuit:
                let value = TerminationCoordinator(clipboard:{$0(true)},updater:{$0(trigger == .quit)},meeting:{r.controller.beginShutdown($0)},
                    cancelMeeting:{r.controller.cancelShutdown()},cancelClipboard:{},cancelUpdater:{},reply:{replies.append($0);reply?.fulfill()},failure:{},
                    onIntent:{r.controller.reserveShutdown()})
                termination = value; XCTAssertEqual(value.request(),trigger == .quit ? .terminateLater : .terminateCancel)
            case .restart,.canceledRestart,.updaterIntent:
                // Updater's meeting participant uses this SAME reservation/drain; outer updater composition remains in its existing selector.
                XCTAssertTrue(r.controller.reserveRestart())
                operation = r.operation { [controller = r.controller] in await controller.drainRestart() }
            case .delete:
                let confirmation = try XCTUnwrap(r.controller.deleteConfirmation)
                r.controller.deleteConfirmed(session:confirmation.session,intent:confirmation.intent)
            case .expiry: break // the deadline itself must cause the stop below; no generic Stop can mask it
            }
            guard await r.observe(self,[backend.stopRequested]) else { return }
            XCTAssertFalse(try XCTUnwrap(backend.ingress).facts.open); XCTAssertFalse(backend.didComplete)
            XCTAssertEqual(backend.task,exact); XCTAssertNil(backend.accessOutcome); XCTAssertNil(r.controller.applicationAccessOutcome)
            XCTAssertEqual(r.factories,1); XCTAssertFalse(r.controller.acceptSourceChoice(.microphone)); XCTAssertFalse(r.controller.restartReady())
            if let operation { guard await r.observe(self,[operation.entered]) else { return }; XCTAssertNil(operation.result) }
            if trigger == .canceledRestart { r.controller.releaseRestart(); XCTAssertFalse(r.controller.reserveRestart()) }
            exact.cancel() // neither cancellation nor Stop can make the held native return happen
            guard await r.accessDisposition(self,backend) else { return }
            XCTAssertFalse(backend.didComplete); XCTAssertEqual(backend.task,exact)
            let stale = ApplicationAudioAccessOutcome(key:key,progress:.nativeStartReturned,disposition:.appOwnedRetired)
            attempt.receiveAccessOutcome(stale); attempt.receiveAccessOutcome(stale)
            XCTAssertEqual(r.factories,1); XCTAssertFalse(r.controller.restartReady())
            backend.accessTail.open()
            guard await r.observe(self,[backend.accessTail.returned]),await r.joinedActual(self,backend) else { return }
            if let operation {
                guard await r.finish(self,operation) else { return }
                XCTAssertEqual(operation.result,trigger != .canceledRestart)
                r.controller.releaseRestart()
            }
            if let reply { guard await r.observe(self,[reply]) else { return }; XCTAssertEqual(replies,[true]); r.controller.releaseRestart() }
            let detached = [.quit,.canceledQuit,.restart,.canceledRestart,.updaterIntent].contains(trigger)
            guard await r.state(self,{!$0.busy && (detached ? $0.state == .detached : trigger == .delete || trigger == .expiry ? $0.state == .idle : $0.state == .stopped)}) else { return }
            XCTAssertEqual(r.factories,1); withExtendedLifetime(termination) {}
            guard await r.accessOpen(self) else { return }
            attempt.receiveAccessOutcome(stale)
            XCTAssertNil(r.controller.applicationAccessOutcome); XCTAssertEqual(r.factories,1)
            if let challenge = r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract) {
                r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:false,purpose:.audioAccessAttemptContract)
            }
            guard await r.accessDetach(self) else { return }
        }
        let r = try HubApplicationRig(); defer { r.release() }; r.unknownRetirement = true
        guard let backend = await r.accessBegin(self) else { return }
        r.controller.reserveShutdown(); r.controller.releaseRestart()
        guard await r.observe(self,[backend.stopRequested]),await r.accessDisposition(self,backend) else { return }
        XCTAssertNil(backend.completionObserver); XCTAssertFalse(backend.didComplete); XCTAssertFalse(r.controller.restartReady())
        XCTAssertFalse(r.controller.reserveRestart()); XCTAssertFalse(r.controller.acceptSourceChoice(.microphone)); XCTAssertEqual(r.factories,1)
        HubApplicationFailureResources.retain(r) // deliberate uncertain task/owner; no completion observer or final join
    }
    @MainActor func testExplicitPostAttemptStartRequiresNewConsentIdentityAndDeletion() async throws {
        let r = try HubApplicationRig(); defer { r.release() }
        guard let backend = await r.accessBegin(self),await r.accessDisposition(self,backend),await r.accessFinish(self,backend) else { return }
        let old = try XCTUnwrap(r.attempts.first), oldOutcome = try XCTUnwrap(backend.accessOutcome)
        let empty = try XCTUnwrap(r.controller.model.metadata)
        XCTAssertTrue(empty.chunks.isEmpty); XCTAssertNil(r.controller.prepareApplicationStart())
        XCTAssertNil(r.controller.prepareApplicationStart(purpose:.audioAccessAttemptContract)); XCTAssertEqual(r.factories,1)
        let deletion = AccessCheckpointHold(match:{ operation, _ in operation == "intent-durable" })
        defer { deletion.latch.open(); r.bottom.observe = nil }; r.heldGates.append(deletion.latch); r.bottom.observe = deletion.observe
        let confirmation = try XCTUnwrap(r.controller.deleteConfirmation)
        r.controller.deleteConfirmed(session:confirmation.session,intent:confirmation.intent)
        guard await r.observe(self,[deletion.entered]) else { return }
        XCTAssertEqual(r.controller.model.metadata?.session,empty.session); XCTAssertNil(r.controller.prepareApplicationStart())
        XCTAssertEqual(r.factories,1); deletion.latch.open()
        guard await r.observe(self,[deletion.returned]),await r.state(self,{$0.state == .idle && !$0.busy && $0.metadata == nil}) else { return }
        r.bottom.observe = nil; XCTAssertFalse(deletion.latch.timedOut)
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot(launch:8))))
        let wrong = try XCTUnwrap(r.controller.prepareApplicationStart())
        r.controller.confirmApplicationStart(challengeID:wrong.id,affirmed:true,purpose:.audioAccessAttemptContract)
        r.controller.confirmApplicationStart(challengeID:wrong.id,affirmed:true); XCTAssertEqual(r.factories,1)
        let fresh = try XCTUnwrap(r.controller.prepareApplicationStart())
        XCTAssertEqual(fresh.purpose,.injectedRecordingContract)
        let factory = XCTestExpectation(description:"fresh explicitly retained factory entered"); r.factoryEntered = factory
        r.controller.confirmApplicationStart(challengeID:fresh.id,affirmed:true)
        guard await r.observe(self,[factory]),let retained = r.backends.last,await r.observe(self,[retained.entered]),
              await r.state(self,{$0.state == .recording && !$0.busy}) else { return }
        let next = try XCTUnwrap(r.attempts.last)
        XCTAssertEqual(next.mode,.retainedRecording); XCTAssertNotEqual(next.consent.startIntent,old.consent.startIntent)
        XCTAssertNotEqual(next.consent.source,old.consent.source); XCTAssertNotEqual(next.consent.session,old.consent.session)
        XCTAssertNotEqual(next.consent.captureEpoch,old.consent.captureEpoch); XCTAssertNotEqual(next.nonce,old.nonce)
        XCTAssertNotEqual(next.consent.challenge.sourceRevision,old.consent.challenge.sourceRevision)
        XCTAssertNotEqual(next.binding.launchNanoseconds,old.binding.launchNanoseconds)
        old.receiveAccessOutcome(oldOutcome); r.controller.applicationSourceInvalidated(old.consent)
        XCTAssertEqual(retained.stops,0); XCTAssertTrue(try XCTUnwrap(retained.ingress).facts.open)
        XCTAssertNil(r.controller.applicationAccessOutcome); XCTAssertEqual(r.controller.applicationState,.injectedRecording); XCTAssertEqual(r.factories,2)
        r.controller.stopAndSave(); guard await r.observe(self,[retained.stopRequested]) else { return }
        retained.bodyExit.open(); guard await r.observe(self,[retained.cleanupEntered]) else { return }
        retained.cleanup.open(); guard await r.joinedActual(self,retained),await r.state(self,{$0.state == .stopped && !$0.busy}) else { return }
        XCTAssertEqual(r.factories,2); guard await r.accessDetach(self) else { return }
    }
}
