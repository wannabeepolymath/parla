import Foundation

/// A single request's identity and delivery authority. Copies of Session retain
/// this same token, including callbacks that outlive foreground generations.
public final class PendingOperation: Equatable, @unchecked Sendable {
    public enum Stage: String, Sendable { case queued, acquiring, recognizing, cleaning, finished, discarded }
    public enum Discard: Sendable { case discarded, deliveryAttempted, unchanged }
    public let id = UUID()
    public let name: String
    private let lock = NSLock()
    private var exited = false
    private var revoked = false
    private var deliveryAttempted = false
    private var finalResultClaimed = false
    private var stageValue: Stage = .queued
    private var abort: (() -> Void)?
    private var preparationRevocation: (UUID, () -> Void)?
    private var diagnosticValue: DiagnosticOperation?
    public var diagnostics: DiagnosticOperation? { lock.withLock { diagnosticValue } }
    public func observe(in store: DiagnosticStore, origin: DiagnosticOrigin) {
        lock.withLock { if diagnosticValue == nil { diagnosticValue = store.start(id: id, origin: origin) } }
    }

    public init(name: String, origin: DiagnosticOrigin = .unknown, diagnostics: DiagnosticStore? = nil) {
        self.name = name
        if let diagnostics { diagnosticValue = diagnostics.start(id: id, origin: origin) }
    }
    public static func == (lhs: PendingOperation, rhs: PendingOperation) -> Bool { lhs.id == rhs.id }
    public var shouldAbort: Bool { lock.withLock { revoked } }
    public var hasExited: Bool { lock.withLock { exited } }
    public var stage: Stage { lock.withLock { stageValue } }
    public func advance(_ stage: Stage) { lock.withLock { if !revoked { stageValue = stage } } }
    /// Revoke first. The caller then releases owned resources before requesting
    /// cooperative cancellation. No native call or network acknowledgement here.
    @discardableResult public func revoke(reason: DiagnosticReason = .discarded) -> Discard {
        let result: Discard = lock.withLock {
            guard !revoked, stageValue != .finished else { return .unchanged }
            revoked = true; stageValue = .discarded
            return deliveryAttempted ? .deliveryAttempted : .discarded
        }
        if result != .unchanged {
            let observer = lock.withLock { preparationRevocation?.1 }
            observer?() // independent of the child-cancel slot, always outside the operation lock
            diagnostics?.disposition(reason)
            diagnostics?.update { $0.cancellationRequested = true }
        }
        return result
    }
    public var hasFinalResult: Bool { lock.withLock { finalResultClaimed } }

    public func observePreparationRevocation(_ action: @escaping () -> Void) -> UUID {
        let token = UUID()
        let revoked = lock.withLock { preparationRevocation = (token, action); return self.revoked }
        if revoked { action() }
        return token
    }
    public func removePreparationRevocation(_ token: UUID) {
        lock.withLock { if preparationRevocation?.0 == token { preparationRevocation = nil } }
    }

    /// Final adjudication is single-shot even if native end/Stop callbacks race.
    public func claimFinalResult() -> Bool {
        lock.withLock {
            guard !revoked, !finalResultClaimed else { return false }
            finalResultClaimed = true
            return true
        }
    }
    public func requestAbort() { let action = lock.withLock { abort }; action?() }
    public func installAbort(_ action: @escaping () -> Void) {
        let cancel = lock.withLock { abort = action; return revoked }
        if cancel { action() }
    }
    public func requestExited() { lock.withLock { abort = nil } }
    public func finish() {
        lock.withLock { exited = true; abort = nil; if !revoked { stageValue = .finished } }
        diagnostics?.update { $0.operationFinished = true }
    }
    /// On main, immediately before a delivery attempt. This is not proof that
    /// the destination accepted text, or even that a failed attempt posted input.
    @discardableResult public func authorizeDispatch() -> Bool {
        lock.withLock { guard !revoked else { return false }; deliveryAttempted = true; return true }
    }
}

/// Cancel the request child, never the serial barrier. A subsequent native call
/// waits for actual exit even when an adapter ignores cooperative cancellation.
public enum PendingOperationQueue {
    public static func enqueue(previous: Task<Void, Never>?, operation: PendingOperation,
                               completes: Bool = false,
                               work: @escaping () async -> Void,
                               finished: @escaping () async -> Void = {}) -> Task<Void, Never> {
        let wait = operation.diagnostics?.begin(.queueWait)
        return Task {
            await previous?.value
            wait?.end()
            if !operation.shouldAbort {
                let child = Task { if !operation.shouldAbort { await work() } }
                operation.installAbort { child.cancel() }
                await child.value
                operation.requestExited()
            }
            if completes { operation.finish(); await finished() }
        }
    }
}
