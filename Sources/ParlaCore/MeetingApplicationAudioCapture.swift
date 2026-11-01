import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Volatile, value-only selection facts. Never a permission token or saved native handle.
public struct SelectedApplicationBinding: Equatable, Sendable {
    public let selection: UUID, source: UUID, captureEpoch: UUID
    public let sourceGeneration: UInt64
    public let pid: Int32, launchNanoseconds: Int64
    public let bundleID: String, bundlePath: String, executablePath: String, label: String
    public init(selection: UUID, source: UUID, sourceGeneration: UInt64, captureEpoch: UUID,
                pid: Int32, launchNanoseconds: Int64, bundleID: String, bundlePath: String,
                executablePath: String, label: String) {
        self.selection = selection; self.source = source; self.sourceGeneration = sourceGeneration
        self.captureEpoch = captureEpoch; self.pid = pid; self.launchNanoseconds = launchNanoseconds
        self.bundleID = bundleID; self.bundlePath = bundlePath; self.executablePath = executablePath; self.label = label
    }
    // New evidence authority is byte-exact without changing legacy Equatable semantics.
    func exactlyMatches(_ other: Self) -> Bool {
        self == other && bundleID.utf8.elementsEqual(other.bundleID.utf8) && bundlePath.utf8.elementsEqual(other.bundlePath.utf8) &&
        executablePath.utf8.elementsEqual(other.executablePath.utf8) && label.utf8.elementsEqual(other.label.utf8)
    }
    static func text(_ s: String, cap: Int) -> Bool {
        !s.isEmpty && s.utf8.count <= cap && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var valid: Bool {
        pid > 0 && sourceGeneration > 0 && launchNanoseconds > 0 &&
        Self.text(bundleID,cap:256) && Self.text(label,cap:128) &&
        Self.text(bundlePath,cap:4_096) && Self.text(executablePath,cap:4_096) &&
        bundlePath.hasPrefix("/") && executablePath.hasPrefix("/")
    }
    func matches(_ context: MeetingAudioIngress.Context) -> Bool {
        valid && source == context.source && sourceGeneration == context.sourceGeneration && captureEpoch == context.epoch
    }
}

public enum ApplicationAudioMode: Equatable, Sendable { case retainedRecording, accessAttempt }

/// Local operation evidence only. No native handles, status codes, messages or permission inference.
public struct ApplicationAudioAccessKey: Equatable, Sendable {
    public let binding: SelectedApplicationBinding, context: MeetingAudioIngress.Context, nonce: UUID
    public init(binding: SelectedApplicationBinding, context: MeetingAudioIngress.Context, nonce: UUID) {
        self.binding = binding; self.context = context; self.nonce = nonce
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.binding.exactlyMatches(rhs.binding) && lhs.context == rhs.context && lhs.nonce == rhs.nonce
    }
}
public struct ApplicationAudioAccessOutcome: Equatable, Sendable {
    public enum Permission: Equatable, Sendable { case unknown }
    public enum Phase: Equatable, Sendable { case factory, identity, resolve, tap, aggregate, listeners, readback, io, start, retirement }
    public enum Progress: Equatable, Sendable { case stoppedBeforeNativeStart, nativeStartReturned, failed(Phase) }
    public enum Disposition: Equatable, Sendable { case appOwnedRetired, heldOrUnknownCleanup }
    public let key: ApplicationAudioAccessKey, progress: Progress, disposition: Disposition
    public var permission: Permission { .unknown }
    public init(key: ApplicationAudioAccessKey, progress: Progress, disposition: Disposition) {
        self.key = key; self.progress = progress; self.disposition = disposition
    }
}

public struct ApplicationAudioRecording {
    public let task: Task<Void,Never>
    private let stop: () -> Void
    init(task: Task<Void,Never>, stop: @escaping () -> Void) { self.task = task; self.stop = stop }
    /// Acquisition fencing only. The owner separately joins task, then its ingress writer.
    public func requestStop() { stop() }
}
public enum ApplicationAudioStart { case notStarted, actual(ApplicationAudioRecording) }

/// No factory, AppKit, HAL, TCC, scratch or microphone lease on construction/validation.
@MainActor public final class MeetingApplicationAudioCapture {
    private let makeBottom: () -> ApplicationAudioBottom?
    private let makeConverter: (AVAudioFormat) -> MeetingPCMConverting?
    private var active: ApplicationAudioDriver?
    private let retainedFailure: () -> Void
    var hasActualTask: Bool { actualTask != nil }
    private var actualTask: Task<Void,Never>?
    public init() {
        retainedFailure = {}
        makeBottom = {
            guard #available(macOS 14.2, *) else { return nil }
            return NativeApplicationAudioBottom()
        }
        makeConverter = { NativeMeetingConverter(format:$0) }
    }
    // Explicitly injected together: a fake can never fall through to a HAL/converter default.
    init(makeBottom: @escaping () -> ApplicationAudioBottom?,
         makeConverter: @escaping (AVAudioFormat) -> MeetingPCMConverting?, retainedFailure: @escaping () -> Void = {}) {
        self.makeBottom = makeBottom; self.makeConverter = makeConverter; self.retainedFailure = retainedFailure
    }
    public func validate(_ binding: SelectedApplicationBinding) -> Bool { binding.valid }
    public func validate(_ binding: SelectedApplicationBinding, context: MeetingAudioIngress.Context) -> Bool {
        binding.matches(context)
    }
    public func startSelectedApplication(binding: SelectedApplicationBinding, ingress: MeetingAudioIngress,
                                         enabled: Bool = false, mode: ApplicationAudioMode = .retainedRecording,
                                         attemptNonce: UUID = UUID(),
                                         outcome: (@MainActor (ApplicationAudioAccessOutcome) -> Void)? = nil) -> ApplicationAudioStart {
        guard enabled else { return .notStarted } // MUST remain first: even factory/OS checks follow this fence.
        guard active == nil,binding.matches(ingress.context) else { return .notStarted }
        let facts = ingress.facts
        guard facts.open,!facts.ended,!facts.bodyEntered,facts.slots == 2,facts.allocated == 2,
              facts.rawBytes == 1_920_088,facts.accepted == 0 else { return .notStarted }
        let driver = ApplicationAudioDriver(binding:binding,ingress:ingress,makeConverter:makeConverter,mode:mode,
            key:.init(binding:binding,context:ingress.context,nonce:attemptNonce))
        active = driver
        // MainActor task cannot run before this synchronous method registers its actual handle.
        let task = Task { @MainActor [self,driver] in
            await driver.run(makeBottom:makeBottom,retainedFailure:retainedFailure,outcome:outcome)
            active = nil; actualTask = nil
        }
        actualTask = task
        return .actual(.init(task:task,stop:{ [gate = driver.gate] in gate.close() }))
    }
}

// Fixed authored payload charge; not allocator, framework, service or RSS measurement.
struct ApplicationAudioPayloadCharge {
    static let slots = 1_920_088, writing = 960_044, converterInput = 65_536
    static let converterOutput = 131_072, handoff = 131_072, normalization = 65_536
    static let total = slots + writing + converterInput + converterOutput + handoff + normalization // 3,273,348
    let bytes = Self.total
}
struct ApplicationPCMFormat: Equatable {
    let rate: Double, channels: Int, interleaved: Bool
    init(_ f: AudioStreamBasicDescription) throws {
        let channels = Int(f.mChannelsPerFrame), interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian |
            (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved)
        guard MeetingAudioIngress.InputShape(rate:f.mSampleRate,channels:channels,frames:0).valid else { throw MeetingSession.Failure.bounds }
        let stride = UInt32(4 * (interleaved ? channels : 1))
        guard
              f.mFormatID == kAudioFormatLinearPCM,f.mFormatFlags == flags,f.mBitsPerChannel == 32,
              f.mFramesPerPacket == 1,f.mBytesPerFrame == stride,f.mBytesPerPacket == stride,f.mReserved == 0 else {
            throw MeetingSession.Failure.bounds
        }
        self.rate = f.mSampleRate; self.channels = channels; self.interleaved = interleaved
    }
    var asbd: AudioStreamBasicDescription {
        .init(mSampleRate:rate,mFormatID:kAudioFormatLinearPCM,
              mFormatFlags:kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian |
                (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
              mBytesPerPacket:UInt32(4 * (interleaved ? channels : 1)),mFramesPerPacket:1,
              mBytesPerFrame:UInt32(4 * (interleaved ? channels : 1)),mChannelsPerFrame:UInt32(channels),mBitsPerChannel:32,mReserved:0)
    }
    init(rate: Double, channels: Int, interleaved: Bool) throws {
        guard channels == 1 || channels == 2 else { throw MeetingSession.Failure.bounds }
        var f = AudioStreamBasicDescription()
        f.mSampleRate = rate; f.mFormatID = kAudioFormatLinearPCM
        f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian |
            (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved)
        f.mBytesPerFrame = UInt32(4 * max(1,interleaved ? channels : 1)); f.mBytesPerPacket = f.mBytesPerFrame
        f.mFramesPerPacket = 1; f.mChannelsPerFrame = UInt32(max(0,channels)); f.mBitsPerChannel = 32
        try self.init(f)
    }
}
/// Borrowed only until receive returns. Native IO has no ASBD argument: its verified stream
/// readback is frozen, with format/topology listeners fencing any later change.
struct ApplicationBorrowedPCM {
    let list: UnsafePointer<AudioBufferList>
    var declaredFormat: AudioStreamBasicDescription? = nil // typed malformed-shape fake seam
}

private final class ApplicationAudioPayload {
    let run: MeetingRecorderRun, charge = ApplicationAudioPayloadCharge()
    var format: ApplicationPCMFormat?, planarFormat: AVAudioFormat?, scratch: AVAudioPCMBuffer?
    var identity: NSRunningApplication?
    // Finite native-off actual listener body oracle, absent from production construction.
    var listenerBody: (() -> Void)?
    init(run: MeetingRecorderRun) { self.run = run }
    func prepare(_ f: ApplicationPCMFormat) throws {
        guard format == nil,let planar = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:f.rate,
                                                       channels:AVAudioChannelCount(f.channels),interleaved:false) else {
            throw MeetingSession.Failure.bounds
        }
        format = f; planarFormat = planar
    }
    func receive(_ borrowed: ApplicationBorrowedPCM) {
        guard let format else { run.requestStop(.invalidTail); return }
        do {
            if let declared = borrowed.declaredFormat,try ApplicationPCMFormat(declared) != format { throw MeetingSession.Failure.bounds }
            // Validate number before constructing a variable-length view, then all byte/stride
            // and finite sample facts before allocating or writing even one normalization sample.
            let count = format.interleaved ? 1 : format.channels
            guard borrowed.list.pointee.mNumberBuffers == UInt32(count) else { throw MeetingSession.Failure.bounds }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:borrowed.list))
            let stride = 4 * (format.interleaved ? format.channels : 1), bytes = Int(list[0].mDataByteSize)
            guard bytes % stride == 0 else { throw MeetingSession.Failure.bounds }
            let frames = bytes / stride
            guard (0...8_192).contains(frames) else { throw MeetingSession.Failure.bounds }
            for buffer in list {
                guard buffer.mNumberChannels == UInt32(format.interleaved ? format.channels : 1),
                      Int(buffer.mDataByteSize) == bytes,(frames == 0 || buffer.mData != nil) else { throw MeetingSession.Failure.bounds }
                if frames > 0 {
                    guard let p = buffer.mData,Int(bitPattern:p) % MemoryLayout<Float>.alignment == 0 else { throw MeetingSession.Failure.bounds }
                    let samples = UnsafeBufferPointer(start:p.assumingMemoryBound(to:Float.self),count:bytes/4)
                    guard samples.allSatisfy(\.isFinite) else { throw MeetingSession.Failure.bounds }
                }
            }
            guard frames > 0 else { return } // zero input never allocates scratch/converter
            guard run.ingress.facts.open else { run.requestStop(); return }
            if scratch == nil {
                guard let planarFormat,let created = AVAudioPCMBuffer(pcmFormat:planarFormat,frameCapacity:8_192) else {
                    throw MeetingSession.Failure.unavailable
                }
                scratch = created // <=8,192*2*4, fixed regardless of borrowed allocation capacity
            }
            guard let scratch,let channels = scratch.floatChannelData else { throw MeetingSession.Failure.unavailable }
            for channel in 0..<format.channels {
                let source = list[format.interleaved ? 0 : channel].mData!.assumingMemoryBound(to:Float.self)
                for frame in 0..<frames { channels[channel][frame] = source[format.interleaved ? frame*format.channels+channel : frame] }
            }
            scratch.frameLength = AVAudioFrameCount(frames)
            run.gate.receive(scratch) // reuse the existing bounded converter/handoff/ingress path
        } catch { run.requestStop(.invalidTail) }
    }
}

