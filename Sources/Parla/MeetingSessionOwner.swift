import Foundation
import ParlaCore

/// Fake-port foundation only. No app entry, capture adapter, recognizer factory or implicit dependency exists.
@MainActor final class MeetingSessionOwner {
    struct Producer {
        enum Exit { case notStarted, actual(Task<Void,Never>) }
        let source: UUID, exit: Exit
    }
    struct ProducerOutcomes {
        let first: Producer?, second: Producer?
        var all: [Producer] { [first,second].compactMap { $0 } }
    }
    struct CapturePort {
        let validate: ([MeetingSession.Selection]) async -> Bool
        /// Exactly one outcome per selection, including every partially started producer.
        let start: ([MeetingSession.Selection]) -> ProducerOutcomes
        let requestStop: () async -> Void
    }
    /// Opt-in canonical microphone seam. start receives two charged slots before it may enter a body.
    /// requestStop only halts acquisition; it MUST NOT await owner.stop or its own writer.
    /// The actual task includes partial-start cleanup, callback quiescence and end(fence(), tail:).
    struct MicrophoneStreamPort {
        let validate: (MeetingSession.Selection) async -> Bool
        let start: (MeetingSession.Selection,MeetingAudioIngress) -> Producer
        let requestStop: () async -> Void
    }
    struct RawResult: Sendable {
        let input: MeetingSessionStore.ResultInput, observed: MeetingSession.Provenance
        var bytes: Data { input.bytes }
        init(bytes: Data, observed: MeetingSession.Provenance) throws {
            guard bytes.count > 0,bytes.count <= MeetingSession.resultBytes,let text = String(data:bytes,encoding:.utf8),
                !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,observed.role == .observed else { throw MeetingSession.Failure.bounds }
            input = try .init(bytes); self.observed = observed
        }
    }
    struct RecognitionPort {
        /// The returned task denotes actual consumer exit, including its owned callbacks. Cancellation acknowledgment is separate.
        let run: (Data,MeetingSession.Provenance) -> Task<Result<RawResult,Error>,Never>
        let requestCancel: () -> Void
    }
    struct Ticket: Equatable { fileprivate let id: UUID, session: UUID, generation: UInt64, track: Int, source: UUID, sourceGeneration: UInt64 }
    enum RecognitionState { case none, pending, canceled, failed, completed }
    private(set) var recognitionState = RecognitionState.none
    enum State: Equatable { case idle, starting, recording, stopping, stopped, transcribing, deleting, expired, unavailable, detached }
    private final class Authority: @unchecked Sendable {
        private let lock = NSLock(); private var valid = true
        func revoke() { lock.withLock { valid = false } }
        func allowed() -> Bool { lock.withLock { valid } }
    }
    private struct Ingress { let ticket: Ticket, hold: MeetingSessionStore.Hold, chunk: Bool; var submitted: Bool }
    let store: MeetingSessionStore
    private let capture: CapturePort, recognition: RecognitionPort, wall: () throws -> Int64, holdEpoch: UInt64
    private(set) var state: State = .idle, projection: MeetingSession.Projection = .idle
    private(set) var concern: MeetingSession.Reason?
    private var terminalReason: MeetingSession.Reason?
    private var lifetime: MeetingSessionOwner?
    private var generation: UInt64 = 0, selections: [MeetingSession.Selection] = [], session: UUID?
    private var ingressOpen = false, reservedSlots = 0, deleteRequested = false, quitIntent = false
    private var unknownMask: UInt64 = 0
    private var ingress: [Int:Ingress] = [:], submissions: [UUID:Task<Result<Void,Error>,Never>] = [:]
    private var producers: [(Producer,MeetingSessionStore.Hold)] = []
    private var unclassifiedProducerTasks: [Task<Void,Never>] = []
    private var microphonePort: MicrophoneStreamPort?
    private var microphoneIngress: MeetingAudioIngress?
    private var streamObserver: Task<Void,Never>?, streamWriter: Task<Result<Void,Error>,Never>?
    private var streamQuitPending = false, streamWriterFinished = false
    private var streamFailure: Error?
    private var streamWriterID: UUID?
    private var pendingStart = false
    private var phaseActive = false
    private var phase: Task<Void,Never>?, idleWaiters: [CheckedContinuation<Void,Never>] = []
    private var callbackWaiters: [CheckedContinuation<Void,Never>] = []
    private var producerJoin: Task<Result<Void,Error>,Never>?, writerTail: Task<Result<Void,Error>,Never>?, writerTailID: UUID?
    private var stopRequest: Task<Void,Never>?, stopTask: Task<Result<Void,Error>,Never>?, deleteTask: Task<Result<Void,Error>,Never>?
    private var recognitionTask: Task<Result<RawResult,Error>,Never>?, transcriptionTask: Task<Result<Void,Error>,Never>?
    private var attemptAuthority: Authority?, captureAuthority: Authority?, attempt: MeetingSessionStore.AttemptToken?
    init(store: MeetingSessionStore, capture: CapturePort, recognition: RecognitionPort, wallClock: @escaping () throws -> Int64, holdEpoch: UInt64) {
        self.store = store; self.capture = capture; self.recognition = recognition; wall = wallClock; self.holdEpoch = holdEpoch
    }
    init(store: MeetingSessionStore, microphone: MicrophoneStreamPort, recognition: RecognitionPort, wallClock: @escaping () throws -> Int64, holdEpoch: UInt64) {
        self.store = store; microphonePort = microphone; self.recognition = recognition; wall = wallClock; self.holdEpoch = holdEpoch
        capture = .init(validate:{ _ in false },start:{ _ in .init(first:nil,second:nil) },requestStop:{})
    }
    private func fail(_ error: Error) {
        microphoneIngress?.revoke()
        if microphoneIngress != nil { captureAuthority?.revoke() }
        switch error {
        case MeetingSession.Failure.clock: concern = .invalidClock
        case MeetingSession.Failure.detailExhausted: concern = .detailExhaustion
        case MeetingSession.Failure.nondurableIntent: concern = .firstIntentFailure
        case MeetingSession.Failure.held: concern = .lifecycleHeld
        case SavedAudioImportStorage.Failure.uncertain: concern = .close
        case SavedAudioImportStorage.Failure.bounds: concern = .budgetRefusal
        case SavedAudioImportStorage.Failure.space: concern = .headroom
        case SavedAudioImportStorage.Failure.changed: concern = .identity
        case SavedAudioImportStorage.Failure.unknown: concern = .namespace
        default: concern = .ioRefusal
        }
        state = .unavailable; ingressOpen = false; projection = projection.refusingUse()
        if session != nil || !unclassifiedProducerTasks.isEmpty { requestProducerStop() }
    }
    private func io<T: Sendable>(waitingForAdmission: Bool = false, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        if waitingForAdmission || microphoneIngress != nil {
            while phaseActive { await withCheckedContinuation { idleWaiters.append($0) } }
        }
        guard !phaseActive else { throw MeetingSession.Failure.held }
        phaseActive = true // registered before the detached body can start
        let task = Task.detached { Result { try operation() } }
        let join = Task { _ = await task.value }; phase = join
        let result = await task.value; await join.value
        phase = nil; phaseActive = false; let waiters = idleWaiters; idleWaiters.removeAll(); for waiter in waiters { waiter.resume() }
        return try result.get()
    }
    private func waitForPhase() async {
        if !phaseActive { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
    private func cache() async throws { let store = store; projection = try await io { store.projection } }
    func refresh() async {
        guard state == .idle else { return }; lifetime = self; let store = store
        do {
            projection = try await io { try store.bootstrap() }
            if projection.session != nil {
                session = projection.session
                if (projection.state == .interrupted || projection.state == .stopped),!projection.expired { let epoch = holdEpoch; _ = try await io { try store.terminal(reason:.interrupted,unknownMask:3,generation:0,holdEpoch:epoch,flags:1,authorized:{true}) }; try await cache() }
                state = projection.state == .deleting || projection.state == .authorityDead ? .deleting : projection.expired ? .expired : .stopped
            } else { lifetime = nil }
        }
        catch { fail(error) }
    }
    func start(owner: UUID, session: UUID, selections: [MeetingSession.Selection], segments: [MeetingSession.Segment]) async throws {
        guard microphonePort == nil else { throw MeetingSession.Failure.unavailable }
        try await startImpl(owner:owner,session:session,selections:selections,segments:segments,streaming:false)
    }
    func startMicrophone(owner: UUID, session: UUID, selection: MeetingSession.Selection, segment: MeetingSession.Segment) async throws {
        guard microphonePort != nil,selection.kind == .microphone,segment.track == 0,segment.generation == selection.generation,
              segment.canonicalStart == 0,segment.timing.mapping == .unknown,segment.timing.rate == 16_000,
              segment.timing.pts == 0,segment.timing.denominator == 1,segment.timing.sample == 0 else { throw MeetingSession.Failure.bounds }
        try await startImpl(owner:owner,session:session,selections:[selection],segments:[segment],streaming:true)
    }
    private func startImpl(owner: UUID, session: UUID, selections: [MeetingSession.Selection], segments: [MeetingSession.Segment], streaming: Bool) async throws {
        guard state == .idle,self.session == nil,!quitIntent,concern == nil,!selections.isEmpty,selections.count <= 2 else { throw MeetingSession.Failure.stale }
        reservedSlots = 0; unknownMask = 0; terminalReason = nil; deleteRequested = false; stopRequest = nil; stopTask = nil; deleteTask = nil
        state = .starting; generation = try increment(generation); let admittedGeneration = generation
        pendingStart = true; lifetime = self
        let authority = Authority(); captureAuthority = authority; let store = store
        defer { pendingStart = false }
        let valid: Bool
        if streaming,let microphonePort { valid = await microphonePort.validate(selections[0]) }
        else { valid = await capture.validate(selections) }
        guard valid,state == .starting,generation == admittedGeneration,!quitIntent,authority.allowed() else {
            authority.revoke()
            if state == .starting { state = .idle }
            if self.session == nil { lifetime = nil }
            throw MeetingSession.Failure.unavailable
        }
        do {
            _ = try await io { try store.admit(owner:owner,session:session,selections:selections,segments:segments,authorized:authority.allowed) }
            self.session = session; self.selections = selections
            guard state == .starting,!quitIntent,generation == admittedGeneration else { throw MeetingSession.Failure.stale }
            var holds: [MeetingSessionStore.Hold] = []
            for s in selections { holds.append(try store.register(s.kind == .microphone ? .microphone : .system)) }
            let runs: [Producer]
            if streaming,let microphonePort {
                let selection = selections[0], segment = segments[0]
                let stream = MeetingAudioIngress(context:.init(session:session,ownerGeneration:generation,source:selection.instance,
                    sourceGeneration:selection.generation,segment:segment.id,epoch:segment.timing.epoch))
                microphoneIngress = stream
                try chargeStream(stream); try chargeStream(stream); try stream.activate()
                // Both permits and producer hold precede the first possible synchronous callback.
                runs = [microphonePort.start(selection,stream)]
                if case .notStarted = runs[0].exit {
                    _ = try stream.end(stream.fence(),tail:UnsafeBufferPointer<Float>(start:nil,count:0))
                }
            } else { runs = capture.start(selections).all }
            unclassifiedProducerTasks = runs.compactMap { if case .actual(let task) = $0.exit { return task }; return nil }
            guard runs.count == selections.count,Set(runs.map(\.source)) == Set(selections.map(\.instance)) else {
                // Missing/foreign outcome supplies no actual-exit evidence. Preserve the registered holds and refuse readiness.
                concern = .lifecycleHeld; state = .unavailable; throw MeetingSession.Failure.unavailable
            }
            for (i,s) in selections.enumerated() {
                guard let run = runs.first(where:{$0.source == s.instance}) else { throw MeetingSession.Failure.unavailable }
                producers.append((run,holds[i]))
            }
            unclassifiedProducerTasks.removeAll() // exact task handles are now retained by producers
            if runs.contains(where:{ if case .notStarted = $0.exit { return true }; return false }) {
                microphoneIngress?.fence()
                ingressOpen = false; state = .stopping; requestProducerStop(); try await joinProducers(); throw MeetingSession.Failure.unavailable
            }
            ingressOpen = true; state = .recording; try await cache()
            if let stream = microphoneIngress { observeStream(stream) }
        } catch { fail(error); throw error }
    }
    private func chargeStream(_ stream: MeetingAudioIngress) throws {
        guard reservedSlots < 240 else { throw MeetingSession.Failure.bounds }
        let next = reservedSlots+1
        try stream.reserve(id:UUID(),slot:UInt64(next)); reservedSlots = next
    }
    private func observeStream(_ stream: MeetingAudioIngress) {
        streamObserver = Task { @MainActor [self] in
            for await _ in stream.events {
                let facts = stream.facts
                if facts.unknown { unknownMask |= 1; terminalReason = facts.reason ?? .unknownCoverage }
                else if let reason = facts.reason { terminalReason = reason }
                if !facts.open,!deleteRequested {
                    ingressOpen = false
                    if state == .recording { state = .stopping }
                    if !facts.ended { requestProducerStop() }
                }
                if streamWriterFinished,streamWriter != nil {
                    do { try await joinStreamWriter() } catch { streamFailure = error }
                }
                launchStreamWriter(stream)
            }
        }
    }
    private func launchStreamWriter(_ stream: MeetingAudioIngress) {
        guard streamWriter == nil,streamFailure == nil,stream.readyPermit != nil else { return }
        streamWriterID = UUID()
        streamWriter = Task { @MainActor [self] in
            defer { streamWriterFinished = true; stream.wakeCoordinator() }
            do {
                while let permit = stream.readyPermit { try await writeStreamSlot(stream,permit:permit) }
                return .success(())
            } catch {
                stream.revoke()
                if !deleteRequested { unknownMask |= 1; terminalReason = .unknownCoverage; fail(error) }
                return .failure(error)
            }
        }
    }
    private func writeStreamSlot(_ stream: MeetingAudioIngress, permit: MeetingAudioIngress.Permit) async throws {
        await waitForPhase()
        guard !deleteRequested,stream.context.session == session,stream.context.ownerGeneration == generation,ingress[0] == nil else { throw MeetingSession.Failure.stale }
        let hold = try store.register(.microphoneCallback)
        let ticket = Ticket(id:permit.id,session:stream.context.session,generation:generation,track:0,
                            source:stream.context.source,sourceGeneration:stream.context.sourceGeneration)
        let delivery: MeetingAudioIngress.Delivery
        do { delivery = try stream.take(permit) }
        catch { try store.actualExit(hold); throw error }
        ingress[0] = .init(ticket:ticket,hold:hold,chunk:true,submitted:false)
        do {
            let timing = MeetingSession.Timing(pts:0,denominator:1,sample:0,rate:16_000,epoch:stream.context.epoch,mapping:.unknown)
            let input = try MeetingSessionStore.ChunkInput(session:ticket.session,source:ticket.source,id:permit.id,generation:permit.slot,
                track:0,sourceGeneration:ticket.sourceGeneration,segment:stream.context.segment,sequence:delivery.sequence,
                start:delivery.start,frames:delivery.frames,timing:timing,bytes:delivery.bytes)
            try await submit(ticket,input:input,authorized:{ stream.permitAllowed(permit) })
        } catch {
            // Pre-submit construction errors still own the callback hold. Submitted bodies retire themselves.
            if let owned = ingress[0],!owned.submitted {
                try store.actualExit(owned.hold); ingress.removeValue(forKey:0); callbacksExited()
            }
            try stream.retire(permit); throw error
        }
        try stream.retire(permit)
        if stream.facts.open {
            if reservedSlots < 240 {
                do { try chargeStream(stream) }
                catch { if stream.facts.open { throw error } } // a callback may have fenced between observation and charge
            }
            else { terminalReason = .slotExhaustion; stream.fence(); requestProducerStop() }
        }
    }
    private func joinStreamWriter() async throws {
        guard let task = streamWriter,let id = streamWriterID else { return }
        let result = await task.value
        if streamWriterID == id { streamWriter = nil; streamWriterID = nil; streamWriterFinished = false }
        if case .failure(let error) = result { streamFailure = error }
        try result.get()
    }
    private func drainStream(_ stream: MeetingAudioIngress) async throws {
        // Producer never waits for this method. It has already handed off EOS and actually exited.
        // At source exit there are at most two slots; identity-checked joins tolerate observer reentrancy.
        for _ in 0..<3 {
            try await joinStreamWriter()
            if let streamFailure { throw streamFailure }
            launchStreamWriter(stream)
            if streamWriter == nil { break }
        }
        guard streamWriter == nil,stream.facts.settled else { throw MeetingSession.Failure.held }
        if stream.facts.unknown { unknownMask |= 1; terminalReason = stream.facts.reason ?? .unknownCoverage }
        else if let reason = stream.facts.reason { terminalReason = reason }
    }
    private func increment(_ n: UInt64) throws -> UInt64 { let next = n.addingReportingOverflow(1); guard !next.overflow else { throw MeetingSession.Failure.bounds }; return next.partialValue }
    /// Must be called BEFORE the fake port allocates/collects the next frozen input. One ticket/buffer per source, 240 total.
    func reserveInput(id: UUID, track: Int) throws -> Ticket {
        guard microphoneIngress == nil else { throw MeetingSession.Failure.stale }
        if ingressOpen,state == .recording,selections.indices.contains(track),reservedSlots >= 240 {
            ingressOpen = false; state = .stopping; unknownMask |= UInt64(1) << track; terminalReason = .slotExhaustion; concern = .slotExhaustion; requestProducerStop()
            throw MeetingSession.Failure.bounds
        }
        guard ingressOpen,state == .recording,let session,selections.indices.contains(track),ingress[track] == nil,reservedSlots < 240,!ingress.values.contains(where:{$0.ticket.id == id}) else { throw MeetingSession.Failure.bounds }
        let s = selections[track], hold = try store.register(s.kind == .microphone ? .microphoneCallback : .systemCallback)
        let ticket = Ticket(id:id,session:session,generation:generation,track:track,source:s.instance,sourceGeneration:s.generation)
        reservedSlots += 1; ingress[track] = .init(ticket:ticket,hold:hold,chunk:true,submitted:false); return ticket
    }
    /// Metadata callbacks use their own bounded body hold and never fabricate an audio allocation.
    func reserveEvent(id: UUID, track: Int) throws -> Ticket {
        guard microphoneIngress == nil else { throw MeetingSession.Failure.stale }
        guard ingressOpen,state == .recording,let session,selections.indices.contains(track),ingress[track] == nil else { throw MeetingSession.Failure.stale }
        let s = selections[track], hold = try store.register(s.kind == .microphone ? .microphoneCallback : .systemCallback)
        let ticket = Ticket(id:id,session:session,generation:generation,track:track,source:s.instance,sourceGeneration:s.generation)
        ingress[track] = .init(ticket:ticket,hold:hold,chunk:false,submitted:false); return ticket
    }
    func boundary(_ ticket: Ticket, segment: MeetingSession.Segment?, gap: MeetingSession.Gap?, evidence: MeetingSession.Timing?) async throws {
        guard var owned = ingress[ticket.track],owned.ticket == ticket,!owned.chunk,!owned.submitted,ticket.session == session,ticket.generation == generation else { throw MeetingSession.Failure.stale }
        owned.submitted = true; ingress[ticket.track] = owned
        let previous = writerTail, store = store, authority = captureAuthority!
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            var writer: MeetingSessionStore.Hold?
            do {
                if let previous { _ = await previous.value }; guard !deleteRequested else { throw MeetingSession.Failure.stale }
                writer = try store.register(.writer)
                _ = try await io { try store.boundary(session:ticket.session,source:ticket.source,segment:segment,gap:gap,evidence:evidence,authorized:authority.allowed) }
                if !deleteRequested { try await cache() }
                if let writer { try store.actualExit(writer) }; return .success(())
            } catch {
                if let writer { do { try store.actualExit(writer) } catch { fail(error) } }
                if !deleteRequested { unknownMask |= UInt64(1) << ticket.track; terminalReason = (error as? MeetingSession.Failure) == .detailExhausted ? .detailExhaustion : .unknownCoverage; fail(error) }
                return .failure(error)
            }
        }
        writerTail = task; writerTailID = ticket.id; submissions[ticket.id] = task
        let result = await task.value
        try store.actualExit(owned.hold); ingress.removeValue(forKey:ticket.track); submissions.removeValue(forKey:ticket.id)
        if writerTailID == ticket.id { writerTail = nil; writerTailID = nil }; callbacksExited()
        if !deleteRequested { try result.get() }
    }
    /// The callback-body hold includes conversion/frozen-buffer ownership through the final writer exit.
    func submit(_ ticket: Ticket, input: MeetingSessionStore.ChunkInput) async throws {
        guard let captureAuthority else { throw MeetingSession.Failure.stale }
        try await submit(ticket,input:input,authorized:captureAuthority.allowed)
    }
    private func submit(_ ticket: Ticket, input: MeetingSessionStore.ChunkInput, authorized: @escaping @Sendable () -> Bool) async throws {
        guard var owned = ingress[ticket.track],owned.ticket == ticket,owned.chunk,!owned.submitted,ticket.session == session,ticket.generation == generation,
            input.session == ticket.session,input.source == ticket.source,input.track == ticket.track,input.sourceGeneration == ticket.sourceGeneration,input.bytes.count <= MeetingSession.sourceBytes else { throw MeetingSession.Failure.stale }
        owned.submitted = true; ingress[ticket.track] = owned
        let store = store, previous = writerTail
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            var writer: MeetingSessionStore.Hold?
            do {
                if let previous { _ = await previous.value }
                guard !deleteRequested else { throw MeetingSession.Failure.stale }
                writer = try store.register(.writer)
                let a = try await io { try store.chunkA(input,authorized:authorized) }
                if !deleteRequested {
                    let b = try await io { try store.chunkB(a,bytes:input.bytes,authorized:authorized) }
                    if !deleteRequested { _ = try await io { try store.chunkC(b,authorized:authorized) } }
                }
                if !deleteRequested { try await cache() }
                if let writer { try store.actualExit(writer) }; return .success(())
            } catch {
                if let writer { do { try store.actualExit(writer) } catch { fail(error) } }
                if !deleteRequested { unknownMask |= UInt64(1) << ticket.track; ingressOpen = false; fail(error) }
                return .failure(error)
            }
        }
        writerTail = task; writerTailID = ticket.id; submissions[ticket.id] = task
        let result = await task.value // includes projection IO; callback-body exit remains separate
        try store.actualExit(owned.hold) // last callback-body action after every owned IO task has actually exited
        submissions.removeValue(forKey:ticket.id); ingress.removeValue(forKey:ticket.track)
        if writerTailID == ticket.id { writerTail = nil; writerTailID = nil }
        callbacksExited()
        if !deleteRequested { try result.get() }
    }
    /// Explicit no-data callback exit. A reserved slot is retained; a positive uncommitted tail is unknown coverage.
    func abandon(_ ticket: Ticket) throws {
        guard let owned = ingress[ticket.track],owned.ticket == ticket,!owned.submitted else { throw MeetingSession.Failure.stale }
        try store.actualExit(owned.hold); ingress.removeValue(forKey:ticket.track); unknownMask |= UInt64(1) << ticket.track; ingressOpen = false; concern = .unknownCoverage; terminalReason = .unknownCoverage; callbacksExited()
    }
    private func requestProducerStop() {
        guard !producers.isEmpty || !unclassifiedProducerTasks.isEmpty else { return }
        if stopRequest == nil {
            if let microphonePort,microphoneIngress != nil { stopRequest = Task { await microphonePort.requestStop() } }
            else { let port = capture; stopRequest = Task { await port.requestStop() } }
        }
    }
    private func joinProducers() async throws {
        if let producerJoin { try await producerJoin.value.get(); return }
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            do {
                if let stopRequest { await stopRequest.value }
                for task in unclassifiedProducerTasks { await task.value }; unclassifiedProducerTasks.removeAll()
                for (producer,hold) in producers {
                    if case .actual(let task) = producer.exit { await task.value }
                    if let stream = microphoneIngress {
                        guard stream.facts.producerFinished else { throw MeetingSession.Failure.held }
                        try await drainStream(stream)
                        guard stream.facts.settled else { throw MeetingSession.Failure.held }
                        if let streamObserver { await streamObserver.value; self.streamObserver = nil }
                    }
                    try store.actualExit(hold)
                }
                producers.removeAll(); return .success(())
            } catch { fail(error); return .failure(error) }
        }
        producerJoin = task; let result = await task.value; producerJoin = nil; try result.get()
    }
    private func callbacksExited() {
        guard ingress.isEmpty else { return }
        let pending = callbackWaiters; callbackWaiters.removeAll(); for waiter in pending { waiter.resume() }
    }
    private func joinCallbacks() async throws {
        if !ingress.isEmpty {
            guard callbackWaiters.count < 2 else { throw MeetingSession.Failure.held }
            await withCheckedContinuation { callbackWaiters.append($0) }
        }
        guard ingress.isEmpty,submissions.isEmpty else { throw MeetingSession.Failure.held }
        await waitForPhase()
    }
    func stop() async throws {
        if let stopTask { try await stopTask.value.get(); return }
        guard state == .recording || state == .stopping || state == .unavailable else { if state == .stopped { return }; throw MeetingSession.Failure.stale }
        microphoneIngress?.fence()
        ingressOpen = false; state = .stopping; requestProducerStop()
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            do {
                try await joinProducers(); try await joinCallbacks()
                if deleteRequested { return .success(()) }
                let store = store, generation = generation, epoch = holdEpoch, mask = unknownMask, reason = terminalReason
                let flags: UInt64 = 0x7f | (reason == .detailExhaustion ? 1 << 10 : 0) | (reason == .slotExhaustion ? 1 << 11 : 0)
                _ = try await io { try store.terminal(reason:reason ?? (mask == 0 ? .normalStop : .unknownCoverage),unknownMask:mask,generation:generation,holdEpoch:epoch,flags:flags,authorized:{true}) }
                state = .stopped; concern = nil; captureAuthority?.revoke(); microphoneIngress?.revoke(); store.fence()
                if streamQuitPending { store.reserveQuit(); streamQuitPending = false }
                try await cache(); return .success(())
            } catch { fail(error); return .failure(error) }
        }
        stopTask = task; let result = await task.value; stopTask = nil; try result.get()
    }
    func transcribe(chunk: UUID, requested: MeetingSession.Provenance) async throws {
        guard state == .stopped,transcriptionTask == nil,!quitIntent,concern == nil else { throw MeetingSession.Failure.stale }
        let authority = Authority(); attemptAuthority = authority; recognitionState = .pending; state = .transcribing; let store = store
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            var borrow: MeetingSessionStore.BorrowToken?, output: MeetingSessionStore.Hold?
            do {
                let token = try await io { try store.beginAttempt(chunk:chunk,requested:requested,authorized:authority.allowed) }; attempt = token
                output = try store.register(.output)
                let selected = try await io { try store.borrow(token,authorized:authority.allowed) }; borrow = selected.0
                let consumer = recognition.run(selected.1,requested); recognitionTask = consumer
                let raw = try await consumer.value.get(); recognitionTask = nil
                if authority.allowed(),!deleteRequested,!quitIntent {
                    let a = try await io { try store.resultReserve(token,borrow:selected.0,input:raw.input,observed:raw.observed,authorized:authority.allowed) }
                    let b = try await io { try store.resultWrite(a,bytes:raw.bytes,authorized:authority.allowed) }
                    _ = try await io { try store.resultPromote(b,authorized:authority.allowed) }; recognitionState = .completed
                } else if !deleteRequested { _ = try await io { try store.cancelAttempt(token,authorized:{true}) }; recognitionState = .canceled }
                if let token = borrow {
                    borrow = nil // the queued retirement owns this token through its actual exit
                    try await io(waitingForAdmission:true) { try store.actualBorrowExit(token) }
                }
                if let token = output { output = nil; try store.actualExit(token) }
                attempt = nil; state = deleteRequested ? .deleting : .stopped; try await cache(); return .success(())
            } catch {
                // The consumer has actually exited before these resources are retired. Cancellation alone never reaches this block.
                recognitionTask = nil
                if !deleteRequested, let token = attempt { let canceled = !authority.allowed(); do { _ = try await io { try store.finishAttempt(token,canceled:canceled,authorized:{true}) } } catch { fail(error) } }
                if let token = borrow {
                    borrow = nil
                    do { try await io(waitingForAdmission:true) { try store.actualBorrowExit(token) } } catch { fail(error) }
                }
                if let token = output { output = nil; do { try store.actualExit(token) } catch { fail(error) } }
                attempt = nil; recognitionState = authority.allowed() ? .failed : .canceled
                if !deleteRequested {
                    do { try await cache(); if projection.unavailable { fail(error) } else { state = .stopped } } catch { fail(error) }
                }
                return .failure(error)
            }
        }
        transcriptionTask = task; let result = await task.value; transcriptionTask = nil; try result.get()
    }
    func cancelTranscription() { attemptAuthority?.revoke(); if recognitionTask != nil { recognition.requestCancel() } }
    func delete(id: UUID) async throws {
        if let deleteTask { try await deleteTask.value.get(); return }
        guard session != nil else { throw MeetingSession.Failure.stale }
        microphoneIngress?.revoke()
        if microphoneIngress != nil { captureAuthority?.revoke() }
        ingressOpen = false; deleteRequested = true; state = .deleting; cancelTranscription(); requestProducerStop()
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            do {
                await waitForPhase()
                let store = store, generation = generation, epoch = holdEpoch
                let resume = projection.state == .deleting || projection.state == .authorityDead
                var receipt = try await io {
                    if resume { return try store.resumeDeletion(authorized:{true}) }
                    return try store.deleteIntent(id:id,terminalGeneration:generation,holdEpoch:epoch,authorized:{true})
                }
                // Durable intent precedes joins and every unlink. Held recognition may keep the borrow alive here.
                try await joinProducers(); try await joinCallbacks()
                if let transcriptionTask { _ = await transcriptionTask.value }
                guard ingress.isEmpty,store.actualHoldsDrained else { throw MeetingSession.Failure.held }
                for _ in 0..<241 {
                    if receipt.deletionRemaining == 0 { break }
                    let prior = receipt; receipt = try await io { try store.deleteSlice(prior,authorized:{true}) }
                }
                guard receipt.deletionRemaining == 0 else { throw MeetingSession.Failure.bounds }
                if receipt.phase != .deleteAuthority { let prior = receipt; receipt = try await io { try store.deleteAuthority(prior,authorized:{true}) } }
                let dead = receipt; _ = try await io { try store.deleteClose(dead,authorized:{true}) }
                session = nil; state = .idle; concern = nil; projection = .idle; lifetime = nil
                microphoneIngress = nil; streamObserver = nil; streamWriter = nil; streamQuitPending = false; streamWriterFinished = false; streamWriterID = nil; streamFailure = nil
                return .success(())
            } catch { fail(error); return .failure(error) }
        }
        deleteTask = task; let result = await task.value; deleteTask = nil; try result.get()
    }
    func evaluateExpiry(deleteID: UUID) async throws {
        do { let n = try wall(); guard n >= 0 else { throw MeetingSession.Failure.clock } }
        catch { if microphoneIngress != nil { fail(error) }; throw error }
        let store = store
        if microphoneIngress == nil {
            try await io { try store.evaluate() }; try await cache()
            if projection.expired { ingressOpen = false; state = .expired; cancelTranscription(); try await delete(id:deleteID) }
            return
        }
        do {
            await waitForPhase()
            // Revoke before the next actor await once the store observes expiry. The store itself fences first.
            let expired = try await io { try store.evaluate(); return store.projection.expired }
            if expired { microphoneIngress?.revoke(); captureAuthority?.revoke() }
            try await cache()
        } catch { fail(error); throw error }
        if projection.expired { ingressOpen = false; state = .expired; cancelTranscription(); try await delete(id:deleteID) }
    }
    func reserveQuit() {
        quitIntent = true; ingressOpen = false; attemptAuthority?.revoke(); captureAuthority?.revoke()
        if let stream = microphoneIngress,(!stream.facts.settled || !producers.isEmpty || streamWriter != nil || streamObserver != nil) {
            stream.fence(); streamQuitPending = true; requestProducerStop()
        } else { store.reserveQuit() }
        if recognitionTask != nil { recognition.requestCancel() }
    }
    func cancelQuit() { quitIntent = false; streamQuitPending = false; store.cancelQuit() } // revoked producer/review/attempt authority is never restored
    var shutdownReady: Bool {
        quitIntent && !streamQuitPending && streamWriter == nil && streamObserver == nil && (microphoneIngress == nil || microphoneIngress!.facts.settled) && !pendingStart && stopTask == nil && deleteTask == nil && producerJoin == nil && !phaseActive && phase == nil && producers.isEmpty && unclassifiedProducerTasks.isEmpty && ingress.isEmpty && submissions.isEmpty && recognitionTask == nil && transcriptionTask == nil && concern == nil && (session == nil || store.shutdownReady)
    }
    /// Explicit future composition hook. Request acknowledgment never substitutes for any owned actual exit.
    func beginShutdown() async -> Bool {
        reserveQuit()
        do {
            if state == .recording || state == .stopping { try await stop() }
            if let transcriptionTask { _ = await transcriptionTask.value }
            if let deleteTask { _ = await deleteTask.value }
            await waitForPhase()
            return shutdownReady
        } catch { fail(error); return false }
    }
    func committedDetach() async throws {
        guard shutdownReady else { throw MeetingSession.Failure.held }
        if session != nil { let store = store; try await io { try store.detach() } }; state = .detached; lifetime = nil
    }
}
