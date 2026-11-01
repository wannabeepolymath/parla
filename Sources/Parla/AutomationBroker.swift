import Foundation
import ParlaCore

/// App-owned automation interface; native runtime/packaging qualification is separate.
enum AutomationFailure: String, Error, Equatable, Sendable {
    case disabled, timeout, busy, microphoneUnavailable, modelUnavailable, secure
    case staleSession, canceled, superseded, unavailable, unsupportedOutputMode, empty, minimumDuration, resultLimit, shuttingDown, waiterLimit
}
/// Process-scoped monotonic retry key. A constant high-water mark rejects old
/// requests after bounded tombstones expire, without an unbounded UUID registry.
struct AutomationRequestID: Hashable, Sendable {
    let process: UUID
    let sequence: UInt64
}
struct AutomationSessionID: Hashable, Sendable {
    let process: UUID
    let id: UUID
}
struct AutomationStart: Equatable, Sendable {
    enum Status: Equatable, Sendable { case recording, stopping, completed }
    let sessionID: AutomationSessionID
    let status: Status
}
enum AutomationCancel: Equatable, Sendable { case canceled, alreadyCanceled, alreadyCompleted }

/// A nonpolling deadline, independent of the request/native task's cooperation.
@MainActor protocol AutomationClock: AnyObject {
    var now: TimeInterval { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void
}
@MainActor final class AutomationMonotonicClock: AutomationClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
}
@MainActor protocol AutomationHost: AnyObject {
    func startAutomation() -> AutomationFailure?
    func stopAutomation(_ session: DictationSession.Session)
    func cancelAutomation(_ session: DictationSession.Session)
    func secureEvidence() -> Bool
}

@MainActor final class AutomationBroker {
    private enum Phase { case waitingForHost, starting, recording, stopping }
    private struct Active {
        let request: AutomationRequestID
        let id: AutomationSessionID
        var session: DictationSession.Session?
        var epoch: UInt64?
        var phase: Phase = .waitingForHost
        var stopRequested = false
        var deadline: (() -> Void)?
        var completionDeadline: (() -> Void)?
    }
    private struct Terminal {
        let request: AutomationRequestID
        let id: AutomationSessionID
        let operationID: UUID?
        let epoch: UInt64?
        let failure: AutomationFailure?
        let expires: TimeInterval
    }
    private enum WaitKind { case start, stop }
    private struct Waiter {
        let session: AutomationSessionID
        let kind: WaitKind
        let continuation: CheckedContinuation<AutomationFailure?, Never>
    }
    let process = UUID()
    private var issuedRequest: UInt64 = 0
    private var consumedRequest: UInt64 = 0
    func makeRequestID() -> AutomationRequestID {
        issuedRequest += 1
        return AutomationRequestID(process: process, sequence: issuedRequest)
    }
    let results: DictationResultStore
    private let clock: AutomationClock
    private let enabled: () -> Bool
    private weak var host: AutomationHost?
    private var active: Active?
    private var terminals: [Terminal] = [] // text-free, max 16, 60 seconds
    private var waiters: [UUID: Waiter] = [:] // never carry returned text
    private var shuttingDown = false
    private var disabledByUser = false
    var reservedSessionID: AutomationSessionID? { active?.id }
    var waiterCount: Int { waiters.count }
    var terminalCount: Int { prune(); return terminals.count }

    init(clock: AutomationClock, results: DictationResultStore, enabled: @escaping () -> Bool) {
        self.clock = clock; self.results = results; self.enabled = enabled
    }
    func register(_ host: AutomationHost) {
        guard !shuttingDown else { return }
        self.host = host
        launchIfReady()
    }
    private func gate() -> AutomationFailure? {
        if shuttingDown { return .shuttingDown }
        guard !disabledByUser, enabled() else { disable(); return .disabled }
        return nil
    }
    private func prune() { terminals.removeAll { clock.now >= $0.expires } }

    /// Native Start has no OS retry identity. Join only the current reservation;
    /// after it terminates, a new explicit invocation gets a broker-issued key.
    func startOrJoin() async -> Result<AutomationStart, AutomationFailure> {
        await start(requestID: active?.request ?? makeRequestID())
    }
    func validateStart(_ id: AutomationSessionID) -> AutomationFailure? {
        if Task.isCancelled { return cancelStart(id) }
        if let failure = gate() { return failure }
        prune()
        if active?.id == id { return nil }
        guard let terminal = terminals.first(where: { $0.id == id }) else { return .staleSession }
        return terminal.failure
    }

    private func cancelStart(_ id: AutomationSessionID) -> AutomationFailure {
        // Acknowledgement removes the waiter before the caller resumes.
        if active?.id == id { settle(.canceled, cancelWork: true) }
        return .canceled
    }

