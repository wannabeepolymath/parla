import Foundation

/// One capture's diagnostic ownership, independent of stop/cancel policy. The
/// recorder supplies scalar facts; a deadline observes them without ending it.
/// Call on the capture owner (main); only the recorder's snapshot crosses threads.
public final class CaptureDiagnosticCoordinator {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let snapshot: (UUID) -> CaptureDiagnosticState?
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private var operation: PendingOperation?
    private var cancelDeadline: (() -> Void)?
    public init(snapshot: @escaping (UUID) -> CaptureDiagnosticState?,
                now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
                schedule: @escaping Schedule = { delay, action in
                    let item = DispatchWorkItem(block: action)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                    return { item.cancel() }
                }) {
        self.snapshot = snapshot; self.now = now; self.schedule = schedule
    }
    public func start(operation: PendingOperation?, capture: (UUID?) throws -> Void) throws {
        if let previous = self.operation {
            if let facts = snapshot(previous.id) { previous.diagnostics?.observeCapture(facts, stopped: true) }
            previous.diagnostics?.disposition(.supersededCapture)
            previous.diagnostics?.update { $0.capture = .canceled }
        }
        clear()
        self.operation = operation
        let setup = operation?.diagnostics?.begin(.captureSetup); defer { setup?.end() }
        do { try capture(operation?.id) }
        catch {
            operation?.diagnostics?.update { $0.capture = .captureFailure }
            clear(); throw error
        }
        guard let operation, let facts = snapshot(operation.id) else { return }
        operation.diagnostics?.observeCapture(facts)
        let deadline = facts.started + CaptureDiagnosticState.firstPCMDeadline
        cancelDeadline = schedule(max(0, deadline - now())) { [weak self, operation] in
            guard let self, self.operation == operation, let facts = self.snapshot(operation.id) else { return }
            operation.diagnostics?.observeCapture(facts, deadline: true)
        }
    }
    public func stop(discard: Bool, capture: () -> [Float]) -> [Float] {
        cancelDeadline?(); cancelDeadline = nil
        let samples = capture()
        if let operation, let facts = snapshot(operation.id) {
            operation.diagnostics?.observeCapture(facts, stopped: true)
            if discard { operation.diagnostics?.update { $0.capture = .canceled } }
        }
        operation = nil
        return samples
    }
    public func clear() { cancelDeadline?(); cancelDeadline = nil; operation = nil }
    deinit { cancelDeadline?() }
}
