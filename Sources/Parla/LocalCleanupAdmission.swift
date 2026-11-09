import Foundation
import ParlaCore

/// Local cleanup and eligible B21 admission/drain only; the app's existing processTask is the sole queue.
/// No preparation journal, timeout, native kill or old-operation resumption.
@MainActor final class LocalCleanupAdmission {
    private var quitting = false, restart = false
    private var operations: [UUID: PendingOperation] = [:]
    private var ordinaryOwner: UUID?
    var ordinaryBusyReason: String? {
        ordinaryOwner != nil || quitting || restart ? "Finishing the last dictation…" : nil
    }
    var hasOrdinaryFailover: Bool { ordinaryOwner != nil }
    func admitOrdinaryFailover(_ operation: PendingOperation) -> Bool {
        guard !quitting, !restart, !operation.shouldAbort, ordinaryOwner == nil || ordinaryOwner == operation.id else { return false }
        ordinaryOwner = operation.id; operations[operation.id] = operation; return true
    }
    func admit(_ operation: PendingOperation) -> Bool {
        guard !quitting, !restart, !operation.shouldAbort else { return false }
        operations[operation.id] = operation
        return true
    }
    func exited(_ operation: PendingOperation) {
        operations[operation.id] = nil
        if ordinaryOwner == operation.id { ordinaryOwner = nil }
    }
    private func revoke() {
        for operation in operations.values { operation.revoke(); operation.requestAbort() }
    }
    func beginShutdown(chain: () -> Task<Void, Never>?, reply: @escaping (Bool) -> Void) {
        quitting = true; revoke()
        guard !operations.isEmpty else { reply(true); return }
        let barrier = chain()
        Task { [self] in
            await barrier?.value
            reply(operations.isEmpty)
        }
    }
    func cancelShutdown() { quitting = false }
    func reserveRestart() -> Bool {
        guard !quitting, !restart else { return false }
        restart = true; revoke(); return true
    }
    func releaseRestart() { restart = false }
}

typealias LocalHistoryRetryResult = Result<(String, HistoryRetryProvenance), Error>
typealias LocalHistoryRetryScheduler = (PendingOperation, @escaping () async -> LocalHistoryRetryResult) async -> LocalHistoryRetryResult

/// Same bridge used by AppDelegate and model-free Hub integration tests. Queue
/// completion settles even cancellation before dequeue; no outer abort slot.
@MainActor enum LocalHistoryRetryQueue {
    final class Completion {
        var result: LocalHistoryRetryResult = .failure(CancellationError())
    }
    static func enqueue(previous: Task<Void, Never>?, operation: PendingOperation,
                        work: @escaping () async -> LocalHistoryRetryResult,
                        done: @escaping (LocalHistoryRetryResult) -> Void) -> Task<Void, Never> {
        let completion = Completion()
        return PendingOperationQueue.enqueue(previous: previous, operation: operation, completes: true, work: {
            let result = await work()
            await MainActor.run { completion.result = result }
        }, finished: {
            await MainActor.run { done(operation.shouldAbort ? .failure(CancellationError()) : completion.result) }
        })
    }
}
