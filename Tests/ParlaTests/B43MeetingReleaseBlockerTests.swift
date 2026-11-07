import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

/// Aggregate/IO refusals execute the native bottom with raw HAL results injected.
@available(macOS 14.2, *)
private final class B43RefusingCreation: ApplicationAudioBottom {
    enum Step { case tap, aggregate, io }
    let step: Step
    let refused = XCTestExpectation(description:"no-handle creation actually returned")
    private(set) var destroyed: [String] = []
    private let native = NativeApplicationAudioBottom(creation:.init(
        aggregate:{ _ in (status:-1,id:kAudioObjectUnknown) },
        ioProc:{ _,_,_ in (status:-1,raw:nil) }))
    init(_ step: Step) { self.step = step }
    @MainActor func bindIdentity(_ b: SelectedApplicationBinding,owned: ApplicationAudioResources,gate: ApplicationAudioGate,queues: ApplicationAudioQueues) throws {}
    @MainActor func revalidateIdentity(_ b: SelectedApplicationBinding,owned: ApplicationAudioResources) throws {}
    @MainActor func removeObserver(_ owned: ApplicationAudioResources) {}
    func resolve(_ b: SelectedApplicationBinding) throws -> ResolvedApplicationAudio { .init(binding:b,process:101,routes:[.init(id:201,uid:"fake-output")]) }
    func createTap(_ plan: ResolvedApplicationAudio,owned: ApplicationAudioResources) throws {
        if step == .tap {
            defer { refused.fulfill() }
            try owned.recordTapCreation(status:-1,id:kAudioObjectUnknown)
        } else {
            try owned.recordTapCreation(status:noErr,id:301); owned.tapUID = "review-tap"
            owned.format = try .init(rate:16_000,channels:1,interleaved:false)
        }
    }
    func createAggregate(_ plan: ResolvedApplicationAudio,owned: ApplicationAudioResources) throws {
        if step == .aggregate {
            defer { refused.fulfill() }
            try native.createAggregate(plan,owned:owned)
        } else { try owned.ownAggregate(401) }
    }
    func installListeners(_ plan: ResolvedApplicationAudio,owned: ApplicationAudioResources,gate: ApplicationAudioGate,queues: ApplicationAudioQueues) throws {
        for id in UInt32(601)...604 {
            try owned.ownListener(object:id,address:.init(mSelector:kAudioObjectPropertySelectorWildcard,mScope:kAudioObjectPropertyScopeGlobal,mElement:0),queue:queues.listener,block:{ _,_ in })
        }
    }
    func revalidateInput(_ owned: ApplicationAudioResources) throws {}
    func installIOProc(_ owned: ApplicationAudioResources,gate: ApplicationAudioGate,queues: ApplicationAudioQueues) throws {
        defer { refused.fulfill() }
        try native.installIOProc(owned,gate:gate,queues:queues)
    }
    func start(_ owned: ApplicationAudioResources) throws { XCTFail("No start after refusal") }
    func stop(_ owned: ApplicationAudioResources) throws { XCTFail("No IO to stop") }
    func removeIOProc(_ owned: ApplicationAudioResources) throws { XCTFail("No IO to remove") }
    func removeListeners(_ owned: ApplicationAudioResources) -> Bool {
        if !owned.listeners.isEmpty { destroyed.append("listeners") }; owned.listeners.removeAll(); return true
    }
    func destroyAggregate(_ owned: ApplicationAudioResources) throws {
        XCTAssertNil(owned.io); XCTAssertTrue(owned.listeners.isEmpty)
        destroyed.append("aggregate"); owned.aggregate = nil
    }
    func destroyTap(_ owned: ApplicationAudioResources) throws {
        XCTAssertNil(owned.aggregate); destroyed.append("tap"); owned.tap = nil
    }
}

final class B43MeetingReleaseBlockerTests: XCTestCase {
    @available(macOS 14.2, *)
    @MainActor func testZeroHandleTapRefusalCompletesStopAndTermination() async throws {
        // A handle returned alongside an error still requires an uncertainty hold.
        let possible = ApplicationAudioResources()
        XCTAssertThrowsError(try possible.recordTapCreation(status:-1,id:301))
        XCTAssertTrue(possible.uncertain); XCTAssertNotNil(possible.tap)
        try await noHandleRefusal(.tap,expected:[])
    }
    @available(macOS 14.2, *)
    @MainActor func testZeroHandleAggregateRefusalCompletesStopAndTermination() async throws {
        // Adapted from the independent native probe: the known tap must remain destroyable.
        let possible = ApplicationAudioResources()
        try possible.ownTap(301)
        XCTAssertThrowsError(try possible.recordAggregateCreation(status:-1,id:401))
        XCTAssertTrue(possible.uncertain); XCTAssertNotNil(possible.aggregate)
        let refused = ApplicationAudioResources()
        try refused.ownTap(301)
        XCTAssertThrowsError(try refused.recordAggregateCreation(status:-1,id:0))
        XCTAssertNil(refused.aggregate); XCTAssertFalse(refused.uncertain); XCTAssertNotNil(refused.tap)
        try await noHandleRefusal(.aggregate,expected:["tap"])
    }
    @available(macOS 14.2, *)
    @MainActor func testNilHandleIOProcRefusalCompletesStopAndTermination() async throws {
        let possible = ApplicationAudioResources()
        let raw: AudioDeviceIOProcID = { _,_,_,_,_,_,_ in noErr }
        XCTAssertThrowsError(try possible.recordIOProcCreation(status:-1,raw:raw))
        XCTAssertTrue(possible.uncertain); XCTAssertNotNil(possible.io)
        let refused = ApplicationAudioResources()
        XCTAssertThrowsError(try refused.recordIOProcCreation(status:-1,raw:nil))
        XCTAssertNil(refused.io); XCTAssertFalse(refused.uncertain)
        try await noHandleRefusal(.io,expected:["listeners","aggregate","tap"])
    }
    @available(macOS 14.2, *)
    @MainActor private func noHandleRefusal(_ step: B43RefusingCreation.Step, expected: [String]) async throws {
        let bottom = B43RefusingCreation(step)
        let core = MeetingApplicationAudioCapture(makeBottom:{bottom},makeConverter:{ _ in XCTFail("No PCM after creation refusal"); return nil })
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
        XCTAssertEqual(bottom.destroyed,expected)
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
