import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

/// The same creation-result ownership classifier as HAL, with no native operation or fallback.
private final class B43RefusingTap: ApplicationAudioBottom {
    let refused = XCTestExpectation(description:"zero-handle tap creation actually returned")
    @MainActor func bindIdentity(_ b: SelectedApplicationBinding,owned: ApplicationAudioResources,gate: ApplicationAudioGate,queues: ApplicationAudioQueues) throws {}
    @MainActor func revalidateIdentity(_ b: SelectedApplicationBinding,owned: ApplicationAudioResources) throws { XCTFail("Refusal must precede readback") }
    @MainActor func removeObserver(_ owned: ApplicationAudioResources) {}
    func resolve(_ b: SelectedApplicationBinding) throws -> ResolvedApplicationAudio { .init(binding:b,process:101,routes:[.init(id:201,uid:"fake-output")]) }
    func createTap(_ plan: ResolvedApplicationAudio,owned: ApplicationAudioResources) throws {
        defer { refused.fulfill() }
        try owned.recordTapCreation(status:-1,id:kAudioObjectUnknown)
    }
    func createAggregate(_ plan: ResolvedApplicationAudio,owned: ApplicationAudioResources) throws { XCTFail("No aggregate after refusal") }
    func installListeners(_ plan: ResolvedApplicationAudio,owned: ApplicationAudioResources,gate: ApplicationAudioGate,queues: ApplicationAudioQueues) throws { XCTFail("No listeners after refusal") }
    func revalidateInput(_ owned: ApplicationAudioResources) throws { XCTFail("No input after refusal") }
    func installIOProc(_ owned: ApplicationAudioResources,gate: ApplicationAudioGate,queues: ApplicationAudioQueues) throws { XCTFail("No IO after refusal") }
    func start(_ owned: ApplicationAudioResources) throws { XCTFail("No start after refusal") }
    func stop(_ owned: ApplicationAudioResources) throws { XCTFail("No IO to stop") }
    func removeIOProc(_ owned: ApplicationAudioResources) throws { XCTFail("No IO to remove") }
    func removeListeners(_ owned: ApplicationAudioResources) -> Bool { true }
    func destroyAggregate(_ owned: ApplicationAudioResources) throws { XCTFail("No aggregate owned") }
    func destroyTap(_ owned: ApplicationAudioResources) throws { XCTFail("No tap owned") }
}

final class B43MeetingReleaseBlockerTests: XCTestCase {
    @MainActor func testZeroHandleTapRefusalCompletesStopAndTermination() async throws {
        // A handle returned alongside an error still requires an uncertainty hold.
        let possible = ApplicationAudioResources()
        XCTAssertThrowsError(try possible.recordTapCreation(status:-1,id:301))
        XCTAssertTrue(possible.uncertain); XCTAssertNotNil(possible.tap)
        let bottom = B43RefusingTap()
        let core = MeetingApplicationAudioCapture(makeBottom:{bottom},makeConverter:{ _ in XCTFail("No converter after tap refusal"); return nil })
        let r = try MeetingHubRig(applicationCapability:.production,application:{ attempt in
            .injected(MeetingSelectedApplicationCapture(binding:attempt.binding,core:.live(core),enabled:true).port)
        })
        defer { r.release() }
        r.controller.openPage(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        _ = r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot()))
        r.controller.startConsentedRecording()
        guard await hubEntered([bottom.refused]) else { return }
        r.controller.stopAndSave()
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertFalse(core.hasActualTask); XCTAssertFalse(r.controller.model.stoppingAvailable)
        XCTAssertTrue(r.admission.isAvailable); XCTAssertFalse(r.engine.isRunning)
        XCTAssertTrue(r.controller.model.status.contains("Couldn't capture that app's audio"))
        let terminated = expectation(description:"termination participant replied after actual drain")
        var permitted = false
        r.controller.beginShutdown { permitted = $0; terminated.fulfill() }
        guard await hubEntered([terminated]) else { return }
        XCTAssertTrue(permitted); XCTAssertTrue(r.controller.restartReady())
    }
    @MainActor func testInvalidManifestOffersExplicitDeleteAllMeetingDataRecovery() async throws {
        let saved = try MeetingHubRig(); defer { saved.release() }
        saved.controller.openPage(); guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.startConsentedRecording(); guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.stopAndSave(); guard await hubComplete({ await saved.controller.drainActions() }) else { return }
        saved.controller.reserveShutdown(); let ready = await saved.controller.drainRestart(); XCTAssertTrue(ready)
        let root = try XCTUnwrap(saved.bottom.rootNode), manifest = try XCTUnwrap(root.children["manifest.json"])
        manifest.body = .metadata(Data("invalid".utf8)); manifest.s.st_size = 7
        let reopened = try MeetingHubRig(bottom:saved.bottom); defer { reopened.release() }
        reopened.controller.openPage(); guard await hubComplete({ await reopened.controller.drainActions() }) else { return }
        XCTAssertEqual(reopened.controller.model.state,.unavailable)
        XCTAssertTrue(reopened.controller.model.recoveryDeleteAvailable)
        let intent = try XCTUnwrap(reopened.controller.recoveryDeleteConfirmation)
        reopened.controller.deleteAllMeetingDataConfirmed(intent:UUID()) // stale confirmation has no authority
        XCTAssertFalse(root.children.isEmpty)
        reopened.controller.deleteAllMeetingDataConfirmed(intent:intent)
        guard await hubComplete({ await reopened.controller.drainActions() }) else { return }
        XCTAssertTrue(root.children.isEmpty); XCTAssertEqual(reopened.controller.model.state,.idle)
        XCTAssertFalse(reopened.controller.model.recoveryDeleteAvailable)
        XCTAssertTrue(reopened.controller.model.canStart)
    }
}
