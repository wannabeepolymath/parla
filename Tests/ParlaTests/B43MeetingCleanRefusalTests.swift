import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

final class B43MeetingCleanRefusalTests: XCTestCase {
    @MainActor func testCleanCorruptManifestCanQuitWithoutDeletingData() async throws {
        let saved = try MeetingHubRig()
        defer { saved.release() }
        saved.controller.openPage()
        guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.startConsentedRecording()
        guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.stopAndSave()
        guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.reserveShutdown()
        let savedReady = await saved.controller.drainRestart()
        XCTAssertTrue(savedReady)
        let root = try XCTUnwrap(saved.bottom.rootNode)
        let manifest = try XCTUnwrap(root.children["manifest.json"])
        manifest.body = .metadata(Data("invalid".utf8)); manifest.s.st_size = 7
        let opened = try MeetingHubRig(bottom:saved.bottom)
        defer { opened.release() }
        opened.controller.maintainSavedMeeting()
        guard await hubComplete({ await opened.controller.drainActions() }) else { return }
        XCTAssertTrue(opened.bottom.descriptors.isEmpty)
        XCTAssertTrue(opened.controller.model.recoveryDeleteAvailable)
        XCTAssertEqual(opened.microphoneFactories,0)
        XCTAssertEqual(opened.enqueues,0)
        let names = Set(root.children.keys)
        let writeCount = opened.bottom.writes
        let reply = expectation(description:"quit participant reply")
        var allowed: Bool?
        opened.controller.beginShutdown { allowed = $0; reply.fulfill() }
        guard await hubEntered([reply]) else { return }
        XCTAssertEqual(allowed,true,"Known-drained cold corruption should allow Quit while preserving the saved files")
        XCTAssertTrue(opened.bottom.descriptors.isEmpty)
        XCTAssertEqual(Set(root.children.keys),names)
        XCTAssertEqual(opened.bottom.writes,writeCount)
        XCTAssertTrue(try XCTUnwrap(opened.meetingStores.first).actualHoldsDrained)
        XCTAssertFalse(try XCTUnwrap(opened.meetingStores.first).protectionQuarantined)
        opened.controller.cancelShutdown()
        opened.controller.openPage()
        guard await hubComplete({ await opened.controller.drainActions() }) else { return }
        let intent = try XCTUnwrap(opened.controller.recoveryDeleteConfirmation)
        opened.controller.deleteAllMeetingDataConfirmed(intent:intent)
        guard await hubComplete({ await opened.controller.drainActions() }) else { return }
        opened.controller.reserveShutdown()
        let deletedReady = await opened.controller.drainRestart()
        XCTAssertTrue(deletedReady)
    }
}
