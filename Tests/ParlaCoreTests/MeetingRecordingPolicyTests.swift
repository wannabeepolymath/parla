import Darwin
import Foundation
import XCTest
@testable import ParlaCore

final class MeetingRecordingPolicyTests: XCTestCase {
    private func saved(success: Bool) throws -> MeetingVirtualRig {
        let rig = MeetingVirtualRig()
        _ = try rig.admit(); _ = try rig.seal(rig.input(0,frames:8000)); try rig.stop()
        if success { rig.testClock.value += 100; _ = try rig.result(meetingID(1000)) }
        return rig
    }
    func testPhysicalBackupExclusionOnOwnedEmptyDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parla-B43-backup-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let fd = Darwin.open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd,0); guard fd >= 0 else { return }; defer { Darwin.close(fd) }
        let bottom = MeetingDarwinBottom(uptime:{0},checkpoint:{_,_ in})
        try bottom.excludeFromBackup(fd)
        XCTAssertEqual(try root.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup,true)
    }
    func testStorageExclusionIsAppliedOnlyOnExplicitAdmission() throws {
        let r = MeetingVirtualRig()
        XCTAssertEqual(r.bottom.backupExclusions,0)
        _ = try r.admit(); XCTAssertEqual(r.bottom.backupExclusions,1)
        XCTAssertEqual(r.bottom.rootNode?.s.st_mode,0o40700)
        XCTAssertTrue(r.bottom.rootNode?.children.values.allSatisfy { $0.s.st_mode == 0o100600 } == true)
        try r.stop(); try r.store.detach()
    }
    func testSuccessfulAudioBoundaryPreservesTranscriptAndColdReopen() throws {
        let r = try saved(success:true), m = try XCTUnwrap(r.store.metadata())
        let raw = try XCTUnwrap(m.rawExpires)
        XCTAssertEqual(raw,r.testClock.value + 86_400_000_000_000)
        let result = try XCTUnwrap(m.chunks.first?.accepted)
        r.testClock.value = raw-1; try r.store.sweepRawAudio(authorized:{true})
        XCTAssertTrue(r.bottom.names.contains(MeetingSession.uuid(meetingID(1000))+".source.wav"))
        r.testClock.value = raw; try r.store.sweepRawAudio(authorized:{true})
        XCTAssertFalse(r.bottom.names.contains(MeetingSession.uuid(meetingID(1000))+".source.wav"))
        XCTAssertEqual(try r.store.readAccepted(session:r.session,chunk:meetingID(1000),result:result.id,authorized:{true}),Data(repeating:81,count:4096))
        XCTAssertThrowsError(try r.store.beginAttempt(chunk:meetingID(1000),requested:meetingProvenance(0,role:.requested),authorized:{true}))
        try r.store.detach()
        let reopened = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
        _ = try reopened.bootstrap()
        XCTAssertEqual(try reopened.metadata()?.chunks.first?.audioRemoved,true)
        XCTAssertEqual(try reopened.readAccepted(session:r.session,chunk:meetingID(1000),result:result.id,authorized:{true}).count,4096)
        r.testClock.value = m.expires
        try reopened.evaluate(); XCTAssertTrue(reopened.projection.expired)
        var deletion = try reopened.deleteIntent(id:meetingID(901),terminalGeneration:1,holdEpoch:1,authorized:{true})
        for _ in 0..<3 where deletion.deletionRemaining != 0 { deletion = try reopened.deleteSlice(deletion,authorized:{true}) }
        deletion = try reopened.deleteAuthority(deletion,authorized:{true}); _ = try reopened.deleteClose(deletion,authorized:{true})
        XCTAssertTrue(r.bottom.names.isEmpty)
    }
    func testFailedAudioBoundaryIsSevenDaysAndTranscriptBoundaryIsThirtyDays() throws {
        let r = try saved(success:false)
        let failed = try r.store.beginAttempt(chunk:meetingID(1000),requested:meetingProvenance(0,role:.requested),authorized:{true})
        _ = try r.store.finishAttempt(failed,canceled:false,authorized:{true})
        let m = try XCTUnwrap(r.store.metadata())
        XCTAssertEqual(m.rawExpires,m.created + 604_800_000_000_000)
        XCTAssertEqual(m.expires,m.created + 2_592_000_000_000_000)
        r.testClock.value = try XCTUnwrap(m.rawExpires)-1; try r.store.sweepRawAudio(authorized:{true})
        XCTAssertFalse(try XCTUnwrap(r.store.metadata()).chunks[0].audioRemoved)
        r.testClock.value += 1; try r.store.sweepRawAudio(authorized:{true})
        XCTAssertTrue(try XCTUnwrap(r.store.metadata()).chunks[0].audioRemoved)
        r.testClock.value = m.expires-1; try r.store.evaluate(); XCTAssertFalse(r.store.projection.expired)
        r.testClock.value += 1; try r.store.evaluate(); XCTAssertTrue(r.store.projection.expired)
        try r.store.detach()
    }
    func testKeepPersistsAcrossRestartAndExplicitDeleteOverridesKeep() throws {
        let r = try saved(success:true)
        _ = try r.store.setKeep(true,authorized:{true}); try r.store.detach()
        r.testClock.value += 2_592_000_000_000_001
        let reopened = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
        _ = try reopened.bootstrap(); try reopened.evaluate(); try reopened.sweepRawAudio(authorized:{true})
        XCTAssertTrue(try XCTUnwrap(reopened.metadata()).kept); XCTAssertFalse(reopened.projection.expired)
        XCTAssertFalse(try XCTUnwrap(reopened.metadata()).chunks[0].audioRemoved)
        var token = try reopened.deleteIntent(id:meetingID(900),terminalGeneration:1,holdEpoch:1,authorized:{true})
        for _ in 0..<3 where token.deletionRemaining != 0 { token = try reopened.deleteSlice(token,authorized:{true}) }
        token = try reopened.deleteAuthority(token,authorized:{true}); _ = try reopened.deleteClose(token,authorized:{true})
        XCTAssertTrue(r.bottom.names.isEmpty); XCTAssertTrue(r.bottom.descriptors.isEmpty)
    }
    func testDeleteResumesAnAlreadyUnlinkedRawRetentionIntentOnlyForItsExactSource() throws {
        for foreignMissing in [false,true] {
            let r = MeetingVirtualRig(); _ = try r.admit()
            for n in 0..<6 { _ = try r.seal(r.input(n,frames:8000)) }
            try r.stop(); try r.store.detach()
            let root = try XCTUnwrap(r.bottom.rootNode), manifest = try XCTUnwrap(root.children["manifest.json"])
            guard case .metadata(let bytes) = manifest.body else { return XCTFail("Missing durable metadata fixture") }
            var ledger = try MeetingSession.Ledger.decode(bytes)
            ledger.retention?.removing = ledger.chunks[4].id; ledger.revision += 1
            let durable = try ledger.encoded(tier:MeetingSession.ordinaryBytes)
            manifest.body = .metadata(durable); manifest.s.st_size = Int64(durable.count)
            root.children.removeValue(forKey:ledger.chunks[foreignMissing ? 5 : 4].name)
            let reopened = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
            defer { _ = try? reopened.detach() }
            if foreignMissing { XCTAssertThrowsError(try reopened.bootstrap()); continue }
            _ = try reopened.bootstrap()
            var deletion = try reopened.deleteIntent(id:meetingID(902),terminalGeneration:1,holdEpoch:1,authorized:{true})
            for _ in 0..<4 where deletion.deletionRemaining != 0 { deletion = try reopened.deleteSlice(deletion,authorized:{true}) }
            deletion = try reopened.deleteAuthority(deletion,authorized:{true}); _ = try reopened.deleteClose(deletion,authorized:{true})
            XCTAssertTrue(r.bottom.names.isEmpty)
        }
    }
    func testKeptAudioCanBeTranscribedAfterThirtyDaysAndUnkeepExpiresIt() throws {
        let r = try saved(success:false)
        _ = try r.store.setKeep(true,authorized:{true})
        r.testClock.value += 40 * 86_400_000_000_000
        _ = try r.result(meetingID(1000))
        XCTAssertFalse(r.store.projection.expired)
        XCTAssertNotNil(try r.store.metadata()?.chunks[0].accepted)
        _ = try r.store.setKeep(false,authorized:{true})
        try r.store.evaluate(); XCTAssertTrue(r.store.projection.expired)
        try r.store.detach()
    }
    func testRemovingKeepRestoresOriginalDeadlinesAndSweepWaitsForHolds() throws {
        let r = try saved(success:true), raw = try XCTUnwrap(r.store.metadata()?.rawExpires)
        _ = try r.store.setKeep(true,authorized:{true}); r.testClock.value = raw
        try r.store.sweepRawAudio(authorized:{true}); XCTAssertFalse(try XCTUnwrap(r.store.metadata()).chunks[0].audioRemoved)
        _ = try r.store.setKeep(false,authorized:{true})
        let hold = try r.store.register(.output)
        try r.store.sweepRawAudio(authorized:{true}); XCTAssertFalse(try XCTUnwrap(r.store.metadata()).chunks[0].audioRemoved)
        try r.store.actualExit(hold); try r.store.sweepRawAudio(authorized:{true})
        XCTAssertTrue(try XCTUnwrap(r.store.metadata()).chunks[0].audioRemoved)
        try r.store.detach()
    }
}
