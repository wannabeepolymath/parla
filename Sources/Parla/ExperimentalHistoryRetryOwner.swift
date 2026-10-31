import Foundation
import ParlaCore

/// One new-mode lease. The existing Hub task (and local processTask when used)
/// owns execution; this participant only retains/drains that same task handle.
final class ExperimentalHistoryRetryOwner {
    private var operation: PendingOperation?
    private var task: Task<LocalHistoryRetryResult, Never>?
    // Execution may finish before the Hub publishes. Revocation must still
    // remove review authority while retaining the task until its real exit.
    private var revoked = false
    private var quitting = false, restarting = false
    var busy: Bool { operation != nil }
    var admits: Bool { !quitting && !restarting && !busy }
    func reserve(_ operation: PendingOperation) -> Bool {
        guard admits else { return false }
        self.operation = operation; revoked = false; return true
    }
    func owns(_ token: UUID) -> Bool { operation?.id == token && !revoked }
    func install(_ task: Task<LocalHistoryRetryResult, Never>, token: UUID) {
        precondition(operation?.id == token); self.task = task
        if revoked || operation?.shouldAbort == true { task.cancel() }
    }
    func exited(_ token: UUID) {
        guard operation?.id == token else { return }
        task = nil
        if revoked || operation?.shouldAbort == true { operation = nil }
    }
    func discard(_ token: UUID) {
        guard operation?.id == token else { return }
        revoked = true
        operation?.revoke(); operation?.requestAbort(); task?.cancel()
        if task == nil { operation?.finish(); operation = nil }
    }
    private func revoke() {
        if let token = operation?.id { discard(token) }
    }
    func beginShutdown(_ reply: @escaping (Bool) -> Void) {
        quitting = true; revoke()
        guard let task, let token = operation?.id else { reply(true); return }
        Task { @MainActor [self] in await task.value; exited(token); reply(true) }
    }
    func cancelShutdown() { quitting = false }
    func reserveRestart() -> Bool {
        guard !quitting, !restarting else { return false }
        restarting = true; revoke(); return true
    }
    @MainActor func drainRestart() async {
        guard let task, let token = operation?.id else { return }
        await task.value; exited(token)
    }
    func releaseRestart() { restarting = false }
}
