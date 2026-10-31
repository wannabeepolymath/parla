import Foundation

/// Quartz other-button numbers only. Product labels use the usual 1-based
/// numbering (middle = 3); left/right can never be constructed or decoded.
public struct MouseButtonBinding: Codable, Equatable, Sendable {
    public static let supportedNumbers = 2...15
    public let buttonNumber: Int
    public init?(buttonNumber: Int) {
        guard Self.supportedNumbers.contains(buttonNumber) else { return nil }
        self.buttonNumber = buttonNumber
    }
    public var display: String { buttonNumber == 2 ? "Middle" : "Button \(buttonNumber + 1)" }
    private enum CodingKeys: String, CodingKey { case buttonNumber }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let number = try c.decode(Int.self, forKey: .buttonNumber)
        guard let binding = Self(buttonNumber: number) else {
            throw DecodingError.dataCorruptedError(forKey: .buttonNumber, in: c, debugDescription: "Choose middle or an extra mouse button (3–16).")
        }
        self = binding
    }
}

/// Main publishes capture authority; the native callback only reads this cache.
/// A non-mouse accepted start invalidates mouse downs still queued for main.
public final class PhysicalInputAuthority {
    public enum Source { case none, keyboard, mouse, automation }
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var source = Source.none
    public init() {}
    public var snapshot: (epoch: UInt64, allowsMouse: Bool) {
        lock.withLock { (epoch, source != .keyboard) }
    }
    public func invalidateQueuedMouseStarts() { lock.withLock { epoch &+= 1 } }
    public func setSource(_ source: Source) { lock.withLock { self.source = source } }
}

/// One consumed native down, independent of the current binding and of reducer
/// ownership. Cancellation revokes start authority, never the release debt.
public final class MousePress: Equatable, @unchecked Sendable {
    public let id = UUID()
    public let button: Int
    public let inputEpoch: UInt64
    public let admissionRevision: UInt64
    public let suspensionRevision: UInt64
    let downAt: TimeInterval
    let tracksPhysicalState: Bool
    private let lock = NSLock()
    private var valid = true
    init(button: Int, at time: TimeInterval, tracksPhysicalState: Bool,
         inputEpoch: UInt64, admissionRevision: UInt64, suspensionRevision: UInt64) {
        self.button = button; downAt = time; self.tracksPhysicalState = tracksPhysicalState
        self.inputEpoch = inputEpoch; self.admissionRevision = admissionRevision; self.suspensionRevision = suspensionRevision
    }
    public var isValid: Bool { lock.withLock { valid } }
    public func invalidate() { lock.withLock { valid = false } }
    public static func == (lhs: MousePress, rhs: MousePress) -> Bool { lhs.id == rhs.id }
}

public enum MouseInputEdge {
    case down(MousePress)
    case up(MousePress, short: Bool)
    case cancel(MousePress)
}
public enum MouseButtonState { case down, up, unknown }
public enum InputTapStatus: Equatable {
    case ready, unavailable, disabled, invalidPort, permissionLost
    public var message: String {
        switch self {
        case .ready: return "Mouse trigger ready."
        case .unavailable: return "Mouse trigger disabled: global input unavailable. Retrying automatically."
        case .disabled: return "Mouse trigger paused: global input interrupted. Retrying automatically."
        case .invalidPort: return "Mouse trigger disabled: global input disconnected. Retrying automatically."
        case .permissionLost: return "Mouse trigger disabled: enable Accessibility access. Retrying automatically."
        }
    }
}
