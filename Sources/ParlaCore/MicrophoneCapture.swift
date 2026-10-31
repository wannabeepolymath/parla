import AVFoundation

/// Local UI only. Never part of DiagnosticRecord, settings, logging or export.
public struct MicrophoneRoute: Equatable {
    public let name: String?
    public let fallback: Bool?
    public init(name: String? = nil, fallback: Bool? = nil) { self.name = name; self.fallback = fallback }
}

/// Injected engine seam. The production recorder uses its existing AUHAL engine;
/// fixtures supply PCM through the very same resampler/tap path without opening a device.
public protocol MicrophoneCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    var route: MicrophoneRoute { get }
    func start(requestedUID: String?, receive: @escaping (AVAudioPCMBuffer) -> Void,
               changed: @escaping () -> Void) throws
    func stop()
}

public struct MicrophoneCaptureSnapshot {
    public let facts: CaptureDiagnosticState?
    public let route: MicrophoneRoute
    public let sampleCount: Int
    public let level: Float
    public let hasSignal: Bool
    public let conversionFailures: Int
    public let ended: AudioRecorder.EndReason?
}

public protocol MicrophoneTestCapturing: AnyObject {
    func start(operation: UUID, lease: CaptureAdmission.Lease) throws
    func snapshot(operation: UUID) -> MicrophoneCaptureSnapshot?
    func stop(operation: UUID) -> [Float]
    func clear(operation: UUID)
}

/// No audio copy is kept here. Stop transfers the recorder's bounded buffer.
public final class RecorderMicrophoneCapture: MicrophoneTestCapturing {
    public let recorder: AudioRecorder
    public init(recorder: AudioRecorder) { self.recorder = recorder }
    public func start(operation: UUID, lease: CaptureAdmission.Lease) throws { try recorder.startMicrophoneTest(operation: operation, lease: lease) }
    public func snapshot(operation: UUID) -> MicrophoneCaptureSnapshot? { recorder.microphoneTestSnapshot(operation: operation) }
    public func stop(operation: UUID) -> [Float] { recorder.stopMicrophoneTest(operation: operation) }
    public func clear(operation: UUID) { recorder.clearMicrophoneTest(operation: operation) }
}


public struct GuidedCaptureResult {
    public let samples: [Float]
    public let route: MicrophoneRoute
    public let complete: Bool
    public init(samples: [Float], route: MicrophoneRoute, complete: Bool) {
        self.samples = samples; self.route = route; self.complete = complete
    }
}

public protocol GuidedTemplateCapturing: AnyObject {
    func reserve(session: UUID, lease: CaptureAdmission.Lease) throws
    func start(session: UUID, capture: UUID, lease: CaptureAdmission.Lease, inputUID: String?) throws
    func stop(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) -> GuidedCaptureResult?
    func clear(session: UUID, capture: UUID, lease: CaptureAdmission.Lease)
    func release(session: UUID, lease: CaptureAdmission.Lease)
}

/// Uses the one production recorder; never borrows the B55 or ordinary handoff.
public final class RecorderGuidedTemplateCapture: GuidedTemplateCapturing {
    public let recorder: AudioRecorder
    public init(recorder: AudioRecorder) { self.recorder = recorder }
    public func reserve(session: UUID, lease: CaptureAdmission.Lease) throws { try recorder.reserveGuidedTemplate(session: session, lease: lease) }
    public func start(session: UUID, capture: UUID, lease: CaptureAdmission.Lease, inputUID: String?) throws {
        try recorder.startGuidedTemplate(session: session, capture: capture, lease: lease, inputUID: inputUID)
    }
    public func stop(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) -> GuidedCaptureResult? {
        recorder.stopGuidedTemplate(session: session, capture: capture, lease: lease)
    }
    public func clear(session: UUID, capture: UUID, lease: CaptureAdmission.Lease) { recorder.clearGuidedTemplate(session: session, capture: capture, lease: lease) }
    public func release(session: UUID, lease: CaptureAdmission.Lease) { recorder.releaseGuidedTemplate(session: session, lease: lease) }
}

// Meeting-only streaming path. None of these initializers opens native input.
public struct MeetingConversionStep {
    public enum Status: Equatable { case inputExhausted, haveData, endOfStream, failed }
    public let frames: Int, status: Status
    public init(frames: Int, status: Status) { self.frames = frames; self.status = status }
}

