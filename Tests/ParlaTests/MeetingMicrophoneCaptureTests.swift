import AVFoundation
import Foundation
import XCTest
@testable import ParlaCore
@testable import Parla

final class AdapterCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
final class AdapterGate: @unchecked Sendable {
    private let lock = NSLock(), signal = DispatchSemaphore(value:0)
    private var armed = true, opened = false, expired = false
    let entered: XCTestExpectation
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func hold() {
        let wait = lock.withLock { () -> Bool in guard armed,!opened else { return false }; armed = false; return true }
        guard wait else { return }; entered.fulfill()
        if signal.wait(timeout:.now()+5) == .timedOut { lock.withLock { expired = true } }
    }
    func open() {
        let wake = lock.withLock { () -> Bool in if opened { return false }; opened = true; return true }
        if wake { signal.signal() }
    }
    var timedOut: Bool { lock.withLock { expired } }
}
final class AdapterEngine: MicrophoneCaptureEngine, @unchecked Sendable {
    private let lock = NSLock(); private var callback: ((AVAudioPCMBuffer) -> Void)?, running = false
    private var requested: String?, routeChanged: (() -> Void)?
    var requestedUID: String? { lock.withLock { requested } }
    func changeRoute() { let action = lock.withLock { routeChanged }; action?() }
    var startSamples: [Float] = []
    let starts = AdapterCounter(), stops = AdapterCounter(), queries = AdapterCounter()
    let started = XCTestExpectation(description:"adapter fake engine started")
    var isRunning: Bool { queries.hit(); return lock.withLock { running } }
    var route: MicrophoneRoute { queries.hit(); return .init() }
    func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws {
        starts.hit(); lock.withLock { running = true; callback = receive; requested = requestedUID; routeChanged = changed }
        if !startSamples.isEmpty {receive(Self.pcm(startSamples))}
        started.fulfill()
    }
    func stop() { stops.hit(); lock.withLock { running = false; callback = nil } }
    var copied: ((AVAudioPCMBuffer) -> Void)? { lock.withLock { callback } }
    static func pcm(_ values: [Float]) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16_000,channels:1,interleaved:false)!
        let b = AVAudioPCMBuffer(pcmFormat:f,frameCapacity:AVAudioFrameCount(max(1,values.count)))!
        b.frameLength = AVAudioFrameCount(values.count)
        for (i,value) in values.enumerated() { b.floatChannelData![0][i] = value }; return b
    }
    func emit(_ values: [Float]) { copied?(Self.pcm(values)) }
}
final class AdapterConverter: MeetingPCMConverting, @unchecked Sendable {
    let feeds = AdapterCounter(), drains = AdapterCounter()
    var drainGate: AdapterGate?
    var finishLatch: HubOwnedLatch?, finishEntered: XCTestExpectation?
    var feedLatch: HubOwnedLatch?, feedEntered: XCTestExpectation?
    func feed(_ input: AVAudioPCMBuffer, output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        feeds.hit(); if let feedLatch { feedEntered?.fulfill(); feedLatch.hold() }
        let n = Int(input.frameLength)
        guard n <= output.count else { return .init(frames:0,status:.failed) }
        for i in 0..<n { output[i] = input.floatChannelData![0][i] }
        return .init(frames:n,status:.inputExhausted)
    }
    func finish(output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        drains.hit(); drainGate?.hold()
        if let finishLatch {finishEntered?.fulfill();finishLatch.hold()}
        return .init(frames:0,status:.endOfStream)
    }
}
private final class AdapterLeaseBox: @unchecked Sendable {
    private let lock = NSLock(); private var lease: CaptureAdmission.Lease?
    func acquireOnce(_ admission: CaptureAdmission) { lock.withLock { if lease == nil { lease = admission.acquire(.guidedTemplate) } } }
    var value: CaptureAdmission.Lease? { lock.withLock { lease } }
}
@MainActor private final class AdapterRig {
    let bottom = LifecycleMeetingBottom(), admission = CaptureAdmission(), engine = AdapterEngine(), converter = AdapterConverter()
    let factories = AdapterCounter(), recognition = AdapterCounter()
    let stopRequested = XCTestExpectation(description:"owner requested acquisition stop")
    let session = UUID(), source = UUID(), segment = UUID(), epoch = UUID(), ownerID = UUID()
    let recorder: AudioRecorder, adapter: MeetingMicrophoneCapture, store: MeetingSessionStore, owner: MeetingSessionOwner
    init(enabled: Bool = true, failingStoreClock: Bool = false) {
        bottom.retainSourceBytes = true
        let converter = converter, factories = factories, recognition = recognition
        recorder = .init(engine:engine,admission:admission,meetingConverter:{ _ in factories.hit(); return converter })
        adapter = .init(recorder:recorder,enabled:enabled)
        store = .init(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{
            if failingStoreClock { throw MeetingSession.Failure.clock }; return 1_000_000_000_000
        })
        let port = adapter.port, stopRequested = stopRequested
        owner = .init(store:store,microphone:.init(validate:port.validate,start:port.start,requestStop:{ stopRequested.fulfill(); await port.requestStop() }),recognition:.init(run:{ _,_ in
            recognition.hit(); return Task { .failure(MeetingSession.Failure.unavailable) }
        },requestCancel:{}),wallClock:{1_000_000_000_000},holdEpoch:1)
    }
    var selection: MeetingSession.Selection { .init(instance:source,kind:.microphone,label:"",generation:7) }
    var timing: MeetingSession.Timing { .init(pts:0,denominator:1,sample:0,rate:16_000,epoch:epoch,mapping:.unknown) }
    func start() async throws {
        try await owner.startMicrophone(owner:ownerID,session:session,selection:selection,
            segment:.init(id:segment,track:0,generation:7,timing:timing,canonicalStart:0))
    }
    var saved: [Data] {
        (bottom.rootNode?.children.values.filter { $0.name.hasSuffix(".wav") } ?? []).map { $0.bytes(0,$0.length) }
    }
    func detach() async throws {
        owner.reserveQuit(); XCTAssertTrue(owner.shutdownReady); try await owner.committedDetach()
        XCTAssertTrue(bottom.descriptors.isEmpty)
    }
}

