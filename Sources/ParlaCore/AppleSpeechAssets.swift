import Foundation

public enum AppleSpeechLocale {
    /// Exact explicit identifiers only. No current-locale or language-code fallback.
    public static func isValid(_ value: String) -> Bool {
        let parts = value.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "_" }
        return (2...64).contains(value.utf8.count) && (1...8).contains(parts.count)
            && parts.allSatisfy { (1...8).contains($0.utf8.count) && $0.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            } } && parts[0].utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
            && value != "auto"
    }
}
public enum AppleSpeechRefusal: String, Error, Sendable, CaseIterable {
    case unsupported, deviceUnavailable, explicitLocaleRequired, unsupportedLocale, needsPreparation
    case assetsUnavailable, reservationUnavailable, capacity, trackingUnavailable, protectedReservation
    case configuration, closed, revoked, deadline, format, conversion, input, results, native
    public var message: String {
        switch self {
        case .unsupported: return "Apple Speech needs macOS 26 or later."
        case .deviceUnavailable: return "Apple Speech is unavailable on this device."
        case .explicitLocaleRequired: return "Enter a language for Apple Speech, e.g. en-US."
        case .unsupportedLocale: return "Apple Speech doesn’t support this language. Try a regional code like en-US."
        case .needsPreparation: return "Click Set up language first."
        case .assetsUnavailable: return "The language isn’t downloaded yet. Click Set up language."
        case .reservationUnavailable: return "Set up the language again."
        case .capacity: return "Too many languages are set up. Release one you don’t use."
        case .trackingUnavailable: return "Couldn’t check your Apple Speech languages."
        case .protectedReservation: return "This language is in use, so it can’t be released."
        case .configuration: return "Choose a speech engine and language in General."
        case .closed: return "Parla is quitting."
        case .revoked: return "Canceled."
        case .deadline: return "Apple Speech took too long. Try again."
        case .format, .conversion: return "Apple Speech couldn’t read the audio."
        case .input, .results, .native: return "Apple Speech couldn’t transcribe this."
        }
    }
}
public struct AppleSpeechAssetObservation: Sendable {
    public let available: Bool
    public let supported: Bool
    public let installedLocale: Bool
    public let moduleInstalled: Bool
    public let reserved: Set<String>
    public let capacity: Int
    public init(available: Bool = true, supported: Bool = true, installedLocale: Bool = true,
                moduleInstalled: Bool = true, reserved: Set<String> = [], capacity: Int = 0) {
        self.available = available; self.supported = supported; self.installedLocale = installedLocale
        self.moduleInstalled = moduleInstalled; self.reserved = reserved; self.capacity = capacity
    }
    public func validate() throws {
        guard available else { throw AppleSpeechRefusal.deviceUnavailable }
        guard supported else { throw AppleSpeechRefusal.unsupportedLocale }
    }
    public func validateInstalled() throws {
        try validate()
        guard installedLocale, moduleInstalled else { throw AppleSpeechRefusal.assetsUnavailable }
    }
}
public struct AppleSpeechProgress: Sendable, Equatable {
    public let fraction: Double?
    public let cancellable: Bool
    public init(fraction: Double?, cancellable: Bool) {
        self.fraction = fraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        self.cancellable = cancellable
    }
}
public protocol AppleSpeechInstallation: AnyObject {
    func download(progress: @escaping (AppleSpeechProgress) -> Void) async throws
    func cancel()
}
/// Only explicit Prepare owns these mutation ports. Recognition receives an installed-use closure.
public struct AppleSpeechAssets {
    public var observe: (String) async throws -> AppleSpeechAssetObservation
    public var reserve: (String) async throws -> Bool
    public var installation: (String) async throws -> AppleSpeechInstallation?
    public var release: (String) async -> Bool
    public init(observe: @escaping (String) async throws -> AppleSpeechAssetObservation,
                reserve: @escaping (String) async throws -> Bool,
                installation: @escaping (String) async throws -> AppleSpeechInstallation?,
                release: @escaping (String) async -> Bool) {
        self.observe = observe; self.reserve = reserve; self.installation = installation; self.release = release
    }
}
public struct AppleSpeechReservationRecord: Codable, Equatable {
    public enum State: String, Codable { case intent, owned, preparedUnknown, releasing }
    public struct Entry: Codable, Equatable {
        public let locale: String
        public var state: State
        public var prepared: Bool
        public init(locale: String, state: State, prepared: Bool = false) { self.locale = locale; self.state = state; self.prepared = prepared }
    }
    public let schema: Int
    public var entries: [Entry]
    public init(entries: [Entry] = []) { schema = 1; self.entries = entries }
    public static let maxBytes = 16_384
    public func encoded() throws -> Data {
        try validate(); let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maxBytes else { throw AppleSpeechRefusal.trackingUnavailable }; return data
    }
    public static func decode(_ data: Data?) throws -> Self {
        guard let data else { return Self() }
        guard data.count <= maxBytes else { throw AppleSpeechRefusal.trackingUnavailable }
        let result = try JSONDecoder().decode(Self.self, from: data); try result.validate(); return result
    }
    public func validate() throws {
        guard schema == 1, entries.count <= 32, Set(entries.map(\.locale)).count == entries.count,
              entries.allSatisfy({ AppleSpeechLocale.isValid($0.locale) && [.owned, .preparedUnknown].contains($0.state) }) else {
            throw AppleSpeechRefusal.trackingUnavailable
        }
    }
    /// Intent/releasing records are deliberately readable only as uncertainty after a crash.
    public func encodedIntent() throws -> Data {
        guard schema == 1, entries.count <= 32, Set(entries.map(\.locale)).count == entries.count,
              entries.allSatisfy({ AppleSpeechLocale.isValid($0.locale) }) else { throw AppleSpeechRefusal.trackingUnavailable }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maxBytes else { throw AppleSpeechRefusal.trackingUnavailable }; return data
    }
}
/// Injected monotonic clock: tests never call a Speech or audio API.
public struct AppleSpeechClock {
    public var now: () -> TimeInterval
    public var wait: (TimeInterval) async throws -> Void
    public init(now: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
                wait: @escaping (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 180)) * 1e9))
                }) { self.now = now; self.wait = wait }
}
/// Thread-safe scalar reference set. Retirement performs no IO/native calls and can run at actual owner deinit.
public final class AppleSpeechLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [UUID: (String, PendingOperation)] = [:]
    public init() {}
    public var count: Int { lock.withLock { live.count } }
    public func contains(_ locale: String) -> Bool { lock.withLock { live.values.contains { $0.0 == locale } } }
    public var operations: [PendingOperation] { lock.withLock { live.values.map { $0.1 } } }
    public func retain(locale: String, operation: PendingOperation) -> AppleSpeechLease {
        let id = UUID(); lock.withLock { live[id] = (locale, operation) }
        return AppleSpeechLease(operation: operation) { [self] in _ = lock.withLock { live.removeValue(forKey: id) } }
    }
}
/// A once-only lease. Native workers retain it through all collector/cancellation joins.
public final class AppleSpeechLease {
    private let lock = NSLock()
    public let operation: PendingOperation
    private var retirement: (() -> Void)?
    public init(operation: PendingOperation = PendingOperation(name: "Apple Speech use"), retirement: @escaping () -> Void) {
        self.operation = operation; self.retirement = retirement
    }
    public func release() { let action = lock.withLock { let a = retirement; retirement = nil; return a }; action?() }
    deinit { release() }
}
