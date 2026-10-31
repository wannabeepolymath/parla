import Foundation

/// Canonical PCM ingress only; no engine, clock, converter, storage or source task is constructed here.
public final class MeetingAudioIngress: @unchecked Sendable {
    public struct Context: Equatable, Sendable {
        public let session: UUID, ownerGeneration: UInt64, source: UUID, sourceGeneration: UInt64, segment: UUID, epoch: UUID
        public init(session: UUID, ownerGeneration: UInt64, source: UUID, sourceGeneration: UInt64, segment: UUID, epoch: UUID) {
            self.session = session; self.ownerGeneration = ownerGeneration; self.source = source
            self.sourceGeneration = sourceGeneration; self.segment = segment; self.epoch = epoch
        }
    }
    public struct Permit: Equatable, Sendable {
        fileprivate let nonce: UUID, context: Context
        public let id: UUID, slot: UInt64
    }
    public struct Body: Equatable, Sendable { fileprivate let nonce: UUID, serial: UInt64 }
    public struct Drain: Equatable, Sendable { fileprivate let nonce: UUID, permits: [Permit] }
    /// Explicit converter disposition; no fabricated samples are needed to close an uncertain source.
    public enum Closure: Sendable { case complete, unknown(MeetingSession.Reason) }
    public struct InputShape: Sendable {
        public let rate: Double, channels: Int, frames: Int
        public init(rate: Double, channels: Int, frames: Int) { self.rate = rate; self.channels = channels; self.frames = frames }
        public var valid: Bool { rate.isFinite && rate.rounded(.towardZero) == rate && (8_000...192_000).contains(rate) && (channels == 1 || channels == 2) && (0...8_192).contains(frames) }
    }
    public struct Delivery: Sendable {
        public let permit: Permit, start: UInt64, sequence: UInt64, frames: UInt64, bytes: Data
    }
    public struct Facts: Equatable, Sendable {
        public let open: Bool, ended: Bool, bodyEntered: Bool, unknown: Bool, reason: MeetingSession.Reason?
        public let slots: Int, allocated: UInt64, accepted: UInt64, rawBytes: Int, snapshotBytes: Int, copies: UInt64
        public var producerFinished: Bool { ended && !bodyEntered }
        public var settled: Bool { producerFinished && slots == 0 }
    }
    private enum Mode { case active, standby, frozen, writing }
    private final class Buffer {
        let permit: Permit, memory: UnsafeMutableRawPointer
        var mode: Mode, frames = 0, start: UInt64 = 0, sequence: UInt64 = 0
        init(_ permit: Permit, mode: Mode, start: UInt64) {
            self.permit = permit; self.mode = mode; self.start = start
            memory = .allocate(byteCount:MeetingSession.sourceBytes,alignment:2)
        }
        deinit { memory.deallocate() }
        func word(_ value: UInt16, at offset: Int) {
            memory.storeBytes(of:UInt8(truncatingIfNeeded:value),toByteOffset:offset,as:UInt8.self)
            memory.storeBytes(of:UInt8(truncatingIfNeeded:value >> 8),toByteOffset:offset+1,as:UInt8.self)
        }
        func wav() -> Data {
            func little(_ value: UInt32, _ offset: Int, _ width: Int) {
                for i in 0..<width { memory.storeBytes(of:UInt8(truncatingIfNeeded:value >> (8*i)),toByteOffset:offset+i,as:UInt8.self) }
            }
            for (offset,string) in [(0,"RIFF"),(8,"WAVEfmt "),(36,"data")] {
                for (i,c) in string.utf8.enumerated() { memory.storeBytes(of:c,toByteOffset:offset+i,as:UInt8.self) }
            }
            little(UInt32(36+frames*2),4,4); little(16,16,4); little(1,20,2); little(1,22,2)
            little(16_000,24,4); little(32_000,28,4); little(2,32,2); little(16,34,2); little(UInt32(frames*2),40,4)
            return Data(bytes:memory,count:44+frames*2) // sole authored immutable snapshot; no freeze clone
        }
    }
    public let context: Context, events: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation, lock = NSLock(), nonce = UUID()
    private var buffers: [Buffer] = [], usedIDs = Set<UUID>(), allocated: UInt64 = 0, accepted: UInt64 = 0, sequence: UInt64 = 0
    private var started = false, open = false, ended = false, unknown = false, revoked = false, eventFinished = false
    private var reason: MeetingSession.Reason?, drain: Drain?, body: Body?, bodySerial: UInt64 = 0
    private var snapshotBytes = 0, copies: UInt64 = 0
    private var hadInput = false
    public init(context: Context) {
        self.context = context
        var continuation: AsyncStream<Void>.Continuation?
        events = AsyncStream(bufferingPolicy:.bufferingNewest(1)) { continuation = $0 }
        signal = continuation!
    }
    private func notify() {
        signal.yield(())
        let finish = lock.withLock { () -> Bool in
            guard !eventFinished,ended,body == nil,buffers.isEmpty else { return false }
            eventFinished = true; return true
        }
        if finish { signal.finish() }
    }
    /// Scalar wake only; grants no admission or publication authority.
    public func wakeCoordinator() { notify() }
    public var facts: Facts {
        lock.withLock { .init(open:open,ended:ended,bodyEntered:body != nil,unknown:unknown,reason:reason,slots:buffers.count,
                              allocated:allocated,accepted:accepted,rawBytes:buffers.count*MeetingSession.sourceBytes,snapshotBytes:snapshotBytes,copies:copies) }
    }
    /// Control-side precharge only. No callback worker is registered, and failed/empty slots never recycle.
    @discardableResult public func reserve(id: UUID, slot: UInt64) throws -> Permit {
        defer { notify() }
        return try lock.withLock {
            guard !revoked,!ended,drain == nil,(!started || open),buffers.count < 2,allocated < 240,slot == allocated+1,
                  !usedIDs.contains(id),![context.session,context.source,context.segment,context.epoch].contains(id),
                  !MeetingSession.reserved(id,session:context.session) else { throw MeetingSession.Failure.bounds }
            let permit = Permit(nonce:nonce,context:context,id:id,slot:slot)
            let mode: Mode = buffers.contains(where:{$0.mode == .active}) ? .standby : .active
            buffers.append(Buffer(permit,mode:mode,start:accepted)); allocated = slot; usedIDs.insert(id); return permit
        }
    }
    public func activate() throws {
        defer { notify() }
        try lock.withLock {
            guard !started,!revoked,drain == nil,buffers.count == 2,buffers.filter({$0.mode == .active}).count == 1 else { throw MeetingSession.Failure.stale }
            started = true; open = true
        }
    }
    public func enter() throws -> Body {
        defer { notify() }
        return try lock.withLock {
            guard open,!revoked,bodySerial < UInt64.max else { throw MeetingSession.Failure.stale }
            guard body == nil else { refuse(.unknownCoverage,positive:true); throw MeetingSession.Failure.held }
            bodySerial += 1; let value = Body(nonce:nonce,serial:bodySerial); body = value; return value
        }
    }
    public func leave(_ token: Body) throws {
        defer { notify() }
        try lock.withLock { guard body == token else { throw MeetingSession.Failure.stale }; body = nil }
    }
    private func fenceLocked() -> Drain {
        open = false
        if let drain { return drain }
        let value = Drain(nonce:nonce,permits:buffers.map(\.permit)); drain = value; return value
    }
    @discardableResult public func fence() -> Drain {
        defer { notify() }; return lock.withLock { fenceLocked() }
    }
    private func refuse(_ why: MeetingSession.Reason, positive: Bool) {
        if positive { unknown = true }; if reason == nil { reason = why }; _ = fenceLocked()
    }
    private func freeze(_ buffer: Buffer) {
        buffer.mode = .frozen; buffer.sequence = sequence; sequence += 1 // <=240 positive freezes
        if let standby = buffers.first(where:{$0.mode == .standby}) { standby.mode = .active; standby.start = accepted }
    }
    private func append(_ samples: UnsafeBufferPointer<Float>) -> Int {
        var index = 0
        while index < samples.count {
            guard let active = buffers.first(where:{$0.mode == .active}) else { refuse(.budgetRefusal,positive:true); break }
            let capacity = min(Int(MeetingSession.maximumFrames)-active.frames,Int(MeetingSession.maximumTrackFrames-accepted))
            let count = min(capacity,samples.count-index)
            for i in 0..<count {
                let scaled = (Double(samples[index+i])*32768).rounded(.towardZero)
                let value = Int16(max(-32768,min(32767,scaled)))
                active.word(UInt16(bitPattern:value),at:44+(active.frames+i)*2)
            }
            active.frames += count; accepted += UInt64(count); index += count
            if accepted == MeetingSession.maximumTrackFrames { refuse(.frameCeiling,positive:index < samples.count) }
            if active.frames == Int(MeetingSession.maximumFrames) {
                if buffers.contains(where:{$0.mode == .frozen || $0.mode == .writing}) {
                    refuse(.budgetRefusal,positive:index < samples.count); break
                }
                freeze(active)
            }
            if count == 0 || !open { break }
        }
        return index
    }
    /// Caller retains no buffer here. InputShape must have been checked before any future converter allocation as well.
    @discardableResult public func receive(_ token: Body, canonical samples: UnsafeBufferPointer<Float>, input: InputShape) throws -> Int {
        defer { notify() }
        return try lock.withLock {
            guard body == token,token.nonce == nonce else { throw MeetingSession.Failure.stale }
            guard open,!revoked else { return 0 }
            guard input.valid,samples.count <= 32_768,(samples.isEmpty || input.frames > 0),samples.allSatisfy({$0.isFinite}) else {
                refuse(.invalidTail,positive:!samples.isEmpty || input.frames > 0); throw MeetingSession.Failure.bounds
            }
            if input.frames > 0 { hadInput = true }
            return append(samples)
        }
    }
    /// Exactly once after source quiescence. EOS must derive exclusively from converter input accepted before the fence.
    /// Invalid EOS still seals the valid prefix and marks its uncommitted positive coverage unknown.
    @discardableResult public func end(_ token: Drain, tail: UnsafeBufferPointer<Float>) throws -> Bool {
        try end(token,tail:tail,closure:.complete)
    }
    /// Identity, actual body exit and one-shot checks also guard explicit uncertainty.
    /// Return value still describes tail validity, not overall source completeness.
    @discardableResult public func end(_ token: Drain, tail: UnsafeBufferPointer<Float>, closure: Closure) throws -> Bool {
        defer { notify() }
        return try lock.withLock {
            guard token == drain,token.nonce == nonce,!ended,body == nil else { throw MeetingSession.Failure.stale }
            ended = true
            if case .unknown(let why) = closure { unknown = true; if reason == nil { reason = why } }
            if revoked { return false }
            let capacity = buffers.first(where:{$0.mode == .active}).map { Int(MeetingSession.maximumFrames)-$0.frames } ?? 0
            let room = min(capacity,Int(MeetingSession.maximumTrackFrames-accepted))
            let valid = (tail.isEmpty || hadInput) && tail.count <= 32_768 && tail.count <= room && tail.allSatisfy({$0.isFinite})
            if valid,!tail.isEmpty {
                // Admission remains fenced; append EOS directly to the single snapshotted active slot.
                let active = buffers.first(where:{$0.mode == .active})!
                for i in tail.indices {
                    let value = Int16(max(-32768,min(32767,(Double(tail[i])*32768).rounded(.towardZero))))
                    active.word(UInt16(bitPattern:value),at:44+(active.frames+i)*2)
                }
                active.frames += tail.count; accepted += UInt64(tail.count)
            } else if !valid { refuse(.invalidTail,positive:!tail.isEmpty) }
            buffers.removeAll(where:{$0.frames == 0 && $0.mode != .writing})
            if !buffers.contains(where:{$0.mode == .frozen || $0.mode == .writing}),let active = buffers.first(where:{$0.mode == .active}) { freeze(active) }
            return valid
        }
    }
    public var readyPermit: Permit? { lock.withLock { revoked ? nil : buffers.first(where:{$0.mode == .frozen})?.permit } }
    public func take(_ permit: Permit) throws -> Delivery {
        defer { notify() }
        return try lock.withLock {
            guard !revoked,snapshotBytes == 0,let buffer = buffers.first(where:{$0.permit == permit && $0.mode == .frozen}) else { throw MeetingSession.Failure.stale }
            buffer.mode = .writing; let bytes = buffer.wav(); snapshotBytes = bytes.count; copies += 1
            return .init(permit:permit,start:buffer.start,sequence:buffer.sequence,frames:UInt64(buffer.frames),bytes:bytes)
        }
    }
    public func permitAllowed(_ permit: Permit) -> Bool {
        lock.withLock { !revoked && permit.nonce == nonce && permit.context == context && buffers.contains(where:{$0.permit == permit && $0.mode == .writing}) && (open || drain?.permits.contains(permit) == true) }
    }
    public func retire(_ permit: Permit) throws {
        defer { notify() }
        try lock.withLock {
            guard let i = buffers.firstIndex(where:{$0.permit == permit && $0.mode == .writing}) else { throw MeetingSession.Failure.stale }
            buffers.remove(at:i); snapshotBytes = 0
            if ended,!revoked,let active = buffers.first(where:{$0.mode == .active}),active.frames > 0 { freeze(active) }
        }
    }
    /// Delete/expiry/failure: no more publication. A writing slot remains owned until actual writer exit.
    public func revoke() {
        defer { notify() }
        lock.withLock {
            _ = fenceLocked(); revoked = true
            if buffers.contains(where:{$0.frames > 0 && $0.mode != .writing}) { unknown = true }
            buffers.removeAll(where:{$0.mode != .writing})
        }
    }
}