@MainActor private final class AdapterOperation {
    let done = XCTestExpectation(description:"owned adapter operation returned")
    private(set) var result: Result<Void,Error>?
    init(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [self] in
            do { try await work(); result = .success(()) }
            catch { result = .failure(error) }
            done.fulfill()
        }
    }
}

final class MeetingMicrophoneCaptureTests: XCTestCase {
    @MainActor private func completed(_ operation: AdapterOperation) async -> Result<Void,Error>? {
        await fulfillment(of:[operation.done],timeout:4)
        guard let result = operation.result else { XCTFail("Owner operation held; not joining an unobserved exit"); return nil }
        return result
    }
    @MainActor private func succeeded(_ work: @escaping @MainActor () async throws -> Void) async throws -> Bool {
        guard let result = await completed(AdapterOperation(work)) else { return false }
        try result.get(); return true
    }

    @MainActor func testNativeOffConstructionAndPureValidationQueryNothingAndReserveNothing() async throws {
        let r = AdapterRig(enabled:false); defer { r.adapter.requestStop() }
        XCTAssertFalse(r.adapter.validate(r.selection)); XCTAssertTrue(r.admission.isAvailable)
        XCTAssertEqual(r.engine.queries.value,0); XCTAssertEqual(r.factories.value,0)
        XCTAssertEqual(r.bottom.calls,0); XCTAssertEqual(r.recognition.value,0)
        guard let result = await completed(AdapterOperation { try await r.start() }) else { return }
        do { try result.get(); XCTFail("Native-off must refuse validation") } catch { }
        XCTAssertEqual(r.bottom.calls,0); XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.engine.stops.value,0)
        let live = AdapterRig()
        XCTAssertTrue(live.adapter.validate(live.selection)); XCTAssertTrue(live.admission.isAvailable)
        XCTAssertEqual(live.engine.queries.value,0); XCTAssertEqual(live.factories.value,0)
        XCTAssertFalse(live.adapter.validate(.init(instance:UUID(),kind:.selectedApplication,label:"",generation:7)))
    }
    @MainActor func testMicrophoneWrapperRefusesApplicationBeforeInjectedSingleSourceCanStart() async throws {
        let bottom = LifecycleMeetingBottom()
        let store = MeetingSessionStore(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{1_000_000_000_000})
        var validates = 0, starts = 0, producerReturned = false
        var sourceError: Error?
        let returned = XCTestExpectation(description:"injected application producer actually returned")
        // The old spelling remains usable, but the explicit initializer does not bind a native adapter.
        let port = MeetingSessionOwner.MicrophoneStreamPort(validate:{ _ in validates += 1; return true },start:{ selection,ingress in
            starts += 1
            do { _ = try ingress.end(ingress.fence(),tail:UnsafeBufferPointer<Float>(start:nil,count:0)) }
            catch { sourceError = error; ingress.revoke() }
            return .init(source:selection.instance,exit:.actual(Task { producerReturned = true; returned.fulfill() }))
        },requestStop:{})
        let owner = MeetingSessionOwner(store:store,singleSource:port,recognition:.init(run:{ _,_ in
            XCTFail("No recognition is requested"); return Task { .failure(MeetingSession.Failure.unavailable) }
        },requestCancel:{}),wallClock:{1_000_000_000_000},holdEpoch:1)
        let selection = MeetingSession.Selection(instance:UUID(),kind:.selectedApplication,label:"",generation:7)
        let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:UUID(),mapping:.unknown)
        let segment = MeetingSession.Segment(id:UUID(),track:0,generation:7,timing:timing,canonicalStart:0)
        let ownerID = UUID(), session = UUID()
        guard let refused = await completed(AdapterOperation {
            try await owner.startMicrophone(owner:ownerID,session:session,selection:selection,segment:segment)
        }) else { return }
        XCTAssertThrowsError(try refused.get()) { XCTAssertEqual($0 as? MeetingSession.Failure,.bounds) }
        XCTAssertEqual(validates,0); XCTAssertEqual(starts,0); XCTAssertEqual(bottom.calls,0)
        XCTAssertEqual(owner.state,.idle)
        guard let started = await completed(AdapterOperation {
            try await owner.startSingleSource(owner:ownerID,session:session,selection:selection,segment:segment)
        }) else { return }; try started.get()
        await fulfillment(of:[returned],timeout:2)
        XCTAssertTrue(producerReturned); XCTAssertNil(sourceError); XCTAssertEqual(validates,1); XCTAssertEqual(starts,1)
        XCTAssertEqual(owner.metadata?.selections,[selection]); XCTAssertFalse(owner.shutdownReady)
        guard let stopped = await completed(AdapterOperation { try await owner.stop() }) else { return }; try stopped.get()
        XCTAssertTrue(store.actualHoldsDrained); XCTAssertEqual(owner.projection.state,.stopped)
        owner.reserveQuit(); XCTAssertTrue(owner.shutdownReady); try await owner.committedDetach()
        XCTAssertTrue(bottom.descriptors.isEmpty)
    }
    @MainActor func testStoreFailureBeforeStartNeverAcquiresRecorderOrQueriesNativeBottom() async throws {
        let r = AdapterRig(failingStoreClock:true); defer { r.adapter.requestStop() }
        XCTAssertTrue(r.adapter.validate(r.selection)); XCTAssertTrue(r.admission.isAvailable)
        guard let result = await completed(AdapterOperation { try await r.start() }) else { return }
        do { try result.get(); XCTFail("Injected store clock must throw") }
        catch { XCTAssertEqual(error as? MeetingSession.Failure,.clock) }
        XCTAssertTrue(r.admission.isAvailable); XCTAssertEqual(r.engine.queries.value,0)
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.engine.stops.value,0)
        XCTAssertEqual(r.factories.value,0); XCTAssertEqual(r.recognition.value,0); XCTAssertTrue(r.bottom.descriptors.isEmpty)
    }
    @MainActor func testCompetitorDuringDurableAdmissionReturnsExactSourceNotStartedAndRequiresDelete() async throws {
        let r = AdapterRig(), lease = AdapterLeaseBox(), admission = r.admission
        // Competitor acquires during the owner's real fake-store IO, after pure validation.
        r.bottom.observe = { operation,name in if operation == "write",name == "owner.json" { lease.acquireOnce(admission) } }
        defer { r.adapter.requestStop(); r.bottom.observe = nil; if let lease = lease.value { admission.release(lease) } }
        guard let result = await completed(AdapterOperation { try await r.start() }) else { return }
        do { try result.get(); XCTFail("Late recorder contention must refuse") } catch { }
        let foreign = try XCTUnwrap(lease.value)
        XCTAssertTrue(r.admission.owns(foreign)); XCTAssertNotNil(r.store.projection.session)
        XCTAssertTrue(r.store.actualHoldsDrained); XCTAssertFalse(r.owner.shutdownReady)
        XCTAssertEqual(r.engine.queries.value,0); XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.factories.value,0)
        r.bottom.observe = nil; guard try await succeeded({ try await r.owner.delete(id:UUID()) }) else { return }
        XCTAssertEqual(r.owner.state,.idle); XCTAssertTrue(r.bottom.descriptors.isEmpty)
        XCTAssertTrue(r.admission.owns(foreign)); XCTAssertEqual(r.recognition.value,0)
    }
    @MainActor func testForeignIngressOutcomeNamesRequestedSourceWithoutEngineSetup() throws {
        let r = AdapterRig(), ingress = MeetingAudioIngress(context:.init(session:UUID(),ownerGeneration:1,source:UUID(),sourceGeneration:7,segment:UUID(),epoch:UUID()))
        try ingress.reserve(id:UUID(),slot:1); try ingress.reserve(id:UUID(),slot:2); try ingress.activate()
        let outcome = r.adapter.start(r.selection,ingress:ingress)
        XCTAssertEqual(outcome.source,r.source)
        if case .actual = outcome.exit { XCTFail("Foreign source must not start") }
        XCTAssertTrue(r.admission.isAvailable); XCTAssertEqual(r.engine.queries.value,0); XCTAssertEqual(r.factories.value,0)
    }
    @MainActor func testPositiveOwnerStartStopSavesLiteralPCMWithoutRecognitionAndReleasesSharedRecorder() async throws {
        let r = AdapterRig(); defer { r.adapter.requestStop() }
        guard try await succeeded({ try await r.start() }) else { return }
        await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([-1,0.5,0,1])
        XCTAssertFalse(r.admission.isAvailable); XCTAssertTrue(r.recorder.snapshot().isEmpty)
        guard try await succeeded({ try await r.owner.stop() }) else { return }
        XCTAssertEqual(r.saved.count,1); XCTAssertEqual(r.saved.first.map { Data($0.dropFirst(44)) },Data([0,128,0,64,0,0,255,127]))
        XCTAssertEqual(r.owner.projection.state,.stopped); XCTAssertTrue(r.admission.isAvailable)
        XCTAssertTrue(r.store.actualHoldsDrained); XCTAssertEqual(r.factories.value,1); XCTAssertEqual(r.recognition.value,0)
        guard try await succeeded({ try await r.detach() }) else { return }
    }
    @MainActor func testQuitCancellationDuringHeldActualDrainCannotReviveOldRunOrPublishLatePCM() async throws {
        let r = AdapterRig(), entered = expectation(description:"EOS held after quit fence"), held = AdapterGate(entered)
        r.converter.drainGate = held; defer { held.open(); r.adapter.requestStop() }
        guard try await succeeded({ try await r.start() }) else { return }; await fulfillment(of:[r.engine.started],timeout:2)
        r.engine.emit([0.5]); let copied = try XCTUnwrap(r.engine.copied)
        r.owner.reserveQuit(); r.owner.cancelQuit()
        await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(r.owner.shutdownReady); XCTAssertFalse(r.admission.isAvailable)
        copied(AdapterEngine.pcm([1])); XCTAssertEqual(r.converter.feeds.value,1)
        held.open(); guard try await succeeded({ try await r.owner.stop() }) else { return }
        XCTAssertFalse(held.timedOut); XCTAssertTrue(r.admission.isAvailable); XCTAssertTrue(r.store.actualHoldsDrained)
        XCTAssertEqual(r.saved.first.map { Data($0.dropFirst(44)) },Data([0,64]))
        XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.recognition.value,0); guard try await succeeded({ try await r.detach() }) else { return }
    }
    @MainActor func testDeleteHeldWriterRevokesPublicationWhileSourceAndWriterOwnActualExits() async throws {
        let r = AdapterRig(), entered = expectation(description:"owned source writer held"), held = AdapterGate(entered)
        defer { held.open(); r.adapter.requestStop(); r.bottom.observe = nil }
        guard try await succeeded({ try await r.start() }) else { return }; await fulfillment(of:[r.engine.started],timeout:2)
        r.bottom.observe = { operation,name in if operation == "write",name?.hasSuffix(".source.pending") == true { held.hold() } }
        for offset in stride(from:0,to:480_000,by:8_192) { r.engine.emit(Array(repeating:0,count:min(8_192,480_000-offset))) }
        await fulfillment(of:[entered],timeout:2)
        let copied = try XCTUnwrap(r.engine.copied), feeds = r.converter.feeds.value
        let deleting = AdapterOperation { try await r.owner.delete(id:UUID()) }
        await fulfillment(of:[r.stopRequested],timeout:2)
        XCTAssertEqual(r.owner.state,.deleting); XCTAssertFalse(r.owner.shutdownReady)
        copied(AdapterEngine.pcm([1])); XCTAssertEqual(r.converter.feeds.value,feeds)
        held.open()
        guard let result = await completed(deleting) else { return }
        do { try result.get(); XCTFail("Revoked in-flight write cannot prove successful Delete") }
        catch { XCTAssertEqual(r.owner.state,.unavailable); XCTAssertFalse(r.owner.shutdownReady) }
        XCTAssertFalse(held.timedOut); XCTAssertEqual(r.recognition.value,0)
        XCTAssertTrue(r.admission.isAvailable); XCTAssertEqual(r.engine.starts.value,1)
    }
}


