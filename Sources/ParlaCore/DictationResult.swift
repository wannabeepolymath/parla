import Foundation

/// Final adjudication only. No provider error body, raw/audio or destination extras.
public enum DictationResultFailure: String, Error, Equatable, Sendable {
    case empty, minimumDuration, unavailable, secure, resultLimit
}
public enum DictationResultOutcome: String, Equatable, Sendable { case final, localFallback }
public enum DictationFinalResult: Equatable, Sendable {
    case text(String, DictationResultOutcome)
    case failure(DictationResultFailure)
}

/// One logical RAM copy. Clearing retrieval never revokes keyboard delivery/history.
/// Call on main through the invocation host/broker; no saved-history fallback.
@MainActor public final class DictationResultStore {
    public struct Value: Equatable, Sendable {
        public let operationID: UUID
        public let text: String
        public let outcome: DictationResultOutcome
    }
    private struct Entry {
        let value: Value
        let operation: PendingOperation
        let epoch: UInt64
        let expires: TimeInterval
    }
    public static let byteLimit = 64 * 1024
    public static let lifetime: TimeInterval = 5 * 60
    public private(set) var epoch: UInt64 = 0
    private var owner: PendingOperation?
    private var entry: Entry?
    public typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private var cancelExpiry: (() -> Void)?
    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: @escaping Schedule = { seconds, action in
                    let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
                    return { item.cancel() }
                }) { self.now = now; self.schedule = schedule }
    @discardableResult public func begin(_ operation: PendingOperation) -> UInt64 {
        clear(); owner = operation; return epoch
    }
    public func clear() { cancelExpiry?(); cancelExpiry = nil; epoch &+= 1; entry = nil; owner = nil }
    public func invalidate(operationID: UUID) { if owner?.id == operationID { clear() } }
    @discardableResult public func publish(_ result: DictationFinalResult, operation: PendingOperation,
                                          epoch expected: UInt64) -> DictationResultFailure? {
        guard epoch == expected, owner == operation, !operation.shouldAbort else { return .unavailable }
        switch result {
        case .failure(let failure): entry = nil; return failure
        case .text(let text, let outcome):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { entry = nil; return .empty }
            guard text.utf8.count <= Self.byteLimit else { entry = nil; return .resultLimit }
            guard entry == nil else { return nil } // never refresh a published result
            entry = Entry(value: Value(operationID: operation.id, text: text, outcome: outcome),
                          operation: operation, epoch: epoch, expires: now() + Self.lifetime)
            cancelExpiry = schedule(Self.lifetime) { [weak self] in
                guard let self, self.epoch == expected else { return }; self.clear()
            }
            return nil
        }
    }
    public func read(operationID: UUID? = nil, epoch expected: UInt64? = nil) -> Value? {
        guard let entry else { return nil }
        guard now() < entry.expires else { clear(); return nil }
        guard entry.epoch == epoch, expected == nil || expected == epoch,
              owner == entry.operation, !entry.operation.shouldAbort,
              operationID == nil || operationID == entry.value.operationID else { return nil }
        return entry.value
    }
}
