import Foundation

/// One physical recorder and its exclusive diagnostic review/shortcut owners.
/// Main control paths acquire before starting; stale releases cannot free a newer owner.
public final class CaptureAdmission {
    public enum Owner { case dictation, microphoneTest, shortcut, guidedTemplate, meeting }
    public struct Lease: Equatable {
        public let id: UUID
        public let owner: Owner
    }
    private let lock = NSLock()
    private var current: Lease?
    private var revisionValue: UInt64 = 0
    /// Changes when an exclusion owner intervenes, even if it releases before main drains.
    public var revision: UInt64 { lock.withLock { revisionValue } }
    public var inputSnapshot: (revision: UInt64, allowed: Bool) {
        lock.withLock { (revisionValue, current == nil || current?.owner == .dictation) }
    }
    public init() {}
    public var allowsKeyboard: Bool { lock.withLock { current == nil || current?.owner == .dictation } }
    public var isAvailable: Bool { lock.withLock { current == nil } }
    public func acquire(_ owner: Owner) -> Lease? {
        lock.withLock {
            guard current == nil else { return nil }
            let lease = Lease(id: UUID(), owner: owner); current = lease; if owner != .dictation { revisionValue &+= 1 }; return lease
        }
    }
    public func owns(_ lease: Lease) -> Bool { lock.withLock { current == lease } }
    public func release(_ lease: Lease) { lock.withLock { if current == lease { current = nil } } }
}