extension MeetingMicrophoneCaptureTests {
    @MainActor func testFrozenInputOverloadIsPureDefaultOffAndStrictFakeReadbackRefuses() async throws {
        let engine = AdapterEngine(),admission = CaptureAdmission(),converter = AdapterConverter(),checks = AdapterCounter()
        let recorder = AudioRecorder(engine:engine,admission:admission,meetingConverter:{_ in converter},meetingBindingCheck:{ _ in checks.hit(); throw MeetingSession.Failure.unavailable })
        let input = try AudioRecorder.MeetingInput(uid:"frozen",label:"Literal microphone")
        let disabled = MeetingMicrophoneCapture(recorder:recorder,input:input)
        let selection = MeetingSession.Selection(instance:UUID(),kind:.microphone,label:"Literal microphone",generation:1)
        XCTAssertFalse(disabled.validate(selection)); XCTAssertEqual(engine.queries.value,0); XCTAssertEqual(checks.value,0); XCTAssertTrue(admission.isAvailable)
        let bottom = LifecycleMeetingBottom(),adapter = MeetingMicrophoneCapture(recorder:recorder,input:input,enabled:true)
        defer { adapter.requestStop() }
        let owner = MeetingSessionOwner(store:.init(root:bottom.rootURL,profile:.init(),bottom:bottom,wallClock:{1_000_000_000_000}),microphone:adapter.port,
            recognition:.init(run:{_,_ in Task{.failure(CancellationError())}},requestCancel:{}),wallClock:{1_000_000_000_000},holdEpoch:1)
        let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16000,epoch:UUID(),mapping:.unknown)
        guard await hubComplete({do {try await owner.startMicrophone(owner:UUID(),session:UUID(),selection:selection,segment:.init(id:UUID(),track:0,generation:1,timing:timing,canonicalStart:0))} catch {}}) else {return}
        guard await hubEntered([engine.started]) else {return}
        guard await hubComplete({owner.requestStopSaving();do {try await owner.finishStopSaving()} catch {}}) else {return}
        XCTAssertEqual(engine.requestedUID,"frozen"); XCTAssertEqual(checks.value,1); XCTAssertTrue(admission.isAvailable)
        XCTAssertEqual(engine.starts.value,1); XCTAssertGreaterThan(engine.stops.value,0)
    }
}