    func start(requestID: AutomationRequestID) async -> Result<AutomationStart, AutomationFailure> {
        if let failure = gate() { return .failure(failure) }
        if Task.isCancelled { return .failure(.canceled) }
        prune()
        if let terminal = terminals.first(where: { $0.request == requestID }) {
            if let failure = terminal.failure { return .failure(failure) }
            return .success(AutomationStart(sessionID: terminal.id, status: .completed))
        }
        if let active, active.request != requestID { return .failure(.busy) }
        if let active, active.phase == .recording || active.phase == .stopping {
            return .success(AutomationStart(sessionID: active.id, status: active.phase == .recording ? .recording : .stopping))
        }
        guard requestID.process == process, requestID.sequence > 0, requestID.sequence <= issuedRequest,
              active?.request == requestID || requestID.sequence > consumedRequest else { return .failure(.staleSession) }
        guard waiters.count < 8 else { return .failure(.waiterLimit) }
        if active == nil {
            consumedRequest = requestID.sequence
            let id = AutomationSessionID(process: process, id: UUID())
            active = Active(request: requestID, id: id)
            active?.deadline = clock.schedule(after: 5) { [weak self] in self?.expire(id) }
        }
        guard let id = active?.id else { return .failure(.unavailable) }
        let failure = await wait(id, kind: .start) { self.launchIfReady() }
        // No suspension after validation. A canceled command never reads the RAM slot.
        if Task.isCancelled { return .failure(cancelStart(id)) }
        if let failure = gate() { return .failure(failure) }
        if let failure { return .failure(failure) }
        prune()
        if let active, active.id == id {
            return .success(AutomationStart(sessionID: id, status: active.phase == .recording ? .recording : .stopping))
        }
        guard let terminal = terminals.first(where: { $0.id == id }) else { return .failure(.staleSession) }
        return terminal.failure.map { .failure($0) } ?? .success(AutomationStart(sessionID: id, status: .completed))
    }

    func stop(sessionID id: AutomationSessionID) async -> Result<DictationResultStore.Value, AutomationFailure> {
        if let failure = gate() { return .failure(failure) }
        if Task.isCancelled { return .failure(.canceled) }
        prune()
        guard id.process == process else { return .failure(.staleSession) }
        if let terminal = terminals.first(where: { $0.id == id }) { return terminalValue(terminal) }
        guard active?.id == id else { return .failure(.staleSession) }
        guard waiters.count < 8 else { return .failure(.waiterLimit) }
        let failure = await wait(id, kind: .stop) {
            guard self.active?.id == id else { return }
            self.active?.stopRequested = true
            if self.active?.phase == .recording, let session = self.active?.session {
                self.active?.phase = .stopping
                self.host?.stopAutomation(session)
            }
            if self.active?.completionDeadline == nil, self.active?.id == id {
                self.active?.completionDeadline = self.clock.schedule(after: 30) { [weak self] in self?.expire(id) }
            }
        }
        if Task.isCancelled { return .failure(.canceled) }
        if let failure = gate() { return .failure(failure) }
        if let failure { return .failure(failure) }
        prune()
        guard let terminal = terminals.first(where: { $0.id == id }) else { return .failure(.staleSession) }
        return terminalValue(terminal)
    }
    func cancel(sessionID id: AutomationSessionID) -> Result<AutomationCancel, AutomationFailure> {
        if let failure = gate() { return .failure(failure) }
        prune()
        guard id.process == process else { return .failure(.staleSession) }
        if let terminal = terminals.first(where: { $0.id == id }) {
            if terminal.failure == .canceled { return .success(.alreadyCanceled) }
            if terminal.failure == nil {
                if results.read(operationID: terminal.operationID) != nil { results.clear() }
                return .success(.alreadyCompleted)
            }
            return .failure(terminal.failure ?? .staleSession)
        }
        guard active?.id == id else { return .failure(.staleSession) }
        settle(.canceled, cancelWork: true)
        return .success(.canceled)
    }
    func getLast() -> Result<DictationResultStore.Value, AutomationFailure> {
        if let failure = gate() { return .failure(failure) }
        if Task.isCancelled { return .failure(.canceled) }
        guard host != nil else { return .failure(.unavailable) }
        guard host?.secureEvidence() != true else { results.clear(); return .failure(.secure) }
        return results.read().map { .success($0) } ?? .failure(.unavailable)
    }
    private func terminalValue(_ terminal: Terminal) -> Result<DictationResultStore.Value, AutomationFailure> {
        if let failure = terminal.failure { return .failure(failure) }
        guard host?.secureEvidence() != true else { results.clear(); return .failure(.secure) }
        guard let operationID = terminal.operationID,
              let value = results.read(operationID: operationID, epoch: terminal.epoch) else { return .failure(.unavailable) }
        return .success(value)
    }