/// OS blocks retain only this gate. Retired callbacks refuse before evaluating inspect,
/// format, normalization scratch, live identity, listener hooks or the existing run.
final class ApplicationAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var payload: ApplicationAudioPayload?
    let mode: ApplicationAudioMode
    private var closed = false, armed = false, fenced = false, pcm = 0, listeners = 0, controls = 0, fencing = 0
    private var concern: MeetingSession.Reason?
    private var stopWaiter: CheckedContinuation<Void,Never>?, bodyWaiter: CheckedContinuation<Void,Never>?
    init(ingress: MeetingAudioIngress, makeConverter: @escaping (AVAudioFormat) -> MeetingPCMConverting?,
         mode: ApplicationAudioMode = .retainedRecording) {
        self.mode = mode
        payload = ApplicationAudioPayload(run:.init(ingress:ingress,makeConverter:makeConverter))
    }
    var isClosed: Bool { lock.withLock { closed } }
    func requireOpen() throws { if isClosed { throw MeetingSession.Failure.stale } }
    func prepare(_ format: ApplicationPCMFormat) throws {
        let p = lock.withLock { payload }; guard let p else { throw MeetingSession.Failure.stale }
        if mode == .accessAttempt {
            guard p.format == nil else { throw MeetingSession.Failure.stale }
            p.format = format // control metadata only; no planar format or sample storage
        } else { try p.prepare(format) } // retained preparation is unchanged
    }
    func bindIdentity(_ identity: NSRunningApplication?) { lock.withLock { payload?.identity = identity } }
    func setListenerBody(_ body: (() -> Void)?) { lock.withLock { payload?.listenerBody = body } }
    func arm() throws { try lock.withLock { guard mode == .retainedRecording,!closed,payload?.format != nil,payload?.charge.bytes == 3_273_348 else { throw MeetingSession.Failure.stale }; armed = true } }
    var pcmFacts: (armed: Bool, bodies: Int, formatStorage: Bool, scratch: Bool, payload: Bool) {
        lock.withLock { (armed,pcm,payload?.planarFormat != nil,payload?.scratch != nil,payload != nil) }
    }
    func close(_ reason: MeetingSession.Reason? = nil) {
        let entry = lock.withLock { () -> (Bool,MeetingRecorderRun?) in
            closed = true
            if let reason { concern = concern ?? reason }
            guard !fenced else { return (false,nil) }
            fenced = true; fencing = 1; return (true,payload?.run)
        }
        // At most one coalesced fence body can retain the run. It is included in joins;
        // repeated/copied stop requests retain no payload and cannot queue more work.
        if entry.0 { entry.1?.requestStop(reason); leave(.fence) }
    }
    func receive(_ inspect: () -> ApplicationBorrowedPCM) {
        guard mode == .retainedRecording else { return } // immutable fence BEFORE payload/body/lazy sample inspection
        let entry = lock.withLock { () -> (ApplicationAudioPayload,Bool)? in
            guard !closed,armed,let payload,pcm < 2 else { return nil }
            let primary = pcm == 0; pcm += 1
            if !primary { closed = true }
            return (payload,primary)
        }
        guard let (p,primary) = entry else { return }
        defer { leave(.pcm) }
        guard primary else { close(.unknownCoverage); return }
        p.receive(inspect())
        // Shape/converter/ingress refusals in the existing run coalesce to this same stop.
        if p.run.gate.isClosed || !p.run.ingress.facts.open { close(p.run.gate.reason) }
    }
    func changed(_ inspect: () -> Bool = { true }) { listener { _ in inspect() } }
    func terminated(_ notification: Notification) {
        listener { payload in
            guard let exact = payload.identity,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return true }
            return exact.isEqual(app)
        }
    }
    private func listener(_ inspect: (ApplicationAudioPayload) -> Bool) {
        let p = lock.withLock { () -> ApplicationAudioPayload? in
            guard !closed,listeners == 0,let payload else { return nil }; listeners = 1; return payload
        }
        guard let p else { return }; defer { leave(.listener) }
        p.listenerBody?()
        if inspect(p) { close(.unknownCoverage) }
    }
    private enum Body { case pcm, listener, control, fence }
    func beginControl() { lock.withLock { precondition(controls == 0); controls = 1 } }
    func endControl() { leave(.control) }
    private func leave(_ body: Body) {
        let waiters = lock.withLock { () -> (CheckedContinuation<Void,Never>?,CheckedContinuation<Void,Never>?) in
            switch body { case .pcm: precondition(pcm > 0); pcm -= 1
            case .listener: precondition(listeners == 1); listeners = 0
            case .control: precondition(controls == 1); controls = 0
            case .fence: precondition(fencing == 1); fencing = 0 }
            var stop: CheckedContinuation<Void,Never>?, bodies: CheckedContinuation<Void,Never>?
            if closed && fenced && fencing == 0 { stop = stopWaiter; stopWaiter = nil }
            if pcm == 0 && listeners == 0 && controls == 0 && fencing == 0 { bodies = bodyWaiter; bodyWaiter = nil }
            return (stop,bodies)
        }; waiters.0?.resume(); waiters.1?.resume()
    }
    func waitForStop() async {
        await withCheckedContinuation { c in
            let ready = lock.withLock { () -> Bool in if closed && fenced && fencing == 0 { return true }; precondition(stopWaiter == nil); stopWaiter = c; return false }
            if ready { c.resume() }
        }
    }
    func waitForBodies() async {
        await withCheckedContinuation { c in
            let ready = lock.withLock { () -> Bool in
                if pcm == 0 && listeners == 0 && controls == 0 && fencing == 0 { return true }
                precondition(bodyWaiter == nil); bodyWaiter = c; return false
            }; if ready { c.resume() }
        }
    }
    func waitForRunBodies() async {
        let p = lock.withLock { payload }; await p?.run.gate.waitForBodies()
    }
    /// Called on the serial control worker after all accepted PCM/listener bodies exit.
    func finishConverter() -> Bool {
        let state = lock.withLock { (payload,concern) }
        state.0?.run.requestStop(state.1); return state.0?.run.finish() ?? false
    }
    func retire() {
        lock.withLock { precondition(closed && pcm == 0 && listeners == 0 && controls == 0 && fencing == 0); payload = nil }
    }

}

