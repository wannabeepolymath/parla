import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import ParlaCore

private final class AppCount: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
/// Every hold releases independently of the capture task after <=5s, as well as by defer.
/// No counter/ingress/store lock is held while waiting.
private final class AppBodyHold: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value:0)
    private var used = false, opened = false, expired = false
    let entered: XCTestExpectation, returned: XCTestExpectation
    init(entered: XCTestExpectation, returned: XCTestExpectation) { self.entered = entered; self.returned = returned }
    func body() {
        let take = lock.withLock { () -> Bool in if used { return false }; used = true; return true }
        guard take else { return }; entered.fulfill()
        if semaphore.wait(timeout:.now()+5) == .timedOut { lock.withLock { expired = true } }
        returned.fulfill()
    }
    func release() {
        let first = lock.withLock { () -> Bool in if opened { return false }; opened = true; return true }
        if first { semaphore.signal() }
    }
    var timedOut: Bool { lock.withLock { expired } }
}
private final class AppPCM {
    let list: UnsafeMutablePointer<AudioBufferList>, raw: UnsafeMutableRawPointer
    private var allocations: [UnsafeMutablePointer<Float>] = []
    var declared: AudioStreamBasicDescription?
    init(_ planes: [[Float]], channelsPerBuffer: Int = 1) {
        let count = max(1,planes.count), bytes = MemoryLayout<AudioBufferList>.size + (count-1)*MemoryLayout<AudioBuffer>.stride
        raw = .allocate(byteCount:bytes,alignment:MemoryLayout<AudioBufferList>.alignment)
        raw.initializeMemory(as:UInt8.self,repeating:0,count:bytes); list = raw.assumingMemoryBound(to:AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(count)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for i in 0..<count {
            let values = planes.isEmpty ? [] : planes[i], p = UnsafeMutablePointer<Float>.allocate(capacity:max(1,values.count))
            for j in values.indices { p[j] = values[j] }; allocations.append(p)
            buffers[i] = .init(mNumberChannels:UInt32(channelsPerBuffer),mDataByteSize:UInt32(values.count*4),mData:p)
        }
    }
    deinit { for p in allocations { p.deallocate() }; raw.deallocate() }
    func mutate(_ work: (UnsafeMutableAudioBufferListPointer) -> Void) { work(.init(list)) }
    var borrowed: ApplicationBorrowedPCM { .init(list:UnsafePointer(list),declaredFormat:declared) }
}
private final class AppConverter: MeetingPCMConverting, @unchecked Sendable {
    let feeds = AppCount(), finishes = AppCount()
    var feedHold: AppBodyHold?, feedOracle: ((AVAudioPCMBuffer) -> Void)?
    var tail: [MeetingConversionStep] = [.init(frames:0,status:.endOfStream)]
    var tailValue: Float = 0.5
    func feed(_ input: AVAudioPCMBuffer, output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        feeds.add(); feedHold?.body(); feedOracle?(input)
        let n = Int(input.frameLength), channels = Int(input.format.channelCount)
        guard n <= output.count,let p = input.floatChannelData else { return .init(frames:0,status:.failed) }
        for frame in 0..<n { output[frame] = channels == 1 ? p[0][frame] : (p[0][frame]+p[1][frame])/2 }
        return .init(frames:n,status:.inputExhausted)
    }
    func finish(output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep {
        let index = finishes.value; finishes.add()
        let step = tail[min(index,tail.count-1)]
        if (0...output.count).contains(step.frames) { for i in 0..<step.frames { output[i] = tailValue } }
        return step
    }
}
private enum AppPhase: String, CaseIterable {
    case identity, revalidate, resolve, tap, aggregate, listener1, listener2, listener3, listener4, inputReadback, io, start
    case stop, removeIO, removeListeners, destroyAggregate, destroyTap
}
/// Every native operation is replaced, including identity, listeners and converter.
/// There is no default/native selector, factory or fall-through inside this fake.
private final class AppBottom: ApplicationAudioBottom, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [AppPhase:Int] = [:], gateValue: ApplicationAudioGate?
    private var pcmQueue: DispatchQueue?, listenerQueue: DispatchQueue?
    var fail: AppPhase?, held: [AppPhase:AppBodyHold] = [:]
    var unknownObject = false, missingFacts = false, incarnation: Int64 = 42
    var format: ApplicationPCMFormat
    var formatAfterListeners: ApplicationPCMFormat?
    var onStarted: (() -> Void)?, onInstall: ((ApplicationAudioGate) -> Void)?, listenerHold: AppBodyHold?
    var observedPlan: ResolvedApplicationAudio?, observedInputOnly = false
    let inspected = AppCount(), included = AppCount(), observedRegistered = AppCount()
    init(format: ApplicationPCMFormat) { self.format = format }
    func count(_ phase: AppPhase) -> Int { lock.withLock { calls[phase,default:0] } }
    var total: Int { lock.withLock { calls.values.reduce(0,+) } }
    var copied: ApplicationAudioGate? { lock.withLock { gateValue } }
    func callbackQueue(listener: Bool) -> DispatchQueue? { lock.withLock { listener ? listenerQueue : pcmQueue } }
    private func phase(_ phase: AppPhase) throws {
        lock.withLock { calls[phase,default:0] += 1 }
        held[phase]?.body()
        if fail == phase { throw MeetingSession.Failure.unavailable }
    }
    @MainActor func bindIdentity(_ b: SelectedApplicationBinding, owned: ApplicationAudioResources,
                                 gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws {
        try phase(.identity)
        guard !missingFacts,b.launchNanoseconds == incarnation else { throw MeetingSession.Failure.stale }
    }
    @MainActor func revalidateIdentity(_ b: SelectedApplicationBinding, owned: ApplicationAudioResources) throws {
        try phase(.revalidate)
        guard !missingFacts,b.launchNanoseconds == incarnation else { throw MeetingSession.Failure.stale }
    }
    @MainActor func removeObserver(_ owned: ApplicationAudioResources) { /* fake owns no AppKit observer */ }
    func resolve(_ b: SelectedApplicationBinding) throws -> ResolvedApplicationAudio {
        try phase(.resolve)
        return .init(binding:b,process:unknownObject ? kAudioObjectUnknown : 101,routes:[.init(id:201,uid:"literal-output")])
    }
    func createTap(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources) throws {
        observedPlan = plan; included.add(); try owned.ownTap(301); owned.tapUID = "literal-tap"
        owned.format = format; try phase(.tap)
    }
    func createAggregate(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources) throws {
        try owned.ownAggregate(401); owned.inputStream = 501
        // Typed fake bottom has no physical-subdevice operation to call.
        observedInputOnly = true; try phase(.aggregate)
    }
    func installListeners(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources,
                          gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws {
        lock.withLock { listenerQueue = queues.listener }
        if let listenerHold { gate.setListenerBody { listenerHold.body() } }
        let phases: [AppPhase] = [.listener1,.listener2,.listener3,.listener4]
        for (i,phaseName) in phases.enumerated() {
            try owned.ownListener(object:UInt32(601+i),
                address:.init(mSelector:kAudioObjectPropertySelectorWildcard,mScope:kAudioObjectPropertyScopeGlobal,mElement:0),
                queue:queues.listener,block:{ [gate] _,_ in gate.changed() })
            try phase(phaseName)
        }
        if let formatAfterListeners { format = formatAfterListeners } // deliberately no notification
    }
    func revalidateInput(_ owned: ApplicationAudioResources) throws {
        try phase(.inputReadback)
        guard let frozen = owned.format,format == frozen else { throw MeetingSession.Failure.bounds }
    }
    func installIOProc(_ owned: ApplicationAudioResources, gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws {
        try owned.ownIOProc(nil); lock.withLock { gateValue = gate; pcmQueue = queues.pcm }
        onInstall?(gate) // synchronous first PCM, including a throw after it, is inside the actual task
        try phase(.io)
    }
    func start(_ owned: ApplicationAudioResources) throws {
        owned.io?.startAttempted = true; try phase(.start); onStarted?()
    }
    func stop(_ owned: ApplicationAudioResources) throws {
        guard let io = owned.io,!io.stopAttempted else { throw MeetingSession.Failure.stale }
        io.stopAttempted = true; try phase(.stop)
    }
    func removeIOProc(_ owned: ApplicationAudioResources) throws {
        guard let io = owned.io,!io.removeAttempted else { throw MeetingSession.Failure.stale }
        io.removeAttempted = true; try phase(.removeIO); owned.io = nil
    }
    func removeListeners(_ owned: ApplicationAudioResources) -> Bool {
        do { try phase(.removeListeners); owned.listeners.removeAll(); return true } catch { return false }
    }
    func destroyAggregate(_ owned: ApplicationAudioResources) throws {
        guard let aggregate = owned.aggregate,!aggregate.attempted,owned.io == nil,owned.listeners.isEmpty else {
            throw MeetingSession.Failure.stale
        }
        aggregate.attempted = true; try phase(.destroyAggregate); owned.aggregate = nil
    }
    func destroyTap(_ owned: ApplicationAudioResources) throws {
        guard let tap = owned.tap,!tap.attempted,owned.aggregate == nil else { throw MeetingSession.Failure.stale }
        tap.attempted = true; try phase(.destroyTap); owned.tap = nil
    }
    func emit(_ pcm: AppPCM) { copied?.receive { inspected.add(); return pcm.borrowed } }
}
@MainActor private final class AppRig {
    let ingress: MeetingAudioIngress, binding: SelectedApplicationBinding, bottom: AppBottom, converter = AppConverter()
    let factories = AppCount(), converters = AppCount()
    let capture: MeetingApplicationAudioCapture
    init(format: ApplicationPCMFormat? = nil, precharge: Bool = true, retained: @escaping () -> Void = {}) throws {
        let context = MeetingAudioIngress.Context(session:UUID(),ownerGeneration:3,source:UUID(),sourceGeneration:7,segment:UUID(),epoch:UUID())
        ingress = .init(context:context)
        if precharge { try ingress.reserve(id:UUID(),slot:1); try ingress.reserve(id:UUID(),slot:2); try ingress.activate() }
        binding = .init(selection:UUID(),source:context.source,sourceGeneration:7,captureEpoch:context.epoch,
                        pid:55,launchNanoseconds:42,bundleID:"org.literal.app",bundlePath:"/Literal.app",
                        executablePath:"/Literal.app/Contents/MacOS/Literal",label:"Literal app")
        bottom = AppBottom(format:try format ?? .init(rate:16_000,channels:1,interleaved:false))
        let bottom = bottom, converter = converter, factories = factories, converters = converters
        capture = .init(makeBottom:{ factories.add(); return bottom },makeConverter:{ _ in converters.add(); return converter },retainedFailure:retained)
    }
    func start(_ binding: SelectedApplicationBinding? = nil, enabled: Bool = true) throws -> ApplicationAudioRecording {
        switch capture.startSelectedApplication(binding:binding ?? self.binding,ingress:ingress,enabled:enabled) {
        case .actual(let recording): return recording
        case .notStarted: XCTFail("Expected actual typed fake producer"); throw MeetingSession.Failure.unavailable
        }
    }
    func take() throws -> Data {
        let delivery = try ingress.take(XCTUnwrap(ingress.readyPermit))
        defer { try? ingress.retire(delivery.permit) }; return delivery.bytes
    }
}
@MainActor private final class AppCompletion {
    let done = XCTestExpectation(description:"actual task returned")
    private(set) var finished = false
    init(_ task: Task<Void,Never>) { Task { @MainActor [self] in await task.value; finished = true; done.fulfill() } }
}

final class MeetingApplicationAudioCaptureTests: XCTestCase {
    /// The final task join is allowed only after independently observed actual completion.
    @MainActor private func complete(_ recording: ApplicationAudioRecording, observation: AppCompletion? = nil) async -> Bool {
        let observation = observation ?? AppCompletion(recording.task)
        await fulfillment(of:[observation.done],timeout:3)
        guard observation.finished else { XCTFail("Actual source exit unobserved; do not await a held task"); return false }
        await recording.task.value; return true
    }
    @MainActor private func running(_ rig: AppRig) async throws -> ApplicationAudioRecording {
        let started = expectation(description:"fake start actually returned")
        rig.bottom.onStarted = { started.fulfill() }; let recording = try rig.start()
        await fulfillment(of:[started],timeout:2)
        XCTAssertEqual(rig.bottom.count(.start),1); return recording
    }
    private func hold(_ label: String) -> AppBodyHold {
        .init(entered:expectation(description:label+" entered"),returned:expectation(description:label+" returned"))
    }
    // Independent WAV literal; no production encoder/quantizer/decoder builds expectations.
    private func wav(_ pcm: [UInt8]) -> Data {
        var header: [UInt8] = [82,73,70,70,0,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,
                               128,62,0,0,0,125,0,0,2,0,16,0,100,97,116,97,0,0,0,0]
        for i in 0..<4 { header[4+i] = UInt8(truncatingIfNeeded:(36+pcm.count) >> (8*i)); header[40+i] = UInt8(truncatingIfNeeded:pcm.count >> (8*i)) }
        return Data(header+pcm)
    }
    private func replacing(_ b: SelectedApplicationBinding, pid: Int32? = nil, generation: UInt64? = nil,
                           epoch: UUID? = nil, source: UUID? = nil, label: String? = nil,
                           bundle: String? = nil, path: String? = nil, launch: Int64? = nil) -> SelectedApplicationBinding {
        .init(selection:b.selection,source:source ?? b.source,sourceGeneration:generation ?? b.sourceGeneration,
              captureEpoch:epoch ?? b.captureEpoch,pid:pid ?? b.pid,launchNanoseconds:launch ?? b.launchNanoseconds,
              bundleID:bundle ?? b.bundleID,bundlePath:path ?? b.bundlePath,executablePath:b.executablePath,label:label ?? b.label)
    }

    @MainActor func testDefaultOffAndPureValidationQueryNothing() async throws {
        let rig = try AppRig(precharge:false), nativeDefault = MeetingApplicationAudioCapture()
        let before = rig.ingress.facts
        XCTAssertTrue(rig.capture.validate(rig.binding,context:rig.ingress.context))
        XCTAssertTrue(nativeDefault.validate(rig.binding,context:rig.ingress.context))
        for capture in [rig.capture,nativeDefault] {
            if case .actual = capture.startSelectedApplication(binding:rig.binding,ingress:rig.ingress) { XCTFail("Default must be off") }
        }
        XCTAssertEqual(rig.factories.value,0); XCTAssertEqual(rig.converters.value,0); XCTAssertEqual(rig.bottom.total,0)
        XCTAssertEqual(rig.ingress.facts,before); XCTAssertFalse(rig.capture.hasActualTask)
        let admission = CaptureAdmission(), foreign = try XCTUnwrap(admission.acquire(.guidedTemplate))
        if case .actual = rig.capture.startSelectedApplication(binding:rig.binding,ingress:rig.ingress,enabled:true) { XCTFail("Uncharged ingress") }
        XCTAssertTrue(admission.owns(foreign)); XCTAssertEqual(rig.factories.value,0); admission.release(foreign)
        XCTAssertEqual(ApplicationAudioPayloadCharge.total,3_273_348)
        XCTAssertEqual(ApplicationAudioPayloadCharge.normalization,65_536)
        let early = try AppRig(), recording = try early.start()
        recording.requestStop() // before the registered MainActor actual task can run a factory
        guard await complete(recording) else { return }
        XCTAssertEqual(early.factories.value,0); XCTAssertEqual(early.bottom.total,0)
        XCTAssertEqual(early.converters.value,0); XCTAssertTrue(early.ingress.facts.ended)
    }

    @MainActor func testUnknownPIDObjectAndIncarnationMismatchRefuseBeforeTapCreation() async throws {
        let rig = try AppRig(), b = rig.binding
        for bad in [replacing(b,pid:0),replacing(b,pid:-1),replacing(b,generation:0),replacing(b,generation:8),
                    replacing(b,epoch:UUID()),replacing(b,source:UUID()),replacing(b,label:String(repeating:"x",count:129)),
                    replacing(b,bundle:""),replacing(b,bundle:String(repeating:"x",count:257)),replacing(b,label:"bad\0label"),
                    replacing(b,path:"relative"),replacing(b,path:"/"+String(repeating:"x",count:4_096)),replacing(b,launch:0)] {
            XCTAssertFalse(rig.capture.validate(bad,context:rig.ingress.context))
            if case .actual = rig.capture.startSelectedApplication(binding:bad,ingress:rig.ingress,enabled:true) { XCTFail("Malformed/foreign binding") }
        }
        XCTAssertEqual(rig.factories.value,0); XCTAssertEqual(rig.bottom.total,0)
        for failure in 0..<3 {
            let r = try AppRig(); r.bottom.unknownObject = failure == 0
            r.bottom.incarnation = failure == 1 ? 43 : 42; r.bottom.missingFacts = failure == 2
            let recording = try r.start(); defer { recording.requestStop() }
            guard await complete(recording) else { return }
            XCTAssertEqual(r.bottom.count(.tap),0); XCTAssertEqual(r.bottom.included.value,0)
            XCTAssertTrue(r.ingress.facts.ended); XCTAssertTrue(r.ingress.facts.unknown)
        }
    }

    @MainActor func testOnlyExplicitProcessIsIncludedAndRestoreAndGlobalModesAreRefused() async throws {
        let r = try AppRig(), recording = try await running(r); defer { recording.requestStop() }
        let plan = try XCTUnwrap(r.bottom.observedPlan)
        XCTAssertEqual(plan.binding,r.binding); XCTAssertEqual(plan.process,101)
        XCTAssertEqual(plan.routes,[.init(id:201,uid:"literal-output")]); XCTAssertTrue(plan.valid)
        XCTAssertTrue(r.bottom.observedInputOnly); XCTAssertEqual(r.bottom.included.value,1)
        let selection = try XCTUnwrap(plan.tapPlan)
        XCTAssertEqual(selection.includedProcesses,[101]); XCTAssertTrue(selection.privateTap)
        XCTAssertFalse(selection.exclusive); XCTAssertFalse(selection.restore); XCTAssertTrue(selection.unmuted)
        XCTAssertTrue(selection.bundleIDs.isEmpty); XCTAssertTrue(selection.physicalInputs.isEmpty)
        let before = r.bottom.total
        XCTAssertNil(ApplicationAudioTapPlan.select([]))
        XCTAssertNil(ApplicationAudioTapPlan.select([0]))
        XCTAssertNil(ApplicationAudioTapPlan.select([101,102]))
        XCTAssertNil(ApplicationAudioTapPlan.select([101],privateTap:false))
        XCTAssertNil(ApplicationAudioTapPlan.select([101],exclusive:true))
        XCTAssertNil(ApplicationAudioTapPlan.select([101],restore:true))
        XCTAssertNil(ApplicationAudioTapPlan.select([101],unmuted:false))
        XCTAssertNil(ApplicationAudioTapPlan.select([101],bundleIDs:["org.foreign.helper"]))
        XCTAssertNil(ApplicationAudioTapPlan.select([101],physicalInputs:[999]))
        let first = ApplicationAudioResources(), second = ApplicationAudioResources()
        try first.ownTap(701); let receipt = try XCTUnwrap(first.tap)
        XCTAssertTrue(first.owns(receipt)); XCTAssertFalse(second.owns(receipt))
        XCTAssertThrowsError(try first.ownTap(702)); XCTAssertThrowsError(try second.ownTap(0))
        XCTAssertEqual(r.bottom.total,before) // all refused shapes are pure, before a bottom operation
        XCTAssertEqual(r.bottom.count(.resolve),2); XCTAssertEqual(r.bottom.count(.identity),1)
        XCTAssertEqual(r.bottom.count(.revalidate),1)
        recording.requestStop(); guard await complete(recording) else { return }
        XCTAssertEqual(r.bottom.count(.destroyAggregate),1); XCTAssertEqual(r.bottom.count(.destroyTap),1)
        XCTAssertFalse(r.capture.hasActualTask); XCTAssertFalse(r.ingress.facts.unknown)
    }

    @MainActor func testEveryPartialStartReturnsActualJoinUntilOwnedCleanupExits() async throws {
        for phase in [AppPhase.tap,.aggregate,.listener1,.listener2,.listener3,.listener4,.revalidate,.inputReadback,.io,.start] {
            let r = try AppRig(), cleanup = hold("cleanup \(phase.rawValue)"), registered = AppCount()
            defer { cleanup.release() }
            r.bottom.fail = phase; r.bottom.held[.destroyTap] = cleanup
            r.bottom.onInstall = { gate in
                XCTAssertEqual(registered.value,1)
                let pcm = AppPCM([[-1,0.5]]); gate.receive { pcm.borrowed }
            }
            let recording = try r.start(); registered.add(); defer { recording.requestStop() }
            let completion = AppCompletion(recording.task)
            await fulfillment(of:[cleanup.entered],timeout:2)
            XCTAssertTrue(r.capture.hasActualTask); XCTAssertFalse(completion.finished)
            XCTAssertEqual(r.bottom.count(.destroyTap),1)
            cleanup.release(); await fulfillment(of:[cleanup.returned],timeout:2)
            guard await complete(recording,observation:completion) else { return }
            XCTAssertFalse(cleanup.timedOut); XCTAssertTrue(r.ingress.facts.ended); XCTAssertTrue(r.ingress.facts.unknown)
            XCTAssertEqual(r.bottom.count(.destroyTap),1)
            XCTAssertEqual(r.bottom.count(.destroyAggregate),phase == .tap ? 0 : 1)
            if phase == .io || phase == .start { XCTAssertEqual(try r.take(),wav([0,128,0,64])) }
            else { XCTAssertNil(r.ingress.readyPermit); XCTAssertEqual(r.converters.value,0) }
        }
        // F0 is frozen before listener registration; F1 arrives before registration
        // completes with the same routes/channels and no delivered change callback.
        let changed = try AppRig()
        changed.bottom.formatAfterListeners = try .init(rate:48_000,channels:1,interleaved:false)
        let recording = try changed.start(); defer { recording.requestStop() }
        guard await complete(recording) else { return }
        XCTAssertEqual(changed.bottom.count(.listener4),1)
        XCTAssertEqual(changed.bottom.count(.inputReadback),1)
        XCTAssertEqual(changed.bottom.count(.io),0); XCTAssertEqual(changed.bottom.count(.start),0)
        XCTAssertEqual(changed.converters.value,0); XCTAssertEqual(changed.converter.feeds.value,0)
        XCTAssertTrue(changed.ingress.facts.ended); XCTAssertTrue(changed.ingress.facts.unknown)
        XCTAssertNil(changed.ingress.readyPermit); XCTAssertFalse(changed.capture.hasActualTask)
        XCTAssertEqual(changed.bottom.count(.destroyAggregate),1); XCTAssertEqual(changed.bottom.count(.destroyTap),1)
    }

    @MainActor func testInterleavedAndPlanarLiteralPCMRespectPrechargedScratchAndBounds() async throws {
        for interleaved in [false,true] {
            let format = try ApplicationPCMFormat(rate:16_000,channels:2,interleaved:interleaved)
            let r = try AppRig(format:format), recording = try await running(r); defer { recording.requestStop() }
            r.converter.feedOracle = { b in
                XCTAssertFalse(b.format.isInterleaved); XCTAssertEqual(b.frameCapacity,8_192); XCTAssertEqual(b.frameLength,2)
                XCTAssertEqual(b.floatChannelData![0][0],-1); XCTAssertEqual(b.floatChannelData![0][1],0.5)
                XCTAssertEqual(b.floatChannelData![1][0],0); XCTAssertEqual(b.floatChannelData![1][1],1)
            }
            r.bottom.emit(AppPCM(interleaved ? [[-1,0,0.5,1]] : [[-1,0.5],[0,1]],channelsPerBuffer:interleaved ? 2 : 1))
            recording.requestStop(); guard await complete(recording) else { return }
            XCTAssertEqual(try r.take(),wav([0,192,0,96])); XCTAssertEqual(r.converters.value,1)
            XCTAssertEqual(r.converter.feeds.value,1); XCTAssertFalse(r.ingress.facts.unknown)
        }
        // Direct 16k mono: exact independent canonical words, with no channel ambiguity.
        let mono = try AppRig(), take = try await running(mono); defer { take.requestStop() }
        mono.bottom.emit(AppPCM([[-1,0,0.5,1,-0.5]])); take.requestStop()
        guard await complete(take) else { return }; XCTAssertEqual(try mono.take(),wav([0,128,0,0,0,64,255,127,0,192]))
        for shape in 0..<10 {
            let r = try AppRig(), recording = try await running(r); defer { recording.requestStop() }
            let pcm = AppPCM([[0.5]])
            switch shape {
            case 0: pcm.list.pointee.mNumberBuffers = 0
            case 1: pcm.list.pointee.mNumberBuffers = 3
            case 2: pcm.mutate { $0[0].mDataByteSize = 3 }
            case 3: pcm.mutate { $0[0].mData = nil }
            case 4: pcm.mutate { $0[0].mNumberChannels = 2 }
            case 5: pcm.mutate { $0[0].mDataByteSize = UInt32(8_193*4) }
            case 6: pcm.mutate { $0[0].mData!.assumingMemoryBound(to:Float.self)[0] = .nan }
            case 7: var asbd = r.bottom.format.asbd; asbd.mChannelsPerFrame = UInt32.max; pcm.declared = asbd
            case 8: var asbd = r.bottom.format.asbd; asbd.mBytesPerFrame = 8; pcm.declared = asbd
            default: var asbd = r.bottom.format.asbd; asbd.mSampleRate = 16_000.5; pcm.declared = asbd
            }
            r.bottom.emit(pcm); guard await complete(recording) else { return }
            XCTAssertEqual(r.converters.value,0); XCTAssertEqual(r.converter.feeds.value,0)
            XCTAssertTrue(r.ingress.facts.unknown); XCTAssertNil(r.ingress.readyPermit)
        }
        for interleaved in [false,true] {
            for fault in 0..<3 {
                let r = try AppRig(format:ApplicationPCMFormat(rate:16_000,channels:2,interleaved:interleaved))
                let recording = try await running(r); defer { recording.requestStop() }
                let pcm = AppPCM(interleaved ? [[-1,0,0.5,1]] : [[-1,0.5],[0,1]],channelsPerBuffer:interleaved ? 2 : 1)
                if fault == 0 { pcm.mutate { $0[0].mDataByteSize = interleaved ? 12 : 7 } }
                if fault == 1 { pcm.list.pointee.mNumberBuffers = interleaved ? 2 : 1 }
                if fault == 2 { pcm.mutate { $0[interleaved ? 0 : 1].mDataByteSize = 4 } }
                r.bottom.emit(pcm); guard await complete(recording) else { return }
                XCTAssertEqual(r.converters.value,0); XCTAssertTrue(r.ingress.facts.unknown)
            }
        }
        let empty = try AppRig(), zero = try await running(empty); defer { zero.requestStop() }
        empty.bottom.emit(AppPCM([[]])); XCTAssertEqual(empty.converters.value,0)
        XCTAssertEqual(empty.ingress.facts.accepted,0); XCTAssertTrue(empty.ingress.facts.open)
        XCTAssertThrowsError(try empty.ingress.reserve(id:UUID(),slot:3))
        zero.requestStop(); guard await complete(zero) else { return }
        XCTAssertEqual(empty.converter.finishes.value,0); XCTAssertNil(empty.ingress.readyPermit)
        for rate in [7_999.0,192_001,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try ApplicationPCMFormat(rate:rate,channels:1,interleaved:false))
        }
        for rate in [8_000.0,192_000] { XCTAssertNoThrow(try ApplicationPCMFormat(rate:rate,channels:2,interleaved:true)) }
        let edge = try AppRig(), edgeRecording = try await running(edge); defer { edgeRecording.requestStop() }
        edge.bottom.emit(AppPCM([Array(repeating:0.5,count:8_192)]))
        XCTAssertEqual(edge.ingress.facts.accepted,8_192); edgeRecording.requestStop()
        guard await complete(edgeRecording) else { return }; XCTAssertEqual(edge.converters.value,1)
    }

    @MainActor func testClosedEpochRejectsBeforeNativeBufferOrScratchAccess() async throws {
        let r = try AppRig(), recording = try await running(r); defer { recording.requestStop() }
        let stale = try XCTUnwrap(r.bottom.copied)
        recording.requestStop(); guard await complete(recording) else { return }
        let next = try AppRig(), successor = try await running(next); defer { successor.requestStop() }
        XCTAssertNotEqual(next.binding.captureEpoch,r.binding.captureEpoch)
        let before = next.ingress.facts, old = r.ingress.facts
        stale.receive { XCTFail("Stale epoch inspected borrowed PCM"); fatalError("must refuse before inspection") }
        stale.changed { XCTFail("Stale listener inspected native addresses"); return true }
        XCTAssertEqual(next.ingress.facts,before); XCTAssertEqual(r.ingress.facts,old)
        XCTAssertEqual(r.converters.value,0); XCTAssertEqual(next.converters.value,0)
        successor.requestStop(); guard await complete(successor) else { return }
    }

    @MainActor func testStopAcknowledgmentsCannotRetireEnteredCallbackOrControlBody() async throws {
        for phase in ["pcm","listener","start","stop","destroyAggregate","destroyTap"] {
            let r = try AppRig(), body = hold(phase)
            let actualReturn = phase == "pcm" || phase == "listener" ? expectation(description:phase+" actual invocation returned") : nil
            defer { body.release() }
            if phase == "pcm" { r.converter.feedHold = body }
            if phase == "listener" { r.bottom.listenerHold = body }
            let nativePhase: AppPhase? = AppPhase(rawValue:phase)
            if let nativePhase { r.bottom.held[nativePhase] = body }
            let recording: ApplicationAudioRecording
            if phase == "start" { recording = try r.start() }
            else { recording = try await running(r) }
            defer { recording.requestStop() }
            let completion = AppCompletion(recording.task)
            if phase == "pcm" || phase == "listener" {
                let gate = try XCTUnwrap(r.bottom.copied)
                let queue = try XCTUnwrap(r.bottom.callbackQueue(listener:phase == "listener"))
                queue.async {
                    if phase == "pcm" { let pcm = AppPCM([[0.5]]); gate.receive { pcm.borrowed } }
                    else { gate.changed() }
                    actualReturn?.fulfill()
                }
            }
            if phase == "stop" || phase.hasPrefix("destroy") { recording.requestStop() }
            await fulfillment(of:[body.entered],timeout:2)
            recording.requestStop()
            XCTAssertTrue(r.capture.hasActualTask); XCTAssertFalse(completion.finished)
            XCTAssertFalse(r.ingress.facts.open)
            if !phase.hasPrefix("destroy") { XCTAssertFalse(r.ingress.facts.ended) }
            if phase == "pcm" { XCTAssertEqual(r.converter.finishes.value,0) }
            // Closed callbacks cannot turn the stop acknowledgment into new work.
            r.bottom.copied?.receive { XCTFail("Fence inspected late PCM"); fatalError("late gate") }
            body.release(); await fulfillment(of:[body.returned] + (actualReturn.map { [$0] } ?? []),timeout:2)
            guard await complete(recording,observation:completion) else { return }
            XCTAssertFalse(body.timedOut); XCTAssertTrue(r.ingress.facts.ended)
            XCTAssertEqual(r.bottom.count(.stop),1); XCTAssertEqual(r.bottom.count(.destroyTap),1)
        }
        // A second concurrent PCM body refuses before inspecting its borrowed list; it
        // cannot enter the converter or allocate a second normalization slab.
        let r = try AppRig(), body = hold("primary PCM"), returned = expectation(description:"primary PCM returned")
        defer { body.release() }; r.converter.feedHold = body
        let recording = try await running(r); defer { recording.requestStop() }
        let gate = try XCTUnwrap(r.bottom.copied)
        let queue = try XCTUnwrap(r.bottom.callbackQueue(listener:false))
        queue.async { let pcm = AppPCM([[0.5]]); gate.receive { pcm.borrowed }; returned.fulfill() }
        await fulfillment(of:[body.entered],timeout:2)
        gate.receive { XCTFail("Overlap inspected input"); fatalError("overlap") }
        gate.receive { XCTFail("Third body inspected input"); fatalError("closed") }
        XCTAssertFalse(r.ingress.facts.open); XCTAssertEqual(r.converter.feeds.value,1)
        body.release(); await fulfillment(of:[body.returned,returned],timeout:2)
        guard await complete(recording) else { return }; XCTAssertFalse(body.timedOut); XCTAssertTrue(r.ingress.facts.unknown)
    }

    @MainActor func testEOSRequiresTerminalDispositionAndSharedFourCallTailCap() async throws {
        let cases: [([MeetingConversionStep],Bool,Int,UInt64)] = [
            ([.init(frames:1,status:.endOfStream)],false,1,2),
            ([.init(frames:0,status:.haveData)],true,4,1),
            ([.init(frames:32_769,status:.endOfStream)],true,1,1),
            ([.init(frames:1,status:.failed)],true,1,1),
            ([.init(frames:8_192,status:.haveData),.init(frames:8_192,status:.haveData),
              .init(frames:8_192,status:.haveData),.init(frames:8_192,status:.endOfStream)],false,4,32_769),
            ([.init(frames:32_768,status:.haveData)],true,1,1)
        ]
        for (tail,unknown,calls,accepted) in cases {
            let r = try AppRig(); r.converter.tail = tail
            let recording = try await running(r); defer { recording.requestStop() }
            r.bottom.emit(AppPCM([[-1]])); recording.requestStop()
            guard await complete(recording) else { return }
            XCTAssertEqual(r.converter.finishes.value,calls); XCTAssertLessThanOrEqual(calls,4)
            XCTAssertEqual(r.ingress.facts.accepted,accepted); XCTAssertEqual(r.ingress.facts.unknown,unknown)
            let bytes = try r.take()
            if accepted == 1 { XCTAssertEqual(bytes,wav([0,128])) }
            if accepted == 2 { XCTAssertEqual(bytes,wav([0,128,0,64])) }
            if accepted == 32_769 {
                XCTAssertEqual(bytes.count,65_582); XCTAssertEqual(Data(bytes[44..<48]),Data([0,128,0,64]))
                XCTAssertEqual(Data(bytes.suffix(4)),Data([0,64,0,64]))
            }
        }
        let r = try AppRig(); r.converter.tail = [.init(frames:1,status:.endOfStream)]; r.converter.tailValue = .nan
        let recording = try await running(r); defer { recording.requestStop() }
        r.bottom.emit(AppPCM([[-1]])); recording.requestStop(); guard await complete(recording) else { return }
        XCTAssertEqual(try r.take(),wav([0,128])); XCTAssertTrue(r.ingress.facts.unknown)
    }

    @MainActor func testRouteTerminationFormatAndPermissionLossFenceWithoutRetarget() async throws {
        for loss in ["route","termination","format","permission","identity","readback"] {
            let r = try AppRig(), retirement = hold("revocation reaches actual stop")
            r.bottom.held[.stop] = retirement
            let recording = try await running(r), completion = AppCompletion(recording.task)
            defer { retirement.release(); recording.requestStop() }
            r.bottom.emit(AppPCM([[0.5]])); let gate = try XCTUnwrap(r.bottom.copied)
            if loss == "format" {
                let changed = AppPCM([[1]]); var format = r.bottom.format.asbd; format.mSampleRate = 48_000
                changed.declared = format; r.bottom.emit(changed)
            } else {
                // Typed bottom delivers the same scalar revocation for each native cause;
                // these fakes do not pretend to exercise actual TCC/NSWorkspace/HAL events.
                gate.changed()
            }
            XCTAssertFalse(r.ingress.facts.open)
            // Loss itself must enter retirement. Later Stop requests may test
            // coalescing/cleanup only after this independent bounded observation.
            await fulfillment(of:[retirement.entered],timeout:2)
            XCTAssertEqual(r.bottom.count(.stop),1); XCTAssertFalse(completion.finished)
            for _ in 0..<20 { gate.changed(); recording.requestStop() }
            retirement.release(); await fulfillment(of:[retirement.returned],timeout:2)
            guard await complete(recording,observation:completion) else { return }
            XCTAssertFalse(retirement.timedOut)
            XCTAssertEqual(try r.take(),wav([0,64])); XCTAssertTrue(r.ingress.facts.unknown)
            XCTAssertEqual(r.bottom.count(.start),1); XCTAssertEqual(r.bottom.count(.stop),1)
            XCTAssertEqual(r.bottom.count(.tap),1); XCTAssertEqual(r.bottom.count(.aggregate),1)
            XCTAssertEqual(r.bottom.count(.resolve),2); XCTAssertEqual(r.factories.value,1)
            XCTAssertEqual(r.bottom.count(.destroyTap),1)
        }
    }

    @MainActor func testUnknownHandleRetirementNeverProducesKnownExitOrRetry() async throws {
        for phase in [AppPhase.stop,.removeIO,.removeListeners,.destroyAggregate,.destroyTap] {
            let retained = expectation(description:"uncertain retirement retained \(phase.rawValue)")
            let r = try AppRig(retained:{ retained.fulfill() }); r.bottom.fail = phase
            let recording = try await running(r)
            recording.requestStop(); await fulfillment(of:[retained],timeout:3)
            XCTAssertTrue(r.capture.hasActualTask); XCTAssertEqual(r.bottom.count(phase),1)
            recording.task.cancel() // cancellation cannot resume the retained closure
            recording.requestStop(); recording.requestStop()
            if case .actual = r.capture.startSelectedApplication(binding:r.binding,ingress:r.ingress,enabled:true) { XCTFail("Quarantined source restarted") }
            XCTAssertTrue(r.capture.hasActualTask); XCTAssertEqual(r.bottom.count(phase),1)
            XCTAssertEqual(r.bottom.count(.start),1); XCTAssertEqual(r.factories.value,1)
            if phase == .stop { XCTAssertEqual(r.bottom.count(.removeIO),0) }
            if phase == .stop || phase == .removeIO || phase == .removeListeners { XCTAssertEqual(r.bottom.count(.destroyAggregate),0) }
            if phase != .destroyTap { XCTAssertEqual(r.bottom.count(.destroyTap),0) }
            // Deliberately no task.value/completion observer: this is the known held state,
            // with no external unbounded join and no retry/timeout pretending it exited.
        }
    }
}
