import Foundation
import XCTest
@testable import ParlaCore

final class B43ReviewRetentionTests: XCTestCase {
    func testRawSweepHandlesRenameBeforeLedgerPublication() throws {
        let r = MeetingVirtualRig()
        _ = try r.admit()
        let input = try r.input(0,frames:8000)
        let a = try r.store.chunkA(input,authorized:{true})
        _ = try r.store.chunkB(a,bytes:input.bytes,authorized:{true})
        try r.store.detach()
        // Crash snapshot: chunkC renamed the source, but its new ledger was not published.
        let root = try XCTUnwrap(r.bottom.rootNode)
        let pending = MeetingSession.uuid(input.id)+".source.pending"
        let final = MeetingSession.uuid(input.id)+".source.wav"
        let node = try XCTUnwrap(root.children.removeValue(forKey:pending))
        node.name = final; node.s.st_ctimespec.tv_sec += 1; root.children[final] = node
        let reopened = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
        _ = try reopened.bootstrap()
        _ = try reopened.terminal(reason:.interrupted,unknownMask:3,generation:0,holdEpoch:1,flags:1,authorized:{true})
        r.testClock.value += MeetingSession.RecordingPolicy.failedAudioRetention
        XCTAssertNoThrow(try reopened.sweepRawAudio(authorized:{true}))
        XCTAssertFalse(r.bottom.names.contains(final),"Expired raw audio survives its sweep")
        XCTAssertTrue(try XCTUnwrap(reopened.metadata()).chunks[0].audioRemoved)
        try reopened.detach()
        let audited = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
        XCTAssertNoThrow(try audited.bootstrap(),"Raw unlink left an unauditable namespace")
        try audited.detach()
    }
    func testRawIntentCanRetireAfterTranscriptExpiry() throws {
        let r = MeetingVirtualRig()
        _ = try r.admit(); _ = try r.seal(r.input(0,frames:8000)); try r.stop()
        _ = try r.result(meetingID(1000)); try r.store.detach()
        let root = try XCTUnwrap(r.bottom.rootNode), manifest = try XCTUnwrap(root.children["manifest.json"])
        guard case .metadata(let bytes) = manifest.body else { return XCTFail("Missing fixture manifest") }
        var ledger = try MeetingSession.Ledger.decode(bytes)
        ledger.retention?.removing = ledger.chunks[0].id; ledger.revision += 1
        let data = try ledger.encoded(tier:MeetingSession.ordinaryBytes)
        manifest.body = .metadata(data); manifest.s.st_size = Int64(data.count)
        root.children.removeValue(forKey:ledger.chunks[0].name)
        r.testClock.value = ledger.expires
        let reopened = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
        _ = try reopened.bootstrap(); XCTAssertTrue(reopened.projection.expired)
        // The owner's expiry action always sweeps raw before entering whole-meeting deletion.
        XCTAssertNoThrow(try reopened.sweepRawAudio(authorized:{true}))
        try reopened.detach()
    }
    func testCrashPublicationDoesNotPermanentlyPreventRetention() throws {
        let r = MeetingVirtualRig()
        _ = try r.admit(); _ = try r.seal(r.input(0,frames:8000)); try r.stop(); try r.store.detach()
        // A crash while publishing the next metadata generation leaves this legitimate file.
        try r.bottom.add("manifest.next",data:Data("partial metadata".utf8))
        r.testClock.value += MeetingSession.RecordingPolicy.transcriptRetention
        let reopened = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
        XCTAssertNoThrow(try reopened.bootstrap())
        XCTAssertNoThrow(try reopened.sweepRawAudio(authorized:{true}))
        XCTAssertFalse(r.bottom.names.contains("manifest.next"))
        var deletion = try reopened.deleteIntent(id:meetingID(902),terminalGeneration:1,holdEpoch:1,authorized:{true})
        while deletion.deletionRemaining != 0 { deletion = try reopened.deleteSlice(deletion,authorized:{true}) }
        deletion = try reopened.deleteAuthority(deletion,authorized:{true})
        _ = try reopened.deleteClose(deletion,authorized:{true})
        XCTAssertTrue(r.bottom.names.isEmpty,"Expired audio is unreachable by retention")
        XCTAssertTrue(r.bottom.descriptors.isEmpty)
        // A genuine unknown entry must still prevent automatic recovery, without touching next.
        let foreign = MeetingVirtualRig(); _ = try foreign.admit(); try foreign.stop(); try foreign.store.detach()
        try foreign.bottom.add("manifest.next",data:Data("partial".utf8)); try foreign.bottom.add("foreign.txt")
        let refused = MeetingSessionStore(root:foreign.bottom.rootURL,profile:.init(),bottom:foreign.bottom,wallClock:{foreign.testClock.value})
        XCTAssertThrowsError(try refused.bootstrap())
        XCTAssertTrue(foreign.bottom.names.contains("manifest.next")); XCTAssertTrue(foreign.bottom.names.contains("foreign.txt"))
    }
    func testInvalidCommittedManifestAllowsOnlyExplicitBoundedOwnedDeletion() throws {
        for unsafe in ["none","unknown","symlink"] {
            let r = MeetingVirtualRig(); _ = try r.admit(); _ = try r.seal(r.input(0,frames:8000)); try r.stop(); try r.store.detach()
            let root = try XCTUnwrap(r.bottom.rootNode), manifest = try XCTUnwrap(root.children["manifest.json"])
            manifest.body = .metadata(Data("invalid".utf8)); manifest.s.st_size = 7
            try r.bottom.add("manifest.next",data:Data("unpublished".utf8))
            if unsafe == "unknown" { try r.bottom.add("foreign.txt") }
            if unsafe == "symlink" { root.children[MeetingSession.uuid(meetingID(1000))+".source.wav"]?.s.st_mode = 0o120600 }
            let reopened = MeetingSessionStore(root:r.bottom.rootURL,profile:.init(),bottom:r.bottom,wallClock:{r.testClock.value})
            XCTAssertThrowsError(try reopened.bootstrap())
            XCTAssertTrue(r.bottom.names.contains("manifest.next"),"Invalid committed authority must not permit automatic unlink")
            XCTAssertTrue(reopened.canDeleteUnavailableMeetingData)
            let before = r.bottom.names
            XCTAssertThrowsError(try reopened.deleteAllUnavailableMeetingData(authorized:{false}))
            XCTAssertEqual(r.bottom.names,before)
            if unsafe == "none" {
                try reopened.deleteAllUnavailableMeetingData(authorized:{true})
                XCTAssertTrue(r.bottom.names.isEmpty); XCTAssertEqual(reopened.projection,.idle)
            } else {
                XCTAssertThrowsError(try reopened.deleteAllUnavailableMeetingData(authorized:{true}))
                XCTAssertEqual(r.bottom.names,before,"Recovery must preflight all members before any deletion")
            }
            XCTAssertTrue(r.bottom.descriptors.isEmpty)
        }
    }
}