extension MeetingMicrophoneCaptureTests {
    @MainActor func testControllerStopLeaveAndWindowCloseKeepActualEOSAndRestartDrainPending() async throws {
        enum Trigger: CaseIterable {case stop,leave,window}
        for trigger in Trigger.allCases {
            let r = try MeetingHubRig(),gate = HubOwnedLatch();defer {gate.open();r.release()}
            r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
            r.controller.startAndSave();guard await hubComplete({await r.controller.drainActions()}) else {return}
            guard await hubEntered([r.engine.started]) else {return}
            r.engine.emit(Array(repeating:Float(0.5),count:8000))
            let entered = XCTestExpectation(description:"actual fake converter EOS held for \(trigger)")
            r.converter.finishLatch = gate;r.converter.finishEntered = entered
            let late = try XCTUnwrap(r.engine.copied),feeds = r.converter.feeds.value
            switch trigger {case .stop:r.controller.stopAndSave();case .leave:r.controller.leavePage();case .window:r.controller.windowClosed()}
            guard await hubEntered([entered]) else {return}
            XCTAssertFalse(r.admission.isAvailable);XCTAssertNotEqual(r.controller.model.state,.stopped)
            XCTAssertTrue(r.controller.reserveRestart());let drain = HubRestartDrain(r.controller)
            guard await hubEntered([drain.entered]) else {return}
            XCTAssertFalse(drain.returned);XCTAssertFalse(r.controller.restartReady())
            late(AdapterEngine.pcm([1]));XCTAssertEqual(r.converter.feeds.value,feeds)
            r.controller.releaseRestart();gate.open()
            guard await hubEntered([drain.exited]) else {return}
            XCTAssertEqual(drain.allowed,false);XCTAssertTrue(r.admission.isAvailable);XCTAssertFalse(gate.timedOut)
            XCTAssertEqual(r.controller.model.metadata?.chunks.count,1);XCTAssertEqual(r.engine.starts.value,1);XCTAssertEqual(r.enqueues,0)
        }
    }
    @MainActor func testControllerHeldActualCallbackBodyCannotBeRetiredByWindowClose() async throws {
        let r = try MeetingHubRig(),gate = HubOwnedLatch();defer {gate.open();r.release()}
        r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {return}
        r.controller.startAndSave();guard await hubComplete({await r.controller.drainActions()}) else {return}
        guard await hubEntered([r.engine.started]) else {return}
        let entered = XCTestExpectation(description:"actual callback converter feed entered")
        let returned = XCTestExpectation(description:"actual callback body returned")
        r.converter.feedLatch = gate;r.converter.feedEntered = entered
        let callback = try XCTUnwrap(r.engine.copied)
        DispatchQueue.global().async {callback(AdapterEngine.pcm(Array(repeating:0.5,count:8000)));returned.fulfill()}
        guard await hubEntered([entered]) else {return}
        r.controller.windowClosed();XCTAssertTrue(r.controller.reserveRestart());let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered]) else {return}
        XCTAssertFalse(drain.returned);XCTAssertFalse(r.controller.restartReady());XCTAssertFalse(r.admission.isAvailable)
        gate.open();guard await hubEntered([returned,drain.exited]) else {return}
        XCTAssertEqual(drain.allowed,true);XCTAssertTrue(r.admission.isAvailable);XCTAssertFalse(gate.timedOut)
        XCTAssertEqual(r.engine.starts.value,1);XCTAssertEqual(r.enqueues,0)
    }
}

