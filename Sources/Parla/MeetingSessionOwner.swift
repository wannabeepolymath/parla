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
    private func fail(_ error: Error) {
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
        if waitingForAdmission {
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
        guard state == .idle,self.session == nil,!quitIntent,concern == nil,!selections.isEmpty,selections.count <= 2 else { throw MeetingSession.Failure.stale }
        reservedSlots = 0; unknownMask = 0; terminalReason = nil; deleteRequested = false; stopRequest = nil; stopTask = nil; deleteTask = nil
        state = .starting; generation = try increment(generation); let admittedGeneration = generation
        pendingStart = true; lifetime = self
        let authority = Authority(); captureAuthority = authority; let store = store
        defer { pendingStart = false }
        guard await capture.validate(selections),state == .starting,generation == admittedGeneration,!quitIntent,authority.allowed() else {
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
            let runs = capture.start(selections).all
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
                ingressOpen = false; state = .stopping; requestProducerStop(); try await joinProducers(); throw MeetingSession.Failure.unavailable
            }
            ingressOpen = true; state = .recording; try await cache()
        } catch { fail(error); throw error }
    }
    private func increment(_ n: UInt64) throws -> UInt64 { let next = n.addingReportingOverflow(1); guard !next.overflow else { throw MeetingSession.Failure.bounds }; return next.partialValue }
    /// Must be called BEFORE the fake port allocates/collects the next frozen input. One ticket/buffer per source, 240 total.
    func reserveInput(id: UUID, track: Int) throws -> Ticket {
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
        guard var owned = ingress[ticket.track],owned.ticket == ticket,owned.chunk,!owned.submitted,ticket.session == session,ticket.generation == generation,
            input.session == ticket.session,input.source == ticket.source,input.track == ticket.track,input.sourceGeneration == ticket.sourceGeneration,input.bytes.count <= MeetingSession.sourceBytes else { throw MeetingSession.Failure.stale }
        owned.submitted = true; ingress[ticket.track] = owned
        let store = store, authority = captureAuthority!, previous = writerTail
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            var writer: MeetingSessionStore.Hold?
            do {
                if let previous { _ = await previous.value }
                guard !deleteRequested else { throw MeetingSession.Failure.stale }
                writer = try store.register(.writer)
                let a = try await io { try store.chunkA(input,authorized:authority.allowed) }
                if !deleteRequested {
                    let b = try await io { try store.chunkB(a,bytes:input.bytes,authorized:authority.allowed) }
                    if !deleteRequested { _ = try await io { try store.chunkC(b,authorized:authority.allowed) } }
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
        if stopRequest == nil { let port = capture; stopRequest = Task { await port.requestStop() } }
    }
    private func joinProducers() async throws {
        if let producerJoin { try await producerJoin.value.get(); return }
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            do {
                if let stopRequest { await stopRequest.value }
                for task in unclassifiedProducerTasks { await task.value }; unclassifiedProducerTasks.removeAll()
                for (producer,hold) in producers {
                    if case .actual(let task) = producer.exit { await task.value }
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
        ingressOpen = false; state = .stopping; requestProducerStop()
        let task = Task { @MainActor [self] () -> Result<Void,Error> in
            do {
                try await joinProducers(); try await joinCallbacks()
                if deleteRequested { return .success(()) }
                let store = store, generation = generation, epoch = holdEpoch, mask = unknownMask, reason = terminalReason
                let flags: UInt64 = 0x7f | (reason == .detailExhaustion ? 1 << 10 : 0) | (reason == .slotExhaustion ? 1 << 11 : 0)
                _ = try await io { try store.terminal(reason:reason ?? (mask == 0 ? .normalStop : .unknownCoverage),unknownMask:mask,generation:generation,holdEpoch:epoch,flags:flags,authorized:{true}) }
                state = .stopped; concern = nil; captureAuthority?.revoke(); store.fence(); try await cache(); return .success(())
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
                session = nil; state = .idle; concern = nil; projection = .idle; lifetime = nil; return .success(())
            } catch { fail(error); return .failure(error) }
        }
        deleteTask = task; let result = await task.value; deleteTask = nil; try result.get()
    }
    func evaluateExpiry(deleteID: UUID) async throws {
        let n = try wall(); guard n >= 0 else { throw MeetingSession.Failure.clock }
        let store = store; try await io { try store.evaluate() }; try await cache()
        if projection.expired { ingressOpen = false; state = .expired; cancelTranscription(); try await delete(id:deleteID) }
    }
    func reserveQuit() {
        quitIntent = true; ingressOpen = false; attemptAuthority?.revoke(); captureAuthority?.revoke(); store.reserveQuit(); if recognitionTask != nil { recognition.requestCancel() }
    }
    func cancelQuit() { quitIntent = false; store.cancelQuit() } // revoked producer/review/attempt authority is never restored
    var shutdownReady: Bool {
        quitIntent && !pendingStart && stopTask == nil && deleteTask == nil && producerJoin == nil && !phaseActive && phase == nil && producers.isEmpty && unclassifiedProducerTasks.isEmpty && ingress.isEmpty && submissions.isEmpty && recognitionTask == nil && transcriptionTask == nil && concern == nil && (session == nil || store.shutdownReady)
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
