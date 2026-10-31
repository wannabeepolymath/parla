import AVFoundation
import Foundation
import XCTest
@testable import ParlaCore

/// One-shot finite gate. No waiting while holding any coordinator-needed lock.
private final class RecorderBodyGate: @unchecked Sendable {
    private let lock = NSLock(), released = DispatchSemaphore(value:0)
    private var armed = true, opened = false, expired = false
    let entered: XCTestExpectation
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func hold() {
        let hold = lock.withLock { () -> Bool in
            guard armed,!opened else { return false }; armed = false; return true
        }
        guard hold else { return }; entered.fulfill()
        if released.wait(timeout:.now()+5) == .timedOut { lock.withLock { expired = true } }
    }
    func open() {
        let signal = lock.withLock { () -> Bool in if opened { return false }; opened = true; return true }
        if signal { released.signal() }
    }
    var timedOut: Bool { lock.withLock { expired } }
}
private final class RecorderCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
private final class MeetingRecorderEngine: MicrophoneCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((AVAudioPCMBuffer) -> Void)?, change: (() -> Void)?, running = false
    let starts = RecorderCounter(), stops = RecorderCounter(), queries = RecorderCounter()
    let started = XCTestExpectation(description:"fake shared engine entered start")
    var startBody: (((AVAudioPCMBuffer) -> Void) throws -> Void)?
    var stopGate: RecorderBodyGate?
    var isRunning: Bool { queries.increment(); return lock.withLock { running } }
    var route: MicrophoneRoute { queries.increment(); return .init() }
    func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void, changed: @escaping () -> Void) throws {
        starts.increment(); lock.withLock { callback = receive; change = changed; running = true }
        started.fulfill(); try startBody?(receive)
    }
    func stop() {
        stopGate?.hold(); stops.increment(); lock.withLock { callback = nil; change = nil; running = false }
    }
    var copied: ((AVAudioPCMBuffer) -> Void)? { lock.withLock { callback } }
    func emit(_ values: [Float], rate: Double = 16_000, capacity: Int? = nil) {
        copied?(Self.buffer(values,rate:rate,capacity:capacity))
    }
    static func buffer(_ values: [Float], rate: Double = 16_000, capacity: Int? = nil) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:1,interleaved:false)!
        let b = AVAudioPCMBuffer(pcmFormat:f,frameCapacity:AVAudioFrameCount(max(1,capacity ?? values.count)))!
        b.frameLength = AVAudioFrameCount(values.count)
        for (i,value) in values.enumerated() { b.floatChannelData![0][i] = value }; return b
    }
}
private final class MeetingRecorderConverter: MeetingPCMConverting, @unchecked Sendable {
    let feeds = RecorderCounter(), finishes = RecorderCounter()
    var feedGate: RecorderBodyGate?, finishGate: RecorderBodyGate?
    var feedStatus = MeetingConversionStep.Status.inputExhausted
    var feedFrames: Int?, emittedValue: Float?, nonterminal = false, oversizedTail = false
    var tail: [Float] = [], emittedTail = false, tailNeedsTerminalCall = false
    func feed(_ input: AVAudioPCMBuffer, output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        feeds.increment(); feedGate?.hold()
        let n = feedFrames ?? Int(input.frameLength)
        if (0...output.count).contains(n) {
            for i in 0..<n { output[i] = emittedValue ?? input.floatChannelData![0][i % Int(input.frameLength)] }
        }
        return .init(frames:n,status:feedStatus)
    }
    func finish(output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        finishes.increment(); finishGate?.hold()
        if oversizedTail { return .init(frames:output.count+1,status:.haveData) }
        if nonterminal { return .init(frames:0,status:.haveData) }
        if !emittedTail {
            emittedTail = true
            guard tail.count <= output.count else { return .init(frames:output.count+1,status:.failed) }
            for i in tail.indices { output[i] = tail[i] }
            return .init(frames:tail.count,status:tailNeedsTerminalCall ? .haveData : .endOfStream)
        }
        return .init(frames:0,status:.endOfStream)
    }
}
@MainActor private final class MeetingRecorderRig {
    let admission = CaptureAdmission(), engine = MeetingRecorderEngine(), converter = MeetingRecorderConverter()
    let factories = RecorderCounter(), ingress: MeetingAudioIngress, recorder: AudioRecorder
    init() throws {
        ingress = .init(context:.init(session:UUID(),ownerGeneration:1,source:UUID(),sourceGeneration:7,segment:UUID(),epoch:UUID()))
        try ingress.reserve(id:UUID(),slot:1); try ingress.reserve(id:UUID(),slot:2); try ingress.activate()
        let converter = converter, factories = factories
        recorder = .init(engine:engine,admission:admission,meetingConverter:{ _ in factories.increment(); return converter })
    }
    func start(enabled: Bool = true) throws -> MeetingMicrophoneRecording {
        switch recorder.startMeeting(source:ingress.context.source,generation:7,ingress:ingress,enabled:enabled) {
        case .notStarted: XCTFail("Expected positive streaming route"); throw MeetingSession.Failure.unavailable
        case .actual(let recording): return recording
        }
    }
    func fill(_ count: Int, value: Float = 0) {
        for offset in stride(from:0,to:count,by:8_192) { engine.emit(Array(repeating:value,count:min(8_192,count-offset))) }
    }
    func takePCM() throws -> Data {
        let d = try ingress.take(XCTUnwrap(ingress.readyPermit))
        defer { try? ingress.retire(d.permit) }; return Data(d.bytes.dropFirst(44))
    }
}