extension MeetingMicrophoneCaptureTests {
    @MainActor func testApplicationAndMicrophoneAuthoritiesNeverCross() async throws {
        var applicationFactories = 0
        let r = try MeetingHubRig(applicationCapability:.injectedContractOnly,application:{_ in
            applicationFactories += 1;XCTFail("microphone invoked application factory");return .unavailable
        })
        r.controller.openPage();guard await hubComplete({await r.controller.drainActions()}) else {HubApplicationFailureResources.retainMicrophone(r);return}
        XCTAssertNil(r.controller.prepareApplicationStart())
        r.controller.confirmApplicationStart(challengeID:UUID(),affirmed:true);XCTAssertEqual(r.microphoneFactories,0)
        r.controller.startAndSave();guard await hubComplete({await r.controller.drainActions()}),await hubEntered([r.engine.started]) else {HubApplicationFailureResources.retainMicrophone(r);return}
        let uid = r.engine.requestedUID
        var saved = r.settings.current;saved.inputDeviceUID = "later";r.settings.current = saved;r.changedSettings()
        r.controller.focusChanged();XCTAssertEqual(r.engine.requestedUID,uid);XCTAssertEqual(applicationFactories,0)
        r.controller.stopAndSave();guard await hubComplete({await r.controller.drainActions()}) else {HubApplicationFailureResources.retainMicrophone(r);return}
        XCTAssertEqual(r.controller.applicationState,.unavailable);XCTAssertEqual(r.engine.starts.value,1);XCTAssertEqual(applicationFactories,0)
        r.controller.reserveShutdown();let drain = HubRestartDrain(r.controller)
        guard await hubEntered([drain.entered,drain.exited]),drain.returned else {HubApplicationFailureResources.retainMicrophone(r);return}
        await drain.task.value;XCTAssertEqual(drain.allowed,true)
    }
    @MainActor func testApplicationChoiceCannotUseMicrophoneStartOrPermissionEvidence() async throws {
        let r = try HubApplicationRig();defer {r.release()};guard await r.open(self) else {return}
        XCTAssertTrue(r.controller.acceptSourceChoice(.selectedApplication(hubApplicationSnapshot())))
        r.controller.startAndSave();r.controller.focusChanged();r.controller.whisperPreparationChanged(UUID())
        XCTAssertEqual(r.factories,0);XCTAssertEqual(r.settingsReads,0)
        let challenge = try XCTUnwrap(r.controller.prepareApplicationStart())
        r.controller.confirmApplicationStart(challengeID:challenge.id,affirmed:false)
        r.controller.startAndSave();XCTAssertEqual(r.factories,0)
        guard await r.detach(self) else {return}
    }
}