    private func wait(_ id: AutomationSessionID, kind: WaitKind, action: () -> Void) async -> AutomationFailure? {
        let key = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .canceled); return }
                waiters[key] = Waiter(session: id, kind: kind, continuation: continuation)
                action()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelWaiter(key, session: id) } }
    }
    private func cancelWaiter(_ key: UUID, session: AutomationSessionID) {
        guard waiters[key] != nil else { return }
        if active?.id == session { settle(.canceled, cancelWork: true) }
        else { waiters.removeValue(forKey: key)?.continuation.resume(returning: .canceled) }
    }
    private func resume(_ id: AutomationSessionID, startsOnly: Bool = false, failure: AutomationFailure?) {
        let keys = waiters.compactMap { key, value in
            value.session == id && (!startsOnly || value.kind == .start) ? key : nil
        }
        for key in keys { waiters.removeValue(forKey: key)?.continuation.resume(returning: failure) }
    }
    private func launchIfReady() {
        guard let current = active, current.phase == .waitingForHost, let host else { return }
        if let failure = gate() { if active != nil { settle(failure, cancelWork: true) }; return }
        active?.phase = .starting
        if let failure = host.startAutomation(), active?.id == current.id { settle(failure, cancelWork: true) }
    }
    /// Called from the acceptance effect, BEFORE synchronous recorder effects.
    func accepted(_ session: DictationSession.Session, epoch: UInt64) {
        guard session.delivery == .resultOnly, active?.phase == .starting else { return }
        active?.session = session; active?.epoch = epoch
    }
    func acknowledged(_ session: DictationSession.Session) {
        guard active?.session?.operation == session.operation, !session.operation.shouldAbort,
              let id = active?.id else { return }
        active?.deadline?(); active?.deadline = nil
        active?.phase = .recording
        if active?.stopRequested == true {
            active?.phase = .stopping
            resume(id, startsOnly: true, failure: nil)
            host?.stopAutomation(session)
        } else {
            active?.deadline?(); active?.deadline = nil
            resume(id, startsOnly: true, failure: nil)
        }
    }
    func finalizing(_ session: DictationSession.Session) {
        guard active?.session?.operation == session.operation, let id = active?.id else { return }
        active?.phase = .stopping
        if active?.completionDeadline == nil {
            active?.completionDeadline = clock.schedule(after: 30) { [weak self] in self?.expire(id) }
        }
    }
    func finished(_ operation: PendingOperation) {
        if active?.session?.operation == operation {
            _ = operation.claimFinalResult()
            results.clear()
            settle(.unavailable, cancelWork: false)
        }
    }
    func completed(_ session: DictationSession.Session, failure: DictationResultFailure?) {
        guard active?.session?.operation == session.operation else { return }
        let mapped: AutomationFailure? = failure.map {
            switch $0 {
            case .empty: return .empty
            case .minimumDuration: return .minimumDuration
            case .unavailable: return .unavailable
            case .secure: return .secure
            case .resultLimit: return .resultLimit
            }
        }
        settle(mapped, cancelWork: false)
    }
    func discarded(_ operationID: UUID) { if active?.session?.operation.id == operationID { settle(.canceled, cancelWork: true) } }
    func preempt() { if active != nil { settle(.superseded, cancelWork: true) } }
    func configurationChanged(enabled: Bool) { disabledByUser = !enabled; if !enabled { disable() } }
    func disable() { if active != nil { settle(.disabled, cancelWork: true) }; results.clear() }
    func quit() { shuttingDown = true; if active != nil { settle(.shuttingDown, cancelWork: true) }; results.clear(); host = nil }
    private func expire(_ id: AutomationSessionID) { if active?.id == id { settle(.timeout, cancelWork: true) } }
    private func settle(_ failure: AutomationFailure?, cancelWork: Bool) {
        guard let current = active else { return }
        // Revoke before continuations OR cooperative abort. Keep the queue barrier alive.
        if cancelWork { current.session?.operation.revoke(); results.clear() }
        active = nil
        current.deadline?(); current.completionDeadline?()
        terminals.append(Terminal(request: current.request, id: current.id, operationID: current.session?.operation.id,
                                  epoch: current.epoch, failure: failure, expires: clock.now + 60))
        prune(); if terminals.count > 16 { terminals.removeFirst(terminals.count - 16) }
        resume(current.id, failure: failure)
        if cancelWork, let session = current.session {
            if let host { host.cancelAutomation(session) } else { session.operation.requestAbort() }
        }
    }
}

/// Lifecycle gate for in-app adapters. Resolving this object never constructs
/// AppDelegate, a recorder, Hub, model, provider or permission prompt.
@MainActor final class AutomationRuntime {
    static let shared: AutomationRuntime = {
        let settings = SettingsStore()
        return AutomationRuntime(clock: AutomationMonotonicClock(), enabled: {
            let value = settings.load()
            return settings.lastError == nil && value.automationEnabled
        })
    }()
    let clock: AutomationClock
    let results: DictationResultStore
    let broker: AutomationBroker
    init(clock: AutomationClock, enabled: @escaping () -> Bool) {
        self.clock = clock
        results = DictationResultStore(now: { clock.now }, schedule: { seconds, action in clock.schedule(after: seconds, action) })
        broker = AutomationBroker(clock: clock, results: results, enabled: enabled)
    }
}