/// Closed, pure request boundary. Unsafe selection modes cannot produce a tap plan.
struct ApplicationAudioTapPlan: Equatable {
    let process: AudioObjectID
    private init(process: AudioObjectID) { self.process = process }
    var includedProcesses: [AudioObjectID] { [process] }
    var privateTap: Bool { true }
    var exclusive: Bool { false }
    var restore: Bool { false }
    var unmuted: Bool { true }
    var bundleIDs: [String] { [] }
    var physicalInputs: [AudioObjectID] { [] }
    static func select(_ processes: [AudioObjectID], privateTap: Bool = true, exclusive: Bool = false,
                       restore: Bool = false, unmuted: Bool = true, bundleIDs: [String] = [],
                       physicalInputs: [AudioObjectID] = []) -> Self? {
        guard processes.count == 1,processes[0] != kAudioObjectUnknown,privateTap,!exclusive,!restore,
              unmuted,bundleIDs.isEmpty,physicalInputs.isEmpty else { return nil }
        return .init(process:processes[0])
    }
}
struct ApplicationAudioRoute: Equatable { let id: AudioObjectID, uid: String }
struct ResolvedApplicationAudio: Equatable {
    let binding: SelectedApplicationBinding, process: AudioObjectID, routes: [ApplicationAudioRoute]
    var tapPlan: ApplicationAudioTapPlan? { .select([process]) }
    func exactlyMatches(_ other: Self) -> Bool {
        self == other && binding.exactlyMatches(other.binding) &&
        zip(routes,other.routes).allSatisfy { pair in pair.0.uid.utf8.elementsEqual(pair.1.uid.utf8) }
    }
    var valid: Bool {
        binding.valid && tapPlan != nil && (1...2).contains(routes.count) &&
        Set(routes.map(\.id)).count == routes.count && Set(routes.map(\.uid)).count == routes.count &&
        routes.allSatisfy { $0.id != kAudioObjectUnknown && SelectedApplicationBinding.text($0.uid,cap:4_096) }
    }
}
// Typed owned wrappers, confined to this backend. Each attempted native retirement is
// consumed once, including failure. No public raw-handle or retry interface exists.
final class ApplicationOwnedTap {
    let id: AudioObjectID; fileprivate let owner: UUID; var attempted = false
    fileprivate init(_ id: AudioObjectID, owner: UUID) { self.id = id; self.owner = owner }
}
final class ApplicationOwnedAggregate {
    let id: AudioObjectID; fileprivate let owner: UUID; var attempted = false
    fileprivate init(_ id: AudioObjectID, owner: UUID) { self.id = id; self.owner = owner }
}
final class ApplicationOwnedIO {
    let raw: AudioDeviceIOProcID?; var startAttempted = false, stopAttempted = false, removeAttempted = false
    fileprivate let owner: UUID
    fileprivate init(_ raw: AudioDeviceIOProcID?, owner: UUID) { self.raw = raw; self.owner = owner }
}
final class ApplicationOwnedListener {
    let object: AudioObjectID, block: AudioObjectPropertyListenerBlock
    let queue: DispatchQueue
    fileprivate let owner: UUID
    var address: AudioObjectPropertyAddress, attempted = false, registrationKnown = true
    fileprivate init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, owner: UUID, block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object; self.address = address; self.queue = queue; self.owner = owner; self.block = block
    }
}
final class ApplicationAudioResources: @unchecked Sendable {
    private let nonce = UUID()
    var identity: NSRunningApplication?, observer: NSObjectProtocol?
    var resolved: ResolvedApplicationAudio?, format: ApplicationPCMFormat?, tapUID: String?
    var inputStream: AudioObjectID?
    var tap: ApplicationOwnedTap?, aggregate: ApplicationOwnedAggregate?, io: ApplicationOwnedIO?
    var listeners: [ApplicationOwnedListener] = []
    var uncertain = false
    // Receipts are minted by the per-run ownership ledger, including partial creations.
    func ownTap(_ id: AudioObjectID) throws {
        guard tap == nil,id != kAudioObjectUnknown else { throw MeetingSession.Failure.stale }; tap = .init(id,owner:nonce)
    }
    func ownAggregate(_ id: AudioObjectID) throws {
        guard aggregate == nil,id != kAudioObjectUnknown else { throw MeetingSession.Failure.stale }; aggregate = .init(id,owner:nonce)
    }
    func ownIOProc(_ raw: AudioDeviceIOProcID?) throws {
        guard io == nil else { throw MeetingSession.Failure.stale }; io = .init(raw,owner:nonce)
    }
    @discardableResult func ownListener(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
                                       block: @escaping AudioObjectPropertyListenerBlock) throws -> ApplicationOwnedListener {
        guard listeners.count < 4,object != kAudioObjectUnknown else { throw MeetingSession.Failure.bounds }
        let result = ApplicationOwnedListener(object:object,address:address,queue:queue,owner:nonce,block:block)
        listeners.append(result); return result
    }
    func owns(_ value: ApplicationOwnedTap) -> Bool { value.owner == nonce }
    func owns(_ value: ApplicationOwnedAggregate) -> Bool { value.owner == nonce }
    func owns(_ value: ApplicationOwnedIO) -> Bool { value.owner == nonce }
    func owns(_ value: ApplicationOwnedListener) -> Bool { value.owner == nonce }
}
final class ApplicationAudioQueues: @unchecked Sendable {
    let control = DispatchQueue(label:"parla.selected-process.control")
    let pcm = DispatchQueue(label:"parla.selected-process.pcm")
    let listener = DispatchQueue(label:"parla.selected-process.listener")
    let observer = OperationQueue()
    init() { observer.maxConcurrentOperationCount = 1; observer.underlyingQueue = listener }
    func call(_ gate: ApplicationAudioGate, _ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
            control.async {
                gate.beginControl(); defer { gate.endControl() }
                do { try work(); c.resume() } catch { c.resume(throwing:error) }
            }
        }
    }
    func join(_ queue: DispatchQueue) async {
        await withCheckedContinuation { c in queue.async { c.resume() } }
    }
}
protocol ApplicationAudioBottom: AnyObject {
    @MainActor func bindIdentity(_ binding: SelectedApplicationBinding, owned: ApplicationAudioResources,
                                 gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws
    @MainActor func revalidateIdentity(_ binding: SelectedApplicationBinding, owned: ApplicationAudioResources) throws
    @MainActor func removeObserver(_ owned: ApplicationAudioResources)
    func resolve(_ binding: SelectedApplicationBinding) throws -> ResolvedApplicationAudio
    func createTap(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources) throws
    func createAggregate(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources) throws
    func installListeners(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources,
                          gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws
    /// Re-read the frozen input after every listener is installed, before any PCM admission.
    func revalidateInput(_ owned: ApplicationAudioResources) throws
    func installIOProc(_ owned: ApplicationAudioResources, gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws
    func start(_ owned: ApplicationAudioResources) throws
    func stop(_ owned: ApplicationAudioResources) throws
    func removeIOProc(_ owned: ApplicationAudioResources) throws
    func removeListeners(_ owned: ApplicationAudioResources) -> Bool
    func destroyAggregate(_ owned: ApplicationAudioResources) throws
    func destroyTap(_ owned: ApplicationAudioResources) throws
}

final class ApplicationAudioDriver: @unchecked Sendable {
    let gate: ApplicationAudioGate, owned = ApplicationAudioResources(), queues = ApplicationAudioQueues()
    private let binding: SelectedApplicationBinding
    private let mode: ApplicationAudioMode, key: ApplicationAudioAccessKey
    private var phase = ApplicationAudioAccessOutcome.Phase.factory
    private var progress = ApplicationAudioAccessOutcome.Progress.stoppedBeforeNativeStart
    private var heldClosure: CheckedContinuation<Void,Never>?
    init(binding: SelectedApplicationBinding, ingress: MeetingAudioIngress,
         makeConverter: @escaping (AVAudioFormat) -> MeetingPCMConverting?, mode: ApplicationAudioMode,
         key: ApplicationAudioAccessKey) {
        self.binding = binding; self.mode = mode; self.key = key
        gate = .init(ingress:ingress,makeConverter:makeConverter,mode:mode)
    }
    @MainActor func run(makeBottom: () -> ApplicationAudioBottom?, retainedFailure: () -> Void,
                        outcome: (@MainActor (ApplicationAudioAccessOutcome) -> Void)?) async {
        var bottom: ApplicationAudioBottom?
        do {
            try gate.requireOpen()
            guard let made = makeBottom() else { throw MeetingSession.Failure.unavailable }
            bottom = made
            if mode == .accessAttempt { try gate.requireOpen() }
            phase = .identity; try made.bindIdentity(binding,owned:owned,gate:gate,queues:queues)
            try await queues.call(gate) { [self] in
                try gate.requireOpen(); phase = .resolve; let plan = try made.resolve(binding)
                guard plan.valid,(mode == .accessAttempt ? plan.binding.exactlyMatches(binding) : plan.binding == binding) else { throw MeetingSession.Failure.stale }
                owned.resolved = plan
                try gate.requireOpen(); phase = .tap; try made.createTap(plan,owned:owned)
                try gate.requireOpen(); phase = .aggregate; try made.createAggregate(plan,owned:owned)
                guard let format = owned.format else { throw MeetingSession.Failure.bounds }
                if mode == .accessAttempt { try gate.requireOpen() }
                try gate.prepare(format)
                try gate.requireOpen(); phase = .listeners; try made.installListeners(plan,owned:owned,gate:gate,queues:queues)
            }
            try gate.requireOpen(); phase = .identity; try made.revalidateIdentity(binding,owned:owned)
            try await queues.call(gate) { [self] in
                try gate.requireOpen()
                phase = .resolve
                guard let plan = owned.resolved else { throw MeetingSession.Failure.stale }
                let current = try made.resolve(binding)
                guard (mode == .accessAttempt ? current.exactlyMatches(plan) : current == plan) else { throw MeetingSession.Failure.stale }
                if mode == .accessAttempt { try gate.requireOpen() }
                phase = .readback; try made.revalidateInput(owned)
                try gate.requireOpen()
                if mode == .retainedRecording { try gate.arm() } // access gates can never arm
                phase = .io; try made.installIOProc(owned,gate:gate,queues:queues)
                try gate.requireOpen(); phase = .start; try made.start(owned)
                progress = .nativeStartReturned
                if mode == .accessAttempt { gate.close() } // immediate fence on the SAME worker after actual return
            }
            if mode == .retainedRecording { await gate.waitForStop() }
        } catch {
            progress = gate.isClosed && phase != .start ? .stoppedBeforeNativeStart : .failed(phase)
            gate.close(.unknownCoverage)
        }
        gate.close()
        await gate.waitForStop() // the single in-flight fence has actually reached ingress before HAL stop
        if let bottom {
            // Every partial start follows this same actual task. No lock spans a native call.
            do {
                try await queues.call(gate) { [self] in
                    if owned.io != nil {
                        do { try bottom.stop(owned) } catch { owned.uncertain = true }
                        // If stop is uncertain, preserve the IO dependency instead of guessing it is safe to remove.
                        if !owned.uncertain { do { try bottom.removeIOProc(owned) } catch { owned.uncertain = true } }
                    }
                    if !bottom.removeListeners(owned) { owned.uncertain = true }
                }
            } catch { owned.uncertain = true }
            bottom.removeObserver(owned)
        }
        await queues.join(queues.pcm); await queues.join(queues.listener); await queues.join(queues.control)
        await gate.waitForBodies()
        if owned.uncertain { gate.close(.unknownCoverage) }
        await gate.waitForRunBodies()
        var finished = false
        do { try await queues.call(gate) { [self] in finished = gate.finishConverter() } }
        catch { owned.uncertain = true }
        await queues.join(queues.control); await gate.waitForBodies()
        if finished { gate.retire() } // sever scratch/run only after the EOS body actually returned
        if finished,!owned.uncertain,let bottom {
            do {
                try await queues.call(gate) { [self] in
                    if owned.aggregate != nil { try bottom.destroyAggregate(owned) }
                    if owned.tap != nil { try bottom.destroyTap(owned) }
                }
            } catch { owned.uncertain = true }
            await queues.join(queues.control); await gate.waitForBodies()
        }
        guard finished,!owned.uncertain else {
            // Cancellation/timeouts are not evidence of exit. Own all unresolved handles forever;
            // root must keep this actual task/hold unavailable, like MeetingRecorderRun.retainFailedClosure.
            if mode == .accessAttempt {
                let observed: ApplicationAudioAccessOutcome.Progress = progress == .nativeStartReturned ? .failed(.retirement) : progress
                outcome?(.init(key:key,progress:observed,disposition:.heldOrUnknownCleanup))
            }
            retainedFailure()
            await withCheckedContinuation { heldClosure = $0 }
            return
        }
        owned.identity = nil; owned.resolved = nil; owned.format = nil; owned.tapUID = nil; owned.inputStream = nil
        if mode == .accessAttempt { outcome?(.init(key:key,progress:progress,disposition:.appOwnedRetired)) }
        // Delivery is synchronous inside the original actual task. No owner/writer join here.
        // Native service exit is NOT established.
    }
}

@available(macOS 14.2, *)
private final class NativeApplicationAudioBottom: ApplicationAudioBottom {
    private func check(_ status: OSStatus) throws { guard status == noErr else { throw MeetingSession.Failure.unavailable } }
    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    /// Exact-size POD reads; no list enumeration, dynamic capacity growth or retry.
    private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        guard object != kAudioObjectUnknown else { throw MeetingSession.Failure.bounds }
        var a = address(selector,scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object,&a,0,nil,&size))
        guard size == UInt32(MemoryLayout<T>.size) else { throw MeetingSession.Failure.bounds }
        var result = initial
        try withUnsafeMutablePointer(to:&result) { try check(AudioObjectGetPropertyData(object,&a,0,nil,&size,$0)) }
        guard size == UInt32(MemoryLayout<T>.size) else { throw MeetingSession.Failure.bounds }
        return result
    }
    private func object(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> CFTypeRef {
        let unmanaged: Unmanaged<CFTypeRef>? = try read(id,selector,Optional<Unmanaged<CFTypeRef>>.none)
        guard let unmanaged else { throw MeetingSession.Failure.bounds }; return unmanaged.takeRetainedValue()
    }
    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, cap: Int) throws -> String {
        let value = try object(id,selector)
        guard CFGetTypeID(value) == CFStringGetTypeID() else { throw MeetingSession.Failure.bounds }
        let text = value as! CFString
        guard CFStringGetLength(text) <= cap else { throw MeetingSession.Failure.bounds }
        let result = text as String
        guard SelectedApplicationBinding.text(result,cap:cap) else { throw MeetingSession.Failure.bounds }; return result
    }
    private func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, cap: Int,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector,scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id,&a,0,nil,&size))
        let width = MemoryLayout<AudioObjectID>.size
        guard Int(size) % width == 0,Int(size)/width <= cap else { throw MeetingSession.Failure.bounds }
        if size == 0 { return [] }
        let expected = size
        var result = [AudioObjectID](repeating:kAudioObjectUnknown,count:Int(size)/width)
        try result.withUnsafeMutableBytes { try check(AudioObjectGetPropertyData(id,&a,0,nil,&size,$0.baseAddress!)) }
        guard size == expected,result.allSatisfy({ $0 != kAudioObjectUnknown }),Set(result).count == result.count else {
            throw MeetingSession.Failure.bounds
        }; return result
    }
    private func cfStrings(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, cap: Int) throws -> [String] {
        let value = try object(id,selector)
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { throw MeetingSession.Failure.bounds }
        let list = value as! CFArray
        guard CFArrayGetCount(list) <= cap else { throw MeetingSession.Failure.bounds }
        var result: [String] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list,i) else { throw MeetingSession.Failure.bounds }
            let element = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(element) == CFStringGetTypeID() else { throw MeetingSession.Failure.bounds }
            let s = element as! CFString
            guard CFStringGetLength(s) <= 4_096 else { throw MeetingSession.Failure.bounds }
            let text = s as String
            guard SelectedApplicationBinding.text(text,cap:4_096) else { throw MeetingSession.Failure.bounds }; result.append(text)
        }; return result
    }
    @MainActor func bindIdentity(_ binding: SelectedApplicationBinding, owned: ApplicationAudioResources,
                                 gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws {
        guard let app = NSRunningApplication(processIdentifier:binding.pid) else { throw MeetingSession.Failure.stale }
        owned.identity = app; try revalidateIdentity(binding,owned:owned); gate.bindIdentity(app)
        owned.observer = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,
                                                                           object:nil,queue:queues.observer) { [gate] notice in
            gate.terminated(notice)
        }
        try revalidateIdentity(binding,owned:owned) // observer installation gap also refuses
    }
    @MainActor func revalidateIdentity(_ b: SelectedApplicationBinding, owned: ApplicationAudioResources) throws {
        guard b.valid,let exact = owned.identity,let live = NSRunningApplication(processIdentifier:b.pid),exact.isEqual(live),
              !exact.isTerminated,exact.processIdentifier == b.pid,exact.bundleIdentifier == b.bundleID,
              let bundle = exact.bundleURL,let executable = exact.executableURL,bundle.isFileURL,executable.isFileURL,
              bundle.path == b.bundlePath,executable.path == b.executablePath,let launched = exact.launchDate,
              try MeetingSession.nanoseconds(seconds:launched.timeIntervalSince1970) == b.launchNanoseconds else {
            throw MeetingSession.Failure.stale
        }
    }
    @MainActor func removeObserver(_ owned: ApplicationAudioResources) {
        if let observer = owned.observer { NSWorkspace.shared.notificationCenter.removeObserver(observer); owned.observer = nil }
    }
    func resolve(_ b: SelectedApplicationBinding) throws -> ResolvedApplicationAudio {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject), pid = b.pid, process = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try withUnsafePointer(to:&pid) { qualifier in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,
                                                 UInt32(MemoryLayout<Int32>.size),qualifier,&size,&process))
        }
        guard size == UInt32(MemoryLayout<AudioObjectID>.size),process != kAudioObjectUnknown,
              try read(process,kAudioProcessPropertyPID,Int32(0)) == b.pid,
              try string(process,kAudioProcessPropertyBundleID,cap:256) == b.bundleID,
              try read(process,kAudioProcessPropertyIsRunningOutput,UInt32(0)) == 1 else { throw MeetingSession.Failure.stale }
        let devices = try ids(process,kAudioProcessPropertyDevices,cap:2,scope:kAudioObjectPropertyScopeOutput)
        // Native v1 refuses multiple routes rather than exceed four exact listeners.
        // The value/fake boundary remains capped at two; no helper/device discovery.
        guard devices.count == 1 else { throw MeetingSession.Failure.bounds }
        let routes = try devices.map { id -> ApplicationAudioRoute in
            guard try read(id,kAudioDevicePropertyDeviceIsAlive,UInt32(0)) == 1 else { throw MeetingSession.Failure.stale }
            return .init(id:id,uid:try string(id,kAudioDevicePropertyDeviceUID,cap:4_096))
        }
        let plan = ResolvedApplicationAudio(binding:b,process:process,routes:routes)
        guard plan.valid else { throw MeetingSession.Failure.bounds }; return plan
    }
    func createTap(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources) throws {
        guard plan.valid,let selection = plan.tapPlan,owned.tap == nil else { throw MeetingSession.Failure.stale }
        let description = CATapDescription(stereoMixdownOfProcesses:selection.includedProcesses)
        description.isPrivate = selection.privateTap; description.isExclusive = selection.exclusive; description.muteBehavior = .unmuted
        if #available(macOS 26.0, *) {
            description.isProcessRestoreEnabled = selection.restore; description.bundleIDs = selection.bundleIDs
            guard !description.isProcessRestoreEnabled,description.bundleIDs.isEmpty else { throw MeetingSession.Failure.bounds }
        }
        guard description.processes == [plan.process],description.isPrivate,!description.isExclusive,
              description.muteBehavior == .unmuted else { throw MeetingSession.Failure.bounds }
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(description,&id)
        if id != kAudioObjectUnknown { try owned.ownTap(id) }
        guard status == noErr,id != kAudioObjectUnknown else {
            owned.uncertain = true; throw MeetingSession.Failure.unavailable
        }
        do {
            guard id != plan.process,!plan.routes.contains(where:{ $0.id == id }),
                  try read(id,kAudioObjectPropertyClass,AudioClassID(0)) == kAudioTapClassID else { throw MeetingSession.Failure.bounds }
        } catch { owned.uncertain = true; throw error }
        owned.tapUID = try string(id,kAudioTapPropertyUID,cap:4_096)
        owned.format = try ApplicationPCMFormat(read(id,kAudioTapPropertyFormat,AudioStreamBasicDescription()))
    }
    func createAggregate(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources) throws {
        guard let tap = owned.tap,owned.owns(tap),let uid = owned.tapUID,let format = owned.format,owned.aggregate == nil else {
            throw MeetingSession.Failure.stale
        }
        // No physical subdevice, default-device selector or global source. If a tap-only
        // composition cannot prove this exact topology on a host, refuse; never add a mic.
        let spec: [String:NSObject] = [
            kAudioAggregateDeviceUIDKey:UUID().uuidString as NSString,
            kAudioAggregateDeviceNameKey:"Parla selected process" as NSString,
            kAudioAggregateDeviceIsPrivateKey:NSNumber(value:true),
            kAudioAggregateDeviceTapAutoStartKey:NSNumber(value:false),
            kAudioAggregateDeviceSubDeviceListKey:NSArray(),
            kAudioAggregateDeviceTapListKey:NSArray(object:[kAudioSubTapUIDKey:uid] as NSDictionary)
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(spec as CFDictionary,&id)
        if id != kAudioObjectUnknown { try owned.ownAggregate(id) }
        guard status == noErr,id != kAudioObjectUnknown else { owned.uncertain = true; throw MeetingSession.Failure.unavailable }
        do {
            guard id != tap.id,id != plan.process,!plan.routes.contains(where:{ $0.id == id }),
                  try read(id,kAudioObjectPropertyClass,AudioClassID(0)) == kAudioAggregateDeviceClassID else { throw MeetingSession.Failure.bounds }
        } catch { owned.uncertain = true; throw error }
        try verifyPrivateComposition(id)
        guard try cfStrings(id,kAudioAggregateDevicePropertyFullSubDeviceList,cap:0).isEmpty,
              try ids(id,kAudioAggregateDevicePropertyActiveSubDeviceList,cap:0).isEmpty,
              try cfStrings(id,kAudioAggregateDevicePropertyTapList,cap:1) == [uid],
              try read(id,kAudioDevicePropertyDeviceIsAlive,UInt32(0)) == 1,
              try ApplicationPCMFormat(read(tap.id,kAudioTapPropertyFormat,AudioStreamBasicDescription())) == format else {
            throw MeetingSession.Failure.bounds
        }
        let streams = try ids(id,kAudioDevicePropertyStreams,cap:1,scope:kAudioObjectPropertyScopeInput)
        guard streams.count == 1,
              try ApplicationPCMFormat(read(streams[0],kAudioStreamPropertyVirtualFormat,AudioStreamBasicDescription())) == format else {
            throw MeetingSession.Failure.bounds
        }
        owned.inputStream = streams[0]
        try verifyInputConfiguration(id,format)
        // A capture-only aggregate must have no output stream we would need to fill.
        guard try ids(id,kAudioDevicePropertyStreams,cap:0,scope:kAudioObjectPropertyScopeOutput).isEmpty else {
            throw MeetingSession.Failure.bounds
        }
    }
    private func verifyPrivateComposition(_ id: AudioObjectID) throws {
        let value = try object(id,kAudioAggregateDevicePropertyComposition)
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else { throw MeetingSession.Failure.bounds }
        let dictionary = value as! NSDictionary
        guard dictionary.count <= 8 else { throw MeetingSession.Failure.bounds }
        guard let privateValue = dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber,privateValue.intValue == 1,
              let automatic = dictionary[kAudioAggregateDeviceTapAutoStartKey] as? NSNumber,automatic.intValue == 0 else {
            throw MeetingSession.Failure.bounds
        }
    }
    private func verifyInputConfiguration(_ id: AudioObjectID, _ f: ApplicationPCMFormat) throws {
        var a = address(kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeInput), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id,&a,0,nil,&size))
        let count = f.interleaved ? 1 : f.channels
        let expected = MemoryLayout<AudioBufferList>.size + (count-1)*MemoryLayout<AudioBuffer>.stride
        guard size == UInt32(expected) else { throw MeetingSession.Failure.bounds }
        let raw = UnsafeMutableRawPointer.allocate(byteCount:expected,alignment:MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }; raw.initializeMemory(as:UInt8.self,repeating:0,count:expected)
        try check(AudioObjectGetPropertyData(id,&a,0,nil,&size,raw))
        guard size == UInt32(expected) else { throw MeetingSession.Failure.bounds }
        let pointer = raw.assumingMemoryBound(to:AudioBufferList.self)
        guard pointer.pointee.mNumberBuffers == UInt32(count) else { throw MeetingSession.Failure.bounds }
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        guard list.allSatisfy({ $0.mNumberChannels == UInt32(f.interleaved ? f.channels : 1) && $0.mData == nil }) else {
            throw MeetingSession.Failure.bounds
        }
    }
    func installListeners(_ plan: ResolvedApplicationAudio, owned: ApplicationAudioResources,
                          gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws {
        guard let aggregate = owned.aggregate,owned.owns(aggregate),owned.listeners.isEmpty else { throw MeetingSession.Failure.stale }
        guard let stream = owned.inputStream,plan.routes.count == 1 else { throw MeetingSession.Failure.bounds }
        // Four exact objects: chosen process, its sole route, owned aggregate and input
        // stream. Ignore ordinary start/running notifications generated by our own IO.
        // Relevant changes fence; no requery, retarget, polling or rebuild from a callback.
        for object in [plan.process,plan.routes[0].id,aggregate.id,stream] {
            try gate.requireOpen()
            let a = AudioObjectPropertyAddress(mSelector:kAudioObjectPropertySelectorWildcard,
                                              mScope:kAudioObjectPropertyScopeWildcard,mElement:kAudioObjectPropertyElementWildcard)
            let listener = try owned.ownListener(object:object,address:a,queue:queues.listener,block:{ [gate] count,addresses in
                gate.changed {
                    guard (1...16).contains(count) else { return true }
                    for i in 0..<Int(count) {
                        switch addresses[i].mSelector {
                        case kAudioProcessPropertyPID,kAudioProcessPropertyBundleID,kAudioProcessPropertyDevices,
                             kAudioProcessPropertyIsRunningOutput,kAudioDevicePropertyDeviceIsAlive,
                             kAudioDevicePropertyDeviceUID,kAudioDevicePropertyStreams,kAudioDevicePropertyStreamConfiguration,
                             kAudioDevicePropertyNominalSampleRate,kAudioStreamPropertyVirtualFormat,
                             kAudioAggregateDevicePropertyComposition,kAudioAggregateDevicePropertyTapList,
                             kAudioAggregateDevicePropertyActiveSubDeviceList,kAudioObjectPropertySelectorWildcard:
                            return true
                        case kAudioDevicePropertyDeviceIsRunning: continue // expected self-start/stop state only
                        default: return true // unknown notification is uncertainty, never retargeting
                        }
                    }
                    return false
                }
            })
            // Ownership receipt precedes even an uncertain registration result.
            let status = AudioObjectAddPropertyListenerBlock(object,&listener.address,listener.queue,listener.block)
            guard status == noErr else {
                listener.registrationKnown = false; owned.uncertain = true; throw MeetingSession.Failure.unavailable
            }
        }
    }

    func revalidateInput(_ owned: ApplicationAudioResources) throws {
        guard let tap = owned.tap,owned.owns(tap),let aggregate = owned.aggregate,owned.owns(aggregate),
              let format = owned.format,let uid = owned.tapUID,let stream = owned.inputStream,
              stream != kAudioObjectUnknown,owned.listeners.count == 4,
              owned.listeners.allSatisfy({ owned.owns($0) && $0.registrationKnown }) else {
            throw MeetingSession.Failure.stale
        }
        // Registration does not replay an earlier change. Compare with the original
        // admission; never adopt a new rate, stream or aggregate composition here.
        try verifyPrivateComposition(aggregate.id)
        guard try string(tap.id,kAudioTapPropertyUID,cap:4_096) == uid,
              try ApplicationPCMFormat(read(tap.id,kAudioTapPropertyFormat,AudioStreamBasicDescription())) == format,
              try cfStrings(aggregate.id,kAudioAggregateDevicePropertyFullSubDeviceList,cap:0).isEmpty,
              try ids(aggregate.id,kAudioAggregateDevicePropertyActiveSubDeviceList,cap:0).isEmpty,
              try cfStrings(aggregate.id,kAudioAggregateDevicePropertyTapList,cap:1) == [uid],
              try read(aggregate.id,kAudioDevicePropertyDeviceIsAlive,UInt32(0)) == 1,
              try ids(aggregate.id,kAudioDevicePropertyStreams,cap:1,scope:kAudioObjectPropertyScopeInput) == [stream],
              try ApplicationPCMFormat(read(stream,kAudioStreamPropertyVirtualFormat,AudioStreamBasicDescription())) == format,
              try ids(aggregate.id,kAudioDevicePropertyStreams,cap:0,scope:kAudioObjectPropertyScopeOutput).isEmpty else {
            throw MeetingSession.Failure.bounds
        }
        try verifyInputConfiguration(aggregate.id,format)
    }

    func installIOProc(_ owned: ApplicationAudioResources, gate: ApplicationAudioGate, queues: ApplicationAudioQueues) throws {
        guard let aggregate = owned.aggregate,owned.owns(aggregate),owned.io == nil else { throw MeetingSession.Failure.stale }
        var raw: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&raw,aggregate.id,queues.pcm) { [gate] _,input,_,_,_ in
            gate.receive { .init(list:input) } // borrowed list never escapes this synchronous body
        }
        try owned.ownIOProc(raw)
        guard status == noErr,raw != nil else { owned.uncertain = true; throw MeetingSession.Failure.unavailable }
    }
    func start(_ owned: ApplicationAudioResources) throws {
        guard let aggregate = owned.aggregate,owned.owns(aggregate),let io = owned.io,owned.owns(io),let raw = io.raw,!io.startAttempted else { throw MeetingSession.Failure.stale }
        io.startAttempted = true; try check(AudioDeviceStart(aggregate.id,raw))
    }
    func stop(_ owned: ApplicationAudioResources) throws {
        guard let aggregate = owned.aggregate,owned.owns(aggregate),let io = owned.io,owned.owns(io),!io.stopAttempted else { throw MeetingSession.Failure.stale }
        io.stopAttempted = true
        guard let raw = io.raw else { throw MeetingSession.Failure.unavailable }
        if io.startAttempted { try check(AudioDeviceStop(aggregate.id,raw)) }
    }
    func removeIOProc(_ owned: ApplicationAudioResources) throws {
        guard let aggregate = owned.aggregate,owned.owns(aggregate),let io = owned.io,owned.owns(io),let raw = io.raw,!io.removeAttempted else { throw MeetingSession.Failure.stale }
        io.removeAttempted = true; try check(AudioDeviceDestroyIOProcID(aggregate.id,raw)); owned.io = nil
    }
    func removeListeners(_ owned: ApplicationAudioResources) -> Bool {
        var known = true
        for listener in owned.listeners {
            guard owned.owns(listener),!listener.attempted else { known = false; continue }; listener.attempted = true
            guard listener.registrationKnown else { known = false; continue }
            if AudioObjectRemovePropertyListenerBlock(listener.object,&listener.address,listener.queue,listener.block) != noErr { known = false }
        }
        if known { owned.listeners.removeAll() }; return known
    }
    func destroyAggregate(_ owned: ApplicationAudioResources) throws {
        guard let aggregate = owned.aggregate,owned.owns(aggregate),!aggregate.attempted,owned.io == nil,owned.listeners.isEmpty else {
            throw MeetingSession.Failure.stale
        }
        aggregate.attempted = true; try check(AudioHardwareDestroyAggregateDevice(aggregate.id)); owned.aggregate = nil
        // API acknowledges a destruction request; actual HAL destruction is asynchronous/unknown.
    }
    func destroyTap(_ owned: ApplicationAudioResources) throws {
        guard let tap = owned.tap,owned.owns(tap),!tap.attempted,owned.aggregate == nil else { throw MeetingSession.Failure.stale }
        tap.attempted = true; try check(AudioHardwareDestroyProcessTap(tap.id)); owned.tap = nil
    }
}
