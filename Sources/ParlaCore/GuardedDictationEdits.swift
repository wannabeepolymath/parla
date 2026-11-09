import Foundation

/// RAM-only evidence. No Codable/diagnostic projection: full field text must
/// never enter history or logs. Selection and inserted ranges use UTF-16.
public struct DictationField<Identity: Equatable>: Equatable {
    public let process: Int32
    public let bundleID: String
    public let identity: Identity
    public let value: String
    public let selection: NSRange
    public let secure: Bool

    public init(process: Int32, bundleID: String, identity: Identity, value: String,
                selection: NSRange, secure: Bool = false) {
        self.process = process; self.bundleID = bundleID; self.identity = identity
        self.value = value; self.selection = selection; self.secure = secure
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.process == rhs.process && lhs.bundleID == rhs.bundleID && lhs.identity == rhs.identity
            && lhs.value.utf16.elementsEqual(rhs.value.utf16)
            && lhs.selection == rhs.selection && lhs.secure == rhs.secure
    }

    func replacing(_ range: NSRange, with text: String, selection: NSRange) -> Self? {
        // Range conversion also rejects splitting a Unicode surrogate pair.
        guard let range = Range(range, in: value) else { return nil }
        return Self(process: process, bundleID: bundleID, identity: identity,
                    value: value.replacingCharacters(in: range, with: text), selection: selection)
    }
}

/// Uses the same read/check/set/readback contract as Inserter.replaceTypedTail.
/// AX has no conditional write; a cross-process read-to-write race remains.
/// The caller serializes access (production uses the main thread).
public final class GuardedDictationEdits<Identity: Equatable> {
    public typealias Field = DictationField<Identity>
    public enum Action { case undo, restoreRaw }
    public enum Outcome: Equatable { case replaced, refused, unverified }
    public static var lifetime: TimeInterval { 10 * 60 }
    public static var refusalMessage: String { "The text changed since Parla typed it — use Copy original text" }

    public struct Receipt {
        public let before: Field
        public let after: Field
        public let insertedRange: NSRange
        public let raw: String
        public let cleaned: String
        public let timestamp: TimeInterval
    }
    private struct Pending {
        let token: UUID
        let receipt: Receipt
    }
    private let read: () -> Field?
    private let write: (Field) -> Bool
    private let now: () -> TimeInterval
    private var pending: Pending?
    private var stored: Receipt?

    public init(read: @escaping () -> Field?, write: @escaping (Field) -> Bool,
                now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }) {
        self.read = read; self.write = write; self.now = now
    }

    public var receipt: Receipt? {
        if let stored, now() >= stored.timestamp + Self.lifetime { clear() }
        return stored
    }

    public func clear() { pending = nil; stored = nil }

    /// Called immediately before actual paste dispatch, after clipboard setup.
    /// No write here: a posted paste is still unverified.
    @discardableResult public func beginInsertion(raw: String, cleaned: String) -> UUID? {
        clear()
        guard !cleaned.isEmpty, let before = read(), !before.secure,
              let after = before.replacing(before.selection, with: cleaned,
                  selection: NSRange(location: before.selection.location + cleaned.utf16.count, length: 0)) else { return nil }
        let token = UUID()
        pending = Pending(token: token, receipt: Receipt(before: before, after: after,
            insertedRange: NSRange(location: before.selection.location, length: cleaned.utf16.count),
            raw: raw, cleaned: cleaned, timestamp: now()))
        return token
    }

    /// A bounded caller may retry READS while the posted paste reaches the app.
    /// Only exact full value, caret, app and element readback publishes authority.
    @discardableResult public func confirmInsertion(_ token: UUID, posted: Bool) -> Bool {
        guard let pending, pending.token == token else { return false }
        guard posted, now() < pending.receipt.timestamp + Self.lifetime else { clear(); return false }
        guard read() == pending.receipt.after else { return false }
        stored = pending.receipt; self.pending = nil
        return true
    }

    /// Drop an unverified attempt without affecting a newer dictation.
    public func abandonInsertion(_ token: UUID) {
        if pending?.token == token { pending = nil }
    }

    public func perform(_ action: Action) -> Outcome {
        guard let receipt else { return .refused }
        // Consume before native calls: failed or delayed writes cannot be retried.
        clear()
        let desired: Field
        switch action {
        case .undo:
            desired = Field(process: receipt.before.process, bundleID: receipt.before.bundleID,
                identity: receipt.before.identity, value: receipt.before.value,
                selection: NSRange(location: receipt.insertedRange.location, length: 0))
        case .restoreRaw:
            guard let replaced = receipt.after.replacing(receipt.insertedRange, with: receipt.raw,
                selection: NSRange(location: receipt.insertedRange.location + receipt.raw.utf16.count, length: 0)) else { return .refused }
            desired = replaced
        }
        // Last operation before the write is the fresh exact focused-field read.
        guard read() == receipt.after else { return .refused }
        let accepted = write(desired)
        let confirmed = read() == desired
        return accepted && confirmed ? .replaced : .unverified
    }
}