@MainActor private final class RecorderCompletion {
    let done = XCTestExpectation(description:"actual recorder task returned")
    private(set) var finished = false
    init(_ task: Task<Void,Never>) {
        Task { @MainActor [self] in
            await task.value; finished = true; done.fulfill()
        }
    }
}

final class MeetingMicrophoneRecorderTests: XCTestCase {
    @MainActor private func completed(_ observation: RecorderCompletion) async -> Bool {
        await fulfillment(of:[observation.done],timeout:3)
        guard observation.finished else { XCTFail("Actual task held; not joining an unobserved exit"); return false }
        return true
    }
    @MainActor private func completed(_ recording: MeetingMicrophoneRecording) async -> Bool {
        await completed(RecorderCompletion(recording.task))
    }

    @MainActor func testNativeOffAndBusyAdmissionQueryNothingAndPreserveForeignOwner() throws {
        let r = try MeetingRecorderRig()
        if case .actual = r.recorder.startMeeting(source:r.ingress.context.source,generation:7,ingress:r.ingress) { XCTFail("Default must be native-off") }
        XCTAssertTrue(r.recorder.snapshot().isEmpty); XCTAssertEqual(r.engine.queries.value,0)
        XCTAssertEqual(r.engine.starts.value,0); XCTAssertEqual(r.factories.value,0)
        let foreign = try XCTUnwrap(r.admission.acquire(.guidedTemplate))
        if case .actual = r.recorder.startMeeting(source:r.ingress.context.source,generation:7,ingress:r.ingress,enabled:true) { XCTFail("Busy must refuse before engine access") }
        XCTAssertTrue(r.admission.owns(foreign)); XCTAssertEqual(r.engine.queries.value,0)
        XCTAssertEqual(r.engine.stops.value,0); XCTAssertEqual(r.factories.value,0); r.admission.release(foreign)
    }
    @MainActor func testLiteralSplitPCMAndTerminalTailWithNoOrdinaryAccumulationOrHooks() async throws {
        // Independent expected words, not production quantization or converter-derived expectations.
        let values: [Float] = [-1,0.5,0,1,-0.5], bytes = Data([0,128,0,64,0,0,255,127,0,192,0,64])
        for split in 1..<values.count {
            let r = try MeetingRecorderRig(); r.converter.tail = [0.5]
            var levels = 0, ends = 0
            r.recorder.onLevel = { _ in levels += 1 }; r.recorder.onEnd = { _ in ends += 1 }
            let recording = try r.start(); defer { recording.requestStop() }
            await fulfillment(of:[r.engine.started],timeout:2)
            r.engine.emit(Array(values.prefix(split))); r.engine.emit(Array(values.dropFirst(split)))
            XCTAssertEqual(r.ingress.facts.accepted,5); XCTAssertTrue(r.recorder.snapshot().isEmpty)
            XCTAssertEqual(r.recorder.retainedAudioCounts.samples,0); XCTAssertEqual(r.recorder.retainedAudioCounts.preRoll,0)
            recording.requestStop(); guard await completed(recording) else { return }
            XCTAssertEqual(try r.takePCM(),bytes); XCTAssertFalse(r.ingress.facts.unknown)
            XCTAssertEqual(r.factories.value,1); XCTAssertEqual(r.converter.feeds.value,2)
            XCTAssertEqual(r.converter.finishes.value,1); XCTAssertEqual(levels,0); XCTAssertEqual(ends,0)
            XCTAssertTrue(r.admission.isAvailable); XCTAssertEqual(r.engine.stops.value,1)
        }
    }
    @MainActor func testSynchronousPCMThenStartThrowStillReturnsActualCleanupAndLiteralPrefix() async throws {
        let r = try MeetingRecorderRig()
        r.engine.startBody = { callback in
            callback(MeetingRecorderEngine.buffer([-1,0.5]))
            throw MeetingSession.Failure.unavailable
        }
        let recording = try r.start(); defer { recording.requestStop() }; guard await completed(recording) else { return }
        XCTAssertEqual(try r.takePCM(),Data([0,128,0,64])); XCTAssertTrue(r.ingress.facts.unknown)
        XCTAssertEqual(r.engine.starts.value,1); XCTAssertEqual(r.engine.stops.value,1)
        XCTAssertEqual(r.converter.feeds.value,1); XCTAssertTrue(r.admission.isAvailable)
    }
    @MainActor func testFenceBetweenAdmittedSourceAndPublicationWaitsForBodyAndMarksUnknown() async throws {
        let r = try MeetingRecorderRig(), entered = expectation(description:"accepted converter body"), returned = expectation(description:"actual callback returned")
        let held = RecorderBodyGate(entered); r.converter.feedGate = held
        defer { held.open() }
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2)
        let callback = try XCTUnwrap(r.engine.copied)
        DispatchQueue.global().async { callback(MeetingRecorderEngine.buffer([0.5])); returned.fulfill() }
        await fulfillment(of:[entered],timeout:2)
        XCTAssertTrue(r.ingress.facts.bodyEntered); r.ingress.fence(); recording.requestStop()
        XCTAssertFalse(r.admission.isAvailable); XCTAssertFalse(r.ingress.facts.ended)
        held.open(); await fulfillment(of:[returned],timeout:2); guard await completed(recording) else { return }
        XCTAssertFalse(held.timedOut); XCTAssertTrue(r.ingress.facts.unknown)
        XCTAssertEqual(r.ingress.facts.accepted,0); XCTAssertNil(r.ingress.readyPermit)
        XCTAssertTrue(r.ingress.facts.settled); XCTAssertTrue(r.admission.isAvailable)
    }
    @MainActor func testFenceBeforeAdmissionAndCopiedLateCallbackNeverAllocateOrTouchSuccessor() async throws {
        let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); let copied = try XCTUnwrap(r.engine.copied)
        r.ingress.fence(); copied(MeetingRecorderEngine.buffer([0.5]))
        recording.requestStop(); guard await completed(recording) else { return }
        XCTAssertEqual(r.factories.value,0); XCTAssertEqual(r.converter.feeds.value,0)
        XCTAssertFalse(r.ingress.facts.unknown); XCTAssertTrue(r.admission.isAvailable)
        let successor = try XCTUnwrap(r.admission.acquire(.dictation))
        let before = r.ingress.facts
        copied(MeetingRecorderEngine.buffer([.nan],capacity:100_000))
        recording.requestStop() // stale handle cannot release successor
        XCTAssertEqual(r.ingress.facts,before); XCTAssertTrue(r.admission.owns(successor))
        XCTAssertEqual(r.factories.value,0); r.admission.release(successor)
    }
    @MainActor func testOverlappingCallbackRefusesWithoutSecondConverterOrQueue() async throws {
        let r = try MeetingRecorderRig(), entered = expectation(description:"first body held"), returned = expectation(description:"first returned")
        let held = RecorderBodyGate(entered); r.converter.feedGate = held; defer { held.open() }
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); let callback = try XCTUnwrap(r.engine.copied)
        DispatchQueue.global().async { callback(MeetingRecorderEngine.buffer([0.5])); returned.fulfill() }
        await fulfillment(of:[entered],timeout:2)
        callback(MeetingRecorderEngine.buffer([1])); XCTAssertFalse(r.ingress.facts.open)
        XCTAssertFalse(r.admission.isAvailable); held.open()
        await fulfillment(of:[returned],timeout:2); guard await completed(recording) else { return }
        XCTAssertFalse(held.timedOut); XCTAssertEqual(r.converter.feeds.value,1)
        XCTAssertEqual(r.factories.value,1); XCTAssertTrue(r.ingress.facts.unknown); XCTAssertTrue(r.admission.isAvailable)
    }
    @MainActor func testHeldNativeStopAcknowledgementAndHeldDrainCannotReleaseLease() async throws {
        let r = try MeetingRecorderRig(), stopEntered = expectation(description:"stop held"), drainEntered = expectation(description:"drain held")
        let stop = RecorderBodyGate(stopEntered), drain = RecorderBodyGate(drainEntered)
        r.engine.stopGate = stop; r.converter.finishGate = drain
        defer { stop.open(); drain.open() }
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([0.5]); let copied = try XCTUnwrap(r.engine.copied)
        recording.requestStop() // synchronous, cannot wait for the control executor
        await fulfillment(of:[stopEntered],timeout:2); XCTAssertFalse(r.admission.isAvailable)
        copied(MeetingRecorderEngine.buffer([1])); XCTAssertEqual(r.converter.feeds.value,1)
        stop.open(); await fulfillment(of:[drainEntered],timeout:2)
        XCTAssertFalse(r.admission.isAvailable); XCTAssertFalse(r.ingress.facts.ended)
        drain.open(); guard await completed(recording) else { return }
        XCTAssertEqual(try r.takePCM(),Data([0,64])); XCTAssertFalse(stop.timedOut); XCTAssertFalse(drain.timedOut)
        XCTAssertTrue(r.admission.isAvailable)
    }
    @MainActor func testNonterminalEmptyEOSAndOversizedTailRemainUnknownWithLiteralPrefix() async throws {
        for oversized in [false,true] {
            let r = try MeetingRecorderRig(); r.converter.nonterminal = !oversized; r.converter.oversizedTail = oversized
            let recording = try r.start(); defer { recording.requestStop() }
            await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([-1,0.5])
            recording.requestStop(); guard await completed(recording) else { return }
            XCTAssertEqual(try r.takePCM(),Data([0,128,0,64])); XCTAssertTrue(r.ingress.facts.unknown)
            XCTAssertEqual(r.converter.finishes.value,oversized ? 1 : 4); XCTAssertTrue(r.admission.isAvailable)
        }
    }
    @MainActor func testShapeAndNonfiniteRefusalsPrecedeConverterWhileLargeNativeCapacityCannotSetScratch() async throws {
        for values in [[Float](repeating:0,count:8_193),[Float.nan]] {
            let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
            await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit(values)
            guard await completed(recording) else { return }
            XCTAssertEqual(r.factories.value,0); XCTAssertEqual(r.converter.feeds.value,0)
            XCTAssertTrue(r.ingress.facts.unknown); XCTAssertTrue(r.ingress.facts.settled)
        }
        let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2)
        r.engine.emit([0.5],capacity:100_000); recording.requestStop(); guard await completed(recording) else { return }
        XCTAssertEqual(try r.takePCM(),Data([0,64])); XCTAssertFalse(r.ingress.facts.unknown)
        XCTAssertEqual(r.factories.value,1) // bounded frameLength, never native frameCapacity allocation
    }
    @MainActor func testFormatChangeAndConverterErrorPreserveOnlyPriorLiteralPrefix() async throws {
        for formatChange in [false,true] {
            let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
            await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([0.5])
            if formatChange { r.engine.emit([1],rate:48_000) }
            else { r.converter.feedStatus = .failed; r.engine.emit([1]) }
            guard await completed(recording) else { return }
            XCTAssertEqual(try r.takePCM(),Data([0,64])); XCTAssertTrue(r.ingress.facts.unknown)
            XCTAssertEqual(r.factories.value,1); XCTAssertEqual(r.converter.feeds.value,formatChange ? 1 : 2)
        }
    }
    @MainActor func testTwoSlotPressureKeepsExactPrefixSnapshotAndNoWholeSessionStorage() async throws {
        let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); r.fill(480_000)
        var writing: MeetingAudioIngress.Delivery? = try r.ingress.take(XCTUnwrap(r.ingress.readyPermit))
        let permit = try XCTUnwrap(writing).permit
        XCTAssertEqual(writing.map { Data($0.bytes.dropFirst(44)) },Data(repeating:0,count:960_000))
        r.fill(479_999); r.engine.emit([0.5,1]); guard await completed(recording) else { return }
        XCTAssertEqual(r.ingress.facts.accepted,960_000); XCTAssertEqual(r.ingress.facts.slots,2)
        XCTAssertEqual(r.ingress.facts.allocated,2); XCTAssertTrue(r.ingress.facts.unknown)
        XCTAssertEqual(r.ingress.facts.rawBytes,1_920_088); XCTAssertEqual(r.ingress.facts.snapshotBytes,960_044)
        XCTAssertLessThan(r.ingress.facts.rawBytes+r.ingress.facts.snapshotBytes+65_536+131_072+131_072,4_194_304)
        XCTAssertEqual(r.recorder.retainedAudioCounts.samples,0); XCTAssertEqual(r.recorder.retainedAudioCounts.preRoll,0)
        writing = nil; try r.ingress.retire(permit)
        var expected = Data(repeating:0,count:959_998); expected.append(contentsOf:[0,64])
        XCTAssertEqual(try r.takePCM(),expected); XCTAssertTrue(r.ingress.facts.settled)
    }
    @MainActor func testRevokeWithEnteredBodyKeepsActualOwnershipButDeniesPublication() async throws {
        let r = try MeetingRecorderRig(), entered = expectation(description:"Delete/expiry body held"), returned = expectation(description:"revoked body exits")
        let held = RecorderBodyGate(entered); defer { held.open() }
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([0.5]); r.converter.feedGate = held
        let callback = try XCTUnwrap(r.engine.copied)
        DispatchQueue.global().async { callback(MeetingRecorderEngine.buffer([1])); returned.fulfill() }
        await fulfillment(of:[entered],timeout:2); r.ingress.revoke(); recording.requestStop()
        XCTAssertFalse(r.admission.isAvailable); XCTAssertNil(r.ingress.readyPermit); XCTAssertFalse(r.ingress.facts.ended)
        held.open(); await fulfillment(of:[returned],timeout:2); guard await completed(recording) else { return }
        XCTAssertFalse(held.timedOut); XCTAssertTrue(r.admission.isAvailable); XCTAssertTrue(r.ingress.facts.unknown)
        XCTAssertNil(r.ingress.readyPermit); XCTAssertTrue(r.ingress.facts.settled)
    }
    @MainActor func testEmptyStopHasNoConverterStateAndNoUnknownOrNativeEOSAssumption() async throws {
        let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2)
        recording.requestStop(); guard await completed(recording) else { return }
        XCTAssertEqual(r.factories.value,0); XCTAssertEqual(r.converter.finishes.value,0)
        XCTAssertTrue(r.ingress.facts.settled); XCTAssertFalse(r.ingress.facts.unknown)
        XCTAssertTrue(r.admission.isAvailable)
    }
    @MainActor func testPositiveHaveDataTailWaitsForRealTerminalStatus() async throws {
        let r = try MeetingRecorderRig(); r.converter.tail = [-0.5]; r.converter.tailNeedsTerminalCall = true
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([0.5])
        recording.requestStop(); guard await completed(recording) else { return }
        XCTAssertEqual(r.converter.finishes.value,2); XCTAssertFalse(r.ingress.facts.unknown)
        XCTAssertEqual(try r.takePCM(),Data([0,64,0,192]))
    }
    @MainActor func testUnsupportedRateChannelsAndInterleavingRefuseBeforeFactory() async throws {
        for (rate,channels,interleaved) in [(4_000.0,AVAudioChannelCount(1),false),(16_000.0,AVAudioChannelCount(3),false),(16_000.0,AVAudioChannelCount(2),true)] {
            let context = "rate=\(rate), channels=\(channels), interleaved=\(interleaved)"
            let f: AVAudioFormat
            if channels == 3 {
                let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_MPEG_3_0_A),context)
                XCTAssertEqual(layout.channelCount,channels,context)
                f = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,interleaved:interleaved,channelLayout:layout)
            } else {
                f = try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:channels,interleaved:interleaved),context)
            }
            XCTAssertEqual(f.sampleRate,rate,context); XCTAssertEqual(f.channelCount,channels,context)
            XCTAssertEqual(f.isInterleaved,interleaved,context)
            let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:f,frameCapacity:1),context); b.frameLength = 1
            let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
            await fulfillment(of:[r.engine.started],timeout:2)
            let callback = try XCTUnwrap(r.engine.copied,context)
            callback(b); guard await completed(recording) else { return }
            XCTAssertEqual(r.factories.value,0); XCTAssertTrue(r.ingress.facts.unknown)
            XCTAssertTrue(r.ingress.facts.settled); XCTAssertTrue(r.admission.isAvailable)
        }
    }
    @MainActor func testOversizedConverterOutputAndNonterminalFeedKeepIndependentPriorPrefix() async throws {
        for oversized in [false,true] {
            let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
            await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([0.5])
            if oversized { r.converter.feedFrames = 32_769 }
            else { r.converter.feedStatus = .haveData }
            r.engine.emit([-1]); guard await completed(recording) else { return }
            XCTAssertEqual(try r.takePCM(),oversized ? Data([0,64]) : Data([0,64,0,128]))
            XCTAssertTrue(r.ingress.facts.unknown); XCTAssertEqual(r.factories.value,1)
        }
    }
    @MainActor func testCancelingActualTaskCannotReleaseOrRestartUntilExplicitStopAndActualBodyExit() async throws {
        let r = try MeetingRecorderRig(), entered = expectation(description:"callback held across cancellation")
        let returned = expectation(description:"canceled source callback actually returned")
        let stopEntered = expectation(description:"explicit stop entered acquisition bottom")
        let body = RecorderBodyGate(entered), stop = RecorderBodyGate(stopEntered)
        defer { body.open(); stop.open() }
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([0.5])
        r.converter.feedGate = body; r.engine.stopGate = stop
        let callback = try XCTUnwrap(r.engine.copied)
        DispatchQueue.global().async { callback(MeetingRecorderEngine.buffer([1])); returned.fulfill() }
        await fulfillment(of:[entered],timeout:2)
        guard r.ingress.facts.bodyEntered else { XCTFail("Cancellation requires an entered held body"); return }
        let observation = RecorderCompletion(recording.task)
        recording.task.cancel()
        // Let another MainActor job run after cancellation, before explicit Stop.
        let checkpoint = expectation(description:"MainActor scheduling opportunity after cancel")
        Task { @MainActor in await Task.yield(); checkpoint.fulfill() }
        await fulfillment(of:[checkpoint],timeout:2)
        XCTAssertFalse(observation.finished); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(r.ingress.facts.bodyEntered); XCTAssertFalse(r.ingress.facts.ended)
        let successor = r.admission.acquire(.dictation)
        XCTAssertNil(successor); if let successor { r.admission.release(successor) }
        XCTAssertEqual(r.engine.starts.value,1)
        recording.requestStop()
        await fulfillment(of:[stopEntered],timeout:2)
        XCTAssertFalse(observation.finished); XCTAssertFalse(r.admission.isAvailable)
        XCTAssertTrue(r.ingress.facts.bodyEntered)
        stop.open(); body.open()
        await fulfillment(of:[returned],timeout:2)
        guard await completed(observation) else { return }
        XCTAssertFalse(body.timedOut); XCTAssertFalse(stop.timedOut)
        XCTAssertEqual(try r.takePCM(),Data([0,64])); XCTAssertEqual(r.engine.starts.value,1)
        XCTAssertTrue(r.ingress.facts.unknown); XCTAssertTrue(r.admission.isAvailable)
    }

    @MainActor func testPositiveNoncanonicalSourceKeepsOnePersistentFakeAcrossBodies() async throws {
        // This qualifies adapter plumbing only; the fake does not claim native resampling.
        let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2)
        r.engine.emit([0.5],rate:48_000); r.engine.emit([-0.5],rate:48_000)
        recording.requestStop(); guard await completed(recording) else { return }
        XCTAssertEqual(r.factories.value,1); XCTAssertEqual(r.converter.feeds.value,2)
        XCTAssertEqual(try r.takePCM(),Data([0,64,0,192])); XCTAssertFalse(r.ingress.facts.unknown)
    }
    @MainActor func testAcceptedInputWithZeroImmediateOutputCanPublishOnlyRealTerminalTail() async throws {
        let r = try MeetingRecorderRig(); r.converter.feedFrames = 0; r.converter.tail = [0.5]
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([1])
        XCTAssertEqual(r.ingress.facts.accepted,0); recording.requestStop(); guard await completed(recording) else { return }
        XCTAssertEqual(try r.takePCM(),Data([0,64])); XCTAssertFalse(r.ingress.facts.unknown)
        XCTAssertEqual(r.converter.feeds.value,1); XCTAssertEqual(r.converter.finishes.value,1)
    }
    @MainActor func testPositiveTerminalTailThatCannotFitRetainsExactPrefixAndUnknown() async throws {
        let r = try MeetingRecorderRig(); r.converter.tail = [0.5,1]
        let recording = try r.start(); defer { recording.requestStop() }
        await fulfillment(of:[r.engine.started],timeout:2); r.fill(479_999)
        recording.requestStop(); guard await completed(recording) else { return }
        XCTAssertEqual(try r.takePCM(),Data(repeating:0,count:959_998))
        XCTAssertEqual(r.ingress.facts.accepted,479_999); XCTAssertTrue(r.ingress.facts.unknown)
        XCTAssertEqual(r.ingress.facts.reason,.invalidTail); XCTAssertTrue(r.admission.isAvailable)
    }

    @MainActor func testNonfiniteConverterOutputAndTailPreservePriorLiteralPrefixWithoutMarkers() async throws {
        for inTail in [false,true] {
            let r = try MeetingRecorderRig(), recording = try r.start(); defer { recording.requestStop() }
            await fulfillment(of:[r.engine.started],timeout:2); r.engine.emit([0.5])
            if inTail { r.converter.tail = [.nan]; recording.requestStop() }
            else { r.converter.emittedValue = .nan; r.engine.emit([1]) }
            guard await completed(recording) else { return }
            XCTAssertEqual(try r.takePCM(),Data([0,64])); XCTAssertTrue(r.ingress.facts.unknown)
            XCTAssertTrue(r.admission.isAvailable)
        }
    }

}