/// Implementations write at most output.count samples, retain no supplied tap buffer,
/// and own at most the native adapter's fixed scratch envelope. Calls are serialized.
/// Fixtures replace this bottom seam as well as MicrophoneCaptureEngine.
public protocol MeetingPCMConverting: AnyObject {
    func feed(_ input: AVAudioPCMBuffer, output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep
    func finish(output: UnsafeMutableBufferPointer<Float>) -> MeetingConversionStep
}

public struct MeetingMicrophoneRecording {
    public let task: Task<Void,Never>
    private let stop: () -> Void
    init(task: Task<Void,Never>, stop: @escaping () -> Void) { self.task = task; self.stop = stop }
    /// Acquisition acknowledgement only; task.value is the separate actual app-owned join.
    public func requestStop() { stop() }
}

public enum MeetingMicrophoneStart {
    case notStarted
    case actual(MeetingMicrophoneRecording)
}

/// Copied engine closures keep only this inert generation gate. Its payload is removed
/// after entered bodies exit. A refused late callback cannot even read the buffer format.
final class MeetingSourceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var payload: MeetingRecorderRun?
    private var closed = false, entered = 0
    private var stopWaiter: CheckedContinuation<Void,Never>?, exitWaiter: CheckedContinuation<Void,Never>?
    private var concern: MeetingSession.Reason?
    func bind(_ run: MeetingRecorderRun) { lock.withLock { precondition(payload == nil); payload = run } }
    func enter() -> (MeetingRecorderRun,Bool)? {
        lock.withLock {
            guard !closed,let payload else { return nil }
            let primary = entered == 0
            entered += 1
            // At most one PCM body and one overlapping refusal body. Never queue PCM.
            if !primary { closed = true; concern = concern ?? .unknownCoverage }
            return (payload,primary)
        }
    }
    func leave() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void,Never>? in
            precondition(entered > 0); entered -= 1
            guard entered == 0 else { return nil }
            let waiter = exitWaiter; exitWaiter = nil; return waiter
        }
        waiter?.resume()
    }
    func close(_ why: MeetingSession.Reason? = nil) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void,Never>? in
            closed = true; if let why { concern = concern ?? why }
            let waiter = stopWaiter; stopWaiter = nil; return waiter
        }
        waiter?.resume()
    }
    var reason: MeetingSession.Reason? { lock.withLock { concern } }
    var isClosed: Bool { lock.withLock { closed } }
    func waitForStop() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if closed { return true }; precondition(stopWaiter == nil); stopWaiter = continuation; return false
            }
            if ready { continuation.resume() }
        }
    }
    func waitForBodies() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if entered == 0 { return true }; precondition(exitWaiter == nil); exitWaiter = continuation; return false
            }
            if ready { continuation.resume() }
        }
    }
    func retire() { lock.withLock { precondition(closed && entered == 0); payload = nil } }
    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let (run,primary) = enter() else { return }
        defer { leave() }
        if primary { run.receive(buffer) }
        else { run.requestStop(.unknownCoverage) }
    }
    func changed() {
        guard let (run,_) = enter() else { return }
        defer { leave() }; run.requestStop(.unknownCoverage)
    }
}

