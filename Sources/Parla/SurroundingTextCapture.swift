import Foundation
import ParlaCore

/// An issued read returns/throws only after its work and handoffs have exited.
/// Construction is inert. New backends must use open, not the fake initializer.
struct SurroundingTextRead {
    let value: () async throws -> SurroundingTextResponse
    let cancel: () -> Void
    init(value: @escaping () async throws -> SurroundingTextResponse, cancel: @escaping () -> Void = {}) {
        self.value = value; self.cancel = cancel
    }
}

/// An awaitable one-shot memory latch. There is one read/notification consumer.
/// yield only signals that fixed waiter; no onTermination/backend callback exists.
/// Cancellation never drops backend state or runs a supplied function inline.
private final class SurroundingTextCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    let events: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    init() {
        var continuation: AsyncStream<Void>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        signal = continuation
    }
    func cancel() {
        let first = lock.withLock { if canceled { return false }; canceled = true; return true }
        if first { signal.yield(()) }
    }
    func check() throws {
        guard !lock.withLock({ canceled }) else { throw SurroundingTextFailure.refused }
    }
    var isCanceled: Bool { lock.withLock { canceled } }
}

/// Operation-owned proof/read lifecycle shared by native and synthetic ports.
/// Jobs are sequential in the caller's lane. A backend must retain any internal
/// handoffs until its nonthrowing finish returns; cancellation is never exit.
final class SurroundingTextOperation: @unchecked Sendable {
    typealias Admit = () throws -> TimeInterval
    private struct Backend {
        let proof: (@escaping Admit) async throws -> SurroundingTextField?
        let issue: @MainActor (SurroundingTextField, NSRange, TimeInterval, @escaping Admit) throws -> SurroundingTextRead
        let finish: () async -> Void
    }
    let operationID: UUID
    let target: String
    private let lock = NSLock()
    private let cancellation = SurroundingTextCancellation()
    private var backend: Backend?
    private var read: SurroundingTextRead?
    private var sealedField: SurroundingTextField? // Comparison only, never returned as a fresh proof.
    private var issued = false, readStarted = false
    private var closing = false, finishing = false, finished = false
    private var jobs = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// All supplied construction is inert. proof must observe anew on every call,
    /// using admit immediately before entry, outside all backend/store locks.
    init(operationID: UUID, target: String,
         proof: @escaping (@escaping Admit) async throws -> SurroundingTextField?,
         issue: @escaping @MainActor (SurroundingTextField, NSRange, TimeInterval, @escaping Admit) throws -> SurroundingTextRead,
         finishAndWaitForExit: @escaping () async -> Void = {}) {
        self.operationID = operationID; self.target = target
        backend = Backend(proof: proof, issue: issue, finish: finishAndWaitForExit)
    }
    /// Safe even under Settings' recursive lock: fixed latch signal only. The
    /// owned read relay below delivers legacy cancellation OUTSIDE that stack.
    func cancel() { cancellation.cancel() }
    func checkCancellation() throws { try cancellation.check() }
    private func begin() throws -> Backend {
        try cancellation.check()
        return try lock.withLock {
            guard !closing, let backend else { throw SurroundingTextFailure.refused }
            jobs += 1; return backend
        }
    }
    private func end() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            jobs -= 1; precondition(jobs >= 0)
            guard jobs == 0 else { return [] }
            let waiters = idleWaiters; idleWaiters = []; return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func proof(admit: @escaping Admit) async throws -> SurroundingTextField? {
        let backend = try begin(); defer { end() }
        _ = try admit(); try cancellation.check()
        let field = try await backend.proof(admit)
        _ = try admit(); try cancellation.check()
        let matches = lock.withLock {
            if let sealedField { return field == sealedField }
            if let field, field.eligible, field.app == target { sealedField = field }
            return true
        }
        guard matches else { cancel(); throw SurroundingTextFailure.refused }
        return field
    }
    @MainActor func issue(_ field: SurroundingTextField, range: NSRange, admit: @escaping Admit) throws -> SurroundingTextRead {
        let backend = try begin(); defer { end() }
        let remaining = try admit(); try cancellation.check()
        guard field.app == target, field.eligible, range == field.request,
              remaining.isFinite, remaining > 0 else { throw SurroundingTextFailure.refused }
        try lock.withLock {
            guard !issued, sealedField == field else { throw SurroundingTextFailure.refused }; issued = true
        }
        // No grant action or scope lock surrounds this inert MainActor callback.
        let read = try backend.issue(field, range, remaining, admit)
        lock.withLock { self.read = read }
        return SurroundingTextRead(value: { try await self.value(admit: admit) }, cancel: { self.cancel() })
    }
    private func value(admit: @escaping Admit) async throws -> SurroundingTextResponse {
        // Count even a canceled, armed handle until its cancellation/cleanup exits.
        let read: SurroundingTextRead = try lock.withLock {
            guard !closing, !readStarted, let read = self.read else { throw SurroundingTextFailure.refused }
            readStarted = true; jobs += 1; return read
        }
        defer { end() }
        let latch = cancellation
        // One owned notification task, not an admission queue/native worker.
        // A buffered signal covers cancellation before this task starts. Joining
        // this task includes the legacy callback's real return, even if it stalls.
        let relay = Task {
            for await _ in latch.events { break }
            if latch.isCanceled { read.cancel() }
        }
        let result: Result<SurroundingTextResponse, Error>
        do {
            _ = try admit(); try latch.check()
            let response = try await withTaskCancellationHandler(operation: { try await read.value() }, onCancel: { latch.cancel() })
            result = .success(response)
        } catch { result = .failure(error) }
        relay.cancel(); await relay.value
        // No supplied callback or captured backend is destroyed under cancel's lock.
        let released = lock.withLock { let old = self.read; self.read = nil; return old }
        withExtendedLifetime(released) {}
        _ = try admit(); try latch.check()
        return try result.get()
    }
    private func waitForIdle() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if jobs == 0 { return true }; idleWaiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    private func waitForExit() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if finished { return true }; exitWaiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    /// Unconditional, nonthrowing, idempotent close/join. Normal close does not
    /// cancel the latch or revoke output authority. Unknown exit keeps the lane.
    func finishAndWaitForExit() async {
        let leader = lock.withLock {
            guard !finishing else { return false }
            closing = true; finishing = true; return true
        }
        guard leader else { await waitForExit(); return }
        await waitForIdle()
        await drainBackend()
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            finished = true; let waiters = exitWaiters; exitWaiters = []; return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    private func drainBackend() async {
        let retained = lock.withLock { () -> (Backend?, SurroundingTextRead?) in
            let retained = (backend, read); backend = nil; read = nil; return retained
        }
        // Armed-but-never-started cleanup is outside Settings and scope locks.
        retained.1?.cancel()
        await retained.0?.finish()
        // This entire frame (including supplied closures) returns before any
        // finish waiter is resumed or successful authority can be handed off.
    }
}

struct SurroundingTextPort {
    let open: (UUID, String) -> SurroundingTextOperation?
    init(open: @escaping (UUID, String) -> SurroundingTextOperation?) { self.open = open }
    /// Explicit fake compatibility only. These synthetic callbacks keep their
    /// MainActor contract/default boundary authority; native adapters may not use it.
    init(proof: @escaping @MainActor () -> SurroundingTextField?,
         issue: @escaping @MainActor (SurroundingTextField, NSRange, TimeInterval) throws -> SurroundingTextRead) {
        open = { id, target in
            SurroundingTextOperation(operationID: id, target: target, proof: { admit in
                return try await MainActor.run { _ = try admit(); return proof() } // Fresh fake observation.
            }, issue: { field, range, remaining, admit in
                _ = try admit(); return try issue(field, range, remaining)
            })
        }
    }
    // Genuinely inert: no proof, policy, subscription, watchdog, timer or job.
    static let unsupported = SurroundingTextPort(open: { _, _ in nil })
}

/// Pipeline invokes this lazily only in its ordinary provider branch. Stage A
/// changes ownership, not Core policy/serializers, credentials, HTTP or sinks.
enum SurroundingTextCapture {
    static func clean(session: DictationSession.Session, landed: DictationSession.Landed,
        transcript: String, context: CleanupContext, store: SettingsStore, environment: [String: String],
        port: SurroundingTextPort, driver: @escaping HistoryRetryHTTP.Driver,
        now: @escaping () -> TimeInterval, sleep: ((TimeInterval) async throws -> Void)?,
        disarmLearning: @escaping @MainActor () -> Void,
        localRuntime: LocalCleanupRuntime = LocalCleanupRuntime()) async throws -> String? {
        guard let grant = session.surroundingTextGrant, session.delivery == .keyboard,
              session.mode == .dictation, !session.live, landed.landing == .pending,
              session.effectiveSettings.outputMode == .cleanup, session.effectiveSettings.cleanupEnabled,
              session.effectiveSettings.cleanupFailover == nil,
              SurroundingTextAuthority.matches(grant.policy, profileID: session.output?.profile?.id), landed.bundleID == grant.policy.target,
              !TextRules.isBrowser(bundleID: landed.bundleID),
              (try? SurroundingTextAuthority.primary(session.effectiveSettings)) == grant.policy.primary,
              !session.operation.shouldAbort else { return nil }
        guard let scope = port.open(session.operation.id, grant.policy.target) else { return nil }
        let run = session.surroundingTextRun
        // Begins before the first supported metadata job, not after its proof.
        let policy = HistoryRetryExecutionPolicy(planned: 1, budget: 15, now: now,
            sleep: sleep ?? { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) })
        func pureAdmission(before phaseDeadline: TimeInterval? = nil) throws -> TimeInterval {
            try policy.check(); try run.check(); try scope.checkCancellation()
            guard scope.operationID == session.operation.id, scope.target == grant.policy.target,
                  !session.operation.shouldAbort, !Task.isCancelled else { throw SurroundingTextFailure.refused }
            let current = now(), end = min(phaseDeadline ?? policy.deadline, policy.deadline)
            guard current.isFinite, end.isFinite, current < end else { throw SurroundingTextFailure.refused }
            return end - current
        }
        func admit(before phaseDeadline: TimeInterval? = nil) throws -> TimeInterval {
            try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {
                try pureAdmission(before: phaseDeadline)
            }
        }
        func proof(_ field: SurroundingTextField, before deadline: TimeInterval? = nil) async throws {
            guard try await scope.proof(admit: { try admit(before: deadline) }) == field else {
                run.revoke(); throw SurroundingTextFailure.refused
            }
        }
        return try await withTaskCancellationHandler(operation: {
            var unsubscribe: (() -> Void)?
            let outcome: Result<String?, Error>
            do {
                _ = try admit()
                unsubscribe = try store.subscribeSurroundingText(grant, operationID: session.operation.id,
                    cancel: { [weak run, weak policy, weak scope] in
                        run?.revoke(); scope?.cancel(); policy?.stop(.canceled)
                    })
                // Keep this slot for the WHOLE scope, including quiescent HTTP.
                // HTTP independently subscribes/cancels/joins completion plus exit.
                policy.installCancellation { [weak scope] in scope?.cancel() }
                let result: String? = try await policy.joined {
                    guard let field = try await scope.proof(admit: { try admit() }),
                          field.eligible, field.app == grant.policy.target else { return nil }
                    let readDeadline = now() + 1
                    try await proof(field, before: readDeadline)
                    // Pure arming action precedes the unlocked MainActor callback.
                    try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {
                        _ = try pureAdmission(before: readDeadline); run.readIssued()
                    }
                    await MainActor.run { disarmLearning() }
                    _ = try admit(before: readDeadline)
                    let read = try await scope.issue(field, range: field.request, admit: { try admit(before: readDeadline) })
                    let response = try await read.value()
                    try await proof(field, before: readDeadline)
                    _ = try admit(before: readDeadline)
                    guard let prefix = try response.prefix(expected: field) else { return nil }
                    try policy.reserve(512 * 2 + 1024 + 16 * 1024 * 4)
                    var remaining = 16 * 1024
                    func charge(_ text: String) throws {
                        let size = text.utf8.count
                        guard size <= remaining else { throw SurroundingTextFailure.refused }; remaining -= size
                    }
                    try charge(transcript)
                    for word in context.dictionary { try charge(word) }
                    for (trigger, expansion) in context.snippets { try charge(trigger); try charge(expansion) }
                    var requestContext = context; requestContext.precedingText = prefix
                    guard PromptBuilder.system(context: requestContext).utf8.count + PromptBuilder.user(transcript: transcript, context: requestContext).utf8.count <= 16 * 1024 else { throw SurroundingTextFailure.refused }
                    _ = try admit()
                    let access = try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {
                        try policy.check(); try run.check()
                        return try prepareCleanupAccess(settings: session.effectiveSettings, env: environment, credentials: store.credentials)
                    }
                    // Ordinary credential preparation can be interactive as before.
                    // Fresh proof follows it; HTTP construction/resume has no proof.
                    try await proof(field); _ = try admit()
                    run.willSend()
                    let construct = { try makeSurroundingTextCleanupClient(settings: session.effectiveSettings,
                        access: access, grant: grant, operationID: session.operation.id, store: store,
                        run: run, policy: policy, driver: driver, localRuntime: localRuntime, shouldContinue: { !session.operation.shouldAbort }) }
                    let client = try session.operation.diagnostics.map { diagnostic in
                        try diagnostic.makeProvider(settings: session.effectiveSettings, factory: construct)
                    } ?? construct()
                    let result = try await client.clean(transcript: transcript, context: requestContext)
                    _ = try admit(); try await proof(field); _ = try admit()
                    return result
                }
                if result != nil {
                    // joined has waited for the watchdog's real return. The last
                    // metadata job remains covered by the outer parent handler.
                    guard let field = try await scope.proof(admit: { try admit() }), field.eligible else {
                        run.revoke(); throw SurroundingTextFailure.refused
                    }
                    // scope.proof compared a NEW observation with its sealed
                    // first field. Private backend evidence must also match.
                    _ = try admit()
                }
                outcome = .success(result)
            } catch { outcome = .failure(error) }

            // No throwing path, nil result or canceled task can bypass close/join.
            await scope.finishAndWaitForExit()
            policy.installCancellation {} // Only now clear transient scope captures.
            do {
                let result = try outcome.get()
                if result != nil {
                    // Old subscription still covers revoke while a fresh validated
                    // run-only callback/token is installed. No backend edge survives.
                    let release = try store.subscribeSurroundingText(grant, operationID: session.operation.id,
                        cancel: { [weak run] in run?.revoke() })
                    unsubscribe?(); unsubscribe = nil
                    do {
                        try store.withSurroundingTextGrant(grant, operationID: session.operation.id) {
                            _ = try pureAdmission(); run.acceptedOutput()
                        }
                    } catch { release(); throw error }
                    run.holdAuthority(release)
                } else if run.participated {
                    // The only successful participated nil is exact empty start.
                    _ = try admit()
                } else {
                    guard !Task.isCancelled, !session.operation.shouldAbort else { throw SurroundingTextFailure.refused }
                }
                unsubscribe?(); return result
            } catch {
                unsubscribe?()
                if !run.participated, !Task.isCancelled, !session.operation.shouldAbort {
                    // Category uses its own ordinary authority in Pipeline/factory.
                    return nil
                }
                run.revoke()
                throw SurroundingTextFailure.refused
            }
        }, onCancel: { [weak run, weak policy, weak scope] in
            run?.revoke(); scope?.cancel(); policy?.stop(.canceled)
        })
    }
}
