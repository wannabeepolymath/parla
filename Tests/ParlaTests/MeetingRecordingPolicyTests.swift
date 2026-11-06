import Combine
import Foundation
import XCTest
@testable import Parla
@testable import ParlaCore

final class MeetingRecordingPolicyFlowTests: XCTestCase {
    @MainActor func testConsentIsSingleUseAndRequiredBeforeAnyPermissionOrCapture() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        r.controller.startAndSave()
        let first = try XCTUnwrap(r.controller.recordingChallenge)
        XCTAssertEqual(r.permissions,0); XCTAssertEqual(r.microphoneFactories,0); XCTAssertEqual(r.engine.starts.value,0)
        r.controller.confirmRecordingStart(id:first.id,affirmed:false)
        r.controller.confirmRecordingStart(id:first.id,affirmed:true)
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertEqual(r.permissions,0); XCTAssertEqual(r.engine.starts.value,0)
        r.controller.startAndSave(); let next = try XCTUnwrap(r.controller.recordingChallenge)
        XCTAssertNotEqual(first.id,next.id)
        r.controller.confirmRecordingStart(id:next.id,affirmed:true)
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertEqual(r.engine.starts.value,1); XCTAssertTrue(r.controller.model.stoppingAvailable)
        r.controller.stopAndSave(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertFalse(r.controller.model.stoppingAvailable)
    }
    @MainActor func testSourceChangeAndPageExitRevokeConsent() async throws {
        var factories = 0
        let r = try MeetingHubRig(applicationCapability:.production,application:{ _ in factories += 1; return .unavailable }); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        r.controller.startAndSave(); let first = try XCTUnwrap(r.controller.recordingChallenge)
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
        r.controller.confirmRecordingStart(id:first.id,affirmed:true)
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertEqual(r.permissions,0); XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(factories,0)
        _ = r.controller.acceptSourceChoice(.microphone)
        r.controller.startAndSave(); let next = try XCTUnwrap(r.controller.recordingChallenge)
        r.controller.leavePage(); r.controller.confirmRecordingStart(id:next.id,affirmed:true)
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.permissions,0)
    }
    @MainActor func testDeniedAndLateMicrophonePermissionNeverStartOrResumeCapture() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        r.permission = .denied; r.controller.startConsentedRecording()
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertEqual(r.microphoneFactories,0); XCTAssertTrue(r.controller.model.message?.contains("System Settings") == true)
        r.permission = .undetermined; r.controller.startConsentedRecording()
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        let reply = try XCTUnwrap(r.pendingPermission)
        r.permission = .authorized; reply(true); r.pendingPermission = nil
        // Wait for the registered permission continuation via lifecycle, rather than yielding blindly.
        r.controller.reserveShutdown(); let ready = await r.controller.drainRestart(); XCTAssertTrue(ready)
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.resolutions,0)
        r.controller.releaseRestart()
    }
    @MainActor func testProductionDualSourcesDrainBothAndTranscribeOnlyOnRequest() async throws {
        var backend: HubApplicationBackend?
        let r = try MeetingHubRig(applicationCapability:.production,application:{ attempt in
            let value = HubApplicationBackend(attempt.binding); backend = value
            return .injected(MeetingSelectedApplicationCapture(binding:attempt.binding,core:value.port,enabled:true).port)
        })
        defer { backend?.release(); r.release() }
        r.controller.openPage(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
        r.controller.startConsentedRecording(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        let app = try XCTUnwrap(backend)
        guard await hubEntered([app.entered,r.engine.started]) else { return }
        XCTAssertEqual(r.controller.model.state,.recording)
        XCTAssertEqual(r.controller.model.metadata?.selections.map(\.kind),[.microphone,.selectedApplication])
        r.engine.emit([Float](repeating:0.5,count:8000))
        r.controller.reserveShutdown()
        let drained = HubApplicationOperation { await r.controller.drainRestart() }
        guard await hubEntered([app.stopRequested]) else { return }
        // The actual app body remains held independently of the microphone exit.
        XCTAssertNil(drained.result); XCTAssertFalse(r.controller.restartReady())
        app.bodyExit.open(); guard await hubEntered([app.cleanupEntered]) else { return }
        XCTAssertNil(drained.result); app.cleanup.open()
        guard await hubEntered([app.completed,drained.completed]) else { return }
        XCTAssertEqual(drained.result,true); XCTAssertFalse(r.controller.model.stoppingAvailable)
        r.controller.releaseRestart(); r.controller.openPage()
        guard await hubComplete({ await r.controller.drainActions() }) else { return }
        var historyBytes = Data("[]".utf8)
        let history = HistoryStore(url:URL(fileURLWithPath:"/virtual/b43-history.json"),persistence:.init(
            read:{ _ in historyBytes },writeAtomically:{ data,_ in historyBytes = data }))
        var historyEvents = 0
        let observer = NotificationCenter.default.addObserver(forName:HistoryStore.didChange,object:nil,queue:.main) { _ in historyEvents += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(history.append(.init(raw:"Ordinary dictation positive control")))
        XCTAssertGreaterThan(historyEvents,0)
        let originalHistory = history.entries, originalBytes = historyBytes
        historyEvents = 0
        r.controller.transcribeRemaining(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertEqual(historyEvents,0); XCTAssertEqual(history.entries,originalHistory); XCTAssertEqual(historyBytes,originalBytes)
        XCTAssertEqual(r.enqueues,1); XCTAssertEqual(r.recognitionJobs.count,1)
        XCTAssertEqual(r.controller.model.metadata?.chunks.filter { $0.accepted != nil }.count,1)
        // The shared settings rig fails immediately on scratchpad/settings writes; no provider is configured.
        XCTAssertTrue(r.copies.isEmpty); XCTAssertEqual(r.literalText,"Literal raw text\nkept verbatim.")
    }
    @MainActor func testStopReschedulesTheEarlierRawAudioDeadline() async throws {
        let r = try MeetingHubRig(); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        r.controller.startConsentedRecording(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        guard await hubEntered([r.engine.started]) else { return }
        r.engine.emit([Float](repeating:0.5,count:8000))
        let boundary = r.clock + 604_800_000_000_000
        r.controllerWall = { r.clock = boundary; return boundary }
        let swept = expectation(description:"raw deadline removed saved audio while transcript slot survives")
        var observed = false
        let sub = r.controller.$model.sink { value in
            if !observed,!value.busy,value.metadata?.chunks.first?.audioRemoved == true {
                observed = true; swept.fulfill()
            }
        }
        defer { sub.cancel() }
        r.controller.stopAndSave()
        guard await hubEntered([swept]) else { return }
        XCTAssertNotNil(r.controller.model.metadata); XCTAssertFalse(r.controller.model.metadata?.expired ?? true)
    }
    func testProductionCompositionEnablesCaptureWithoutDictationHistorySink() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf:root.appendingPathComponent("Sources/Parla/main.swift"),encoding:.utf8)
        let start = try XCTUnwrap(main.range(of:"@MainActor private func configureMeetingHub()"))
        let end = try XCTUnwrap(main.range(of:"/// Resource-free owner",range:start.upperBound..<main.endIndex))
        let composition = main[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(composition.contains("captureCapability:true"))
        XCTAssertFalse(composition.localizedCaseInsensitiveContains("history"))
        for file in ["MeetingHubController.swift","MeetingRecognitionExecution.swift"] {
            let source = try String(contentsOf:root.appendingPathComponent("Sources/Parla/"+file),encoding:.utf8)
            XCTAssertFalse(source.contains("HistoryStore")); XCTAssertFalse(source.contains("history.append"))
        }
    }
    @MainActor func testApplicationRefusalStopsMicrophoneAndExplainsPermissions() async throws {
        let r = try MeetingHubRig(applicationCapability:.production,application:{ _ in
            .injected(.init(validate:{ _ in true },start:{ selection,_ in .init(source:selection.instance,exit:.notStarted) },requestStop:{}))
        }); defer { r.release() }
        r.controller.openPage(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        _ = r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot()))
        r.controller.startConsentedRecording(); guard await hubComplete({ await r.controller.drainActions() }) else { return }
        XCTAssertNotEqual(r.controller.model.state,.recording)
        XCTAssertTrue(r.controller.model.message?.contains("System Audio Recording") == true)
        XCTAssertEqual(r.microphoneFactories,1); XCTAssertTrue(r.admission.isAvailable); XCTAssertFalse(r.engine.isRunning)
    }
}