/// Owns only one bounded handoff, one persistent converter and scalar source state.
/// No native tap buffer, whole-session array, per-buffer task, timestamp or ordinary hook.
final class MeetingRecorderRun: @unchecked Sendable {
    static let outputFrames = 32_768, drainCalls = 4
    let ingress: MeetingAudioIngress, gate = MeetingSourceGate()
    private let makeConverter: (AVAudioFormat) -> MeetingPCMConverting?
    private var converter: MeetingPCMConverting?, format: AVAudioFormat?
    private var handoff: UnsafeMutablePointer<Float>?
    private var convertedInput = false
    // Only used for a closure invariant failure. It intentionally cannot manufacture actual exit.
    private var heldClosure: CheckedContinuation<Void,Never>?
    init(ingress: MeetingAudioIngress, makeConverter: @escaping (AVAudioFormat) -> MeetingPCMConverting?) {
        self.ingress = ingress; self.makeConverter = makeConverter; gate.bind(self)
    }
    deinit { handoff?.deallocate() }
    func requestStop(_ reason: MeetingSession.Reason? = nil) {
        // Never hold gate.lock while entering ingress, or ingress.lock while resuming a waiter.
        ingress.fence(); gate.close(reason)
    }
    private func shape(_ buffer: AVAudioPCMBuffer) -> MeetingAudioIngress.InputShape? {
        let f = buffer.format, frames = Int(buffer.frameLength), channels = Int(f.channelCount)
        let shape = MeetingAudioIngress.InputShape(rate:f.sampleRate,channels:channels,frames:frames)
        guard shape.valid,f.commonFormat == .pcmFormatFloat32,!f.isInterleaved,
              buffer.frameLength <= buffer.frameCapacity,buffer.floatChannelData != nil else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard list.count == channels,list.allSatisfy({ $0.mNumberChannels == 1 && Int($0.mDataByteSize) >= frames*4 && (frames == 0 || $0.mData != nil) }) else { return nil }
        for channel in 0..<channels {
            let samples = UnsafeBufferPointer(start:buffer.floatChannelData![channel],count:frames)
            guard samples.allSatisfy(\.isFinite) else { return nil }
        }
        return shape
    }
    func receive(_ buffer: AVAudioPCMBuffer) {
        // enter is atomic with fence and rejects before inspecting source PCM/native format.
        guard let body = try? ingress.enter() else { requestStop(); return }
        defer { do { try ingress.leave(body) } catch { requestStop(.unknownCoverage) } }
        guard let shape = shape(buffer) else { requestStop(.invalidTail); return }
        guard shape.frames > 0 else { return } // no converter for empty input
        do {
            // Existing receive(empty) performs source-shape admission under ingress.lock.
            // Monotonic open observed afterwards proves that admission preceded any fence.
            // If fence won, never consume source input or allocate a converter.
            _ = try ingress.receive(body,canonical:.init(start:nil,count:0),input:shape)
            guard ingress.facts.open else { requestStop(); return }
            if let format,format != buffer.format { requestStop(.unknownCoverage); return }
            if converter == nil {
                guard let created = makeConverter(buffer.format) else { requestStop(.unknownCoverage); return }
                converter = created; format = buffer.format
                handoff = .allocate(capacity:Self.outputFrames)
            }
            guard let converter,let handoff else { requestStop(.unknownCoverage); return }
            convertedInput = true
            let step = converter.feed(buffer,output:.init(start:handoff,count:Self.outputFrames))
            guard (0...Self.outputFrames).contains(step.frames) else { requestStop(.invalidTail); return }
            guard step.status != .failed else { requestStop(.unknownCoverage); return }
            let pcm = UnsafeBufferPointer(start:handoff,count:step.frames)
            guard pcm.allSatisfy(\.isFinite) else { requestStop(.invalidTail); return }
            let accepted = try ingress.receive(body,canonical:pcm,input:shape)
            if accepted != pcm.count { requestStop(.unknownCoverage) }
            // A valid produced prefix survives even when full source consumption is unproved.
            if step.status != .inputExhausted { requestStop(.unknownCoverage) }
            if !ingress.facts.open { requestStop() }
        } catch { requestStop(.unknownCoverage) }
    }
    /// Runs only after native stop acknowledgement AND actual entered app body exit.
    /// A real endOfStream is required. Empty haveData/inputExhausted is not EOS proof.
    func finish() -> Bool {
        let drain = ingress.fence()
        var total = 0, terminal = !convertedInput, refusedTail = false
        if let converter,let handoff,convertedInput {
            for _ in 0..<Self.drainCalls {
                let room = Self.outputFrames-total
                guard room > 0 else { refusedTail = true; break }
                let step = converter.finish(output:.init(start:handoff.advanced(by:total),count:room))
                guard (0...room).contains(step.frames),
                      UnsafeBufferPointer(start:handoff.advanced(by:total),count:step.frames).allSatisfy(\.isFinite) else { refusedTail = true; break }
                total += step.frames
                if step.status == .endOfStream { terminal = true; break }
                if step.status == .failed { refusedTail = true; break }
            }
        }
        let reason = gate.reason
        let closure: MeetingAudioIngress.Closure = terminal && !refusedTail && reason == nil ? .complete : .unknown(reason ?? .unknownCoverage)
        // An uncertain drain's unproved tail is refused wholesale, never a fake marker.
        let tail = UnsafeBufferPointer(start:handoff,count:terminal && !refusedTail && reason == nil ? total : 0)
        do {
            _ = try ingress.end(drain,tail:tail,closure:closure)
            converter = nil; format = nil; handoff?.deallocate(); handoff = nil
            gate.retire(); return true
        } catch { return false }
    }
    func retainFailedClosure() async {
        await withCheckedContinuation { continuation in heldClosure = continuation }
    }
}
