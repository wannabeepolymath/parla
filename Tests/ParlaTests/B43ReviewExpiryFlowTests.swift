import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

final class B43ReviewExpiryFlowTests: XCTestCase {
    @MainActor func testStartupDeletesExpiredTranscriptWithInterruptedRawIntent() async throws {
        let saved = try MeetingHubRig()
        defer { saved.release() }
        saved.controller.openPage()
        guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.startConsentedRecording()
        guard await hubComplete({ await saved.controller.drainActions() }),await hubEntered([saved.engine.started]) else { return }
        saved.engine.emit([Float](repeating:0.5,count:8000))
        saved.controller.stopAndSave()
        guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.transcribeRemaining()
        guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.reserveShutdown()
        let drained = await saved.controller.drainRestart(); XCTAssertTrue(drained)
        let root = try XCTUnwrap(saved.bottom.rootNode), manifest = try XCTUnwrap(root.children["manifest.json"])
        guard case .metadata(let bytes) = manifest.body else { return XCTFail("Missing fixture manifest") }
        var ledger = try MeetingSession.Ledger.decode(bytes)
        let text = MeetingSession.uuid(try XCTUnwrap(ledger.chunks[0].accepted).id)+".raw.txt"
        XCTAssertNotNil(root.children[text])
        ledger.retention?.removing = ledger.chunks[0].id; ledger.revision += 1
        let data = try ledger.encoded(tier:MeetingSession.ordinaryBytes)
        manifest.body = .metadata(data); manifest.s.st_size = Int64(data.count)
        root.children.removeValue(forKey:ledger.chunks[0].name)
        let reopened = try MeetingHubRig(bottom:saved.bottom)
        defer { reopened.release() }
        reopened.clock = ledger.expires
        reopened.controller.maintainSavedMeeting()
        guard await hubComplete({ await reopened.controller.drainActions() }) else { return }
        XCTAssertNil(reopened.controller.model.metadata,"Startup expiry did not delete the expired meeting")
        XCTAssertNil(root.children[text],"Thirty-day-expired transcript is still on disk")
    }
}
