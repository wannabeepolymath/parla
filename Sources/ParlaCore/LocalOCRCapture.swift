import Foundation

/// Reserved grammar is pure; no application, permission or capture work here.
public enum OwnedOCRInvocation: Equatable {
    case legacy, owned, refuse

    public static func parse(_ arguments: [String]) -> Self {
        func reserved(_ text: String) -> Bool {
            let prefix = Array("--owned-ocr".utf8)
            let bytes = text.utf8.prefix(prefix.count).map { byte in
                (65...90).contains(byte) ? byte + 32 : byte
            }
            return bytes == prefix
        }
        guard arguments.contains(where: reserved) else { return .legacy }
        return arguments.count == 2 && arguments[1] == "--owned-ocr-qualification" ? .owned : .refuse
    }
}

public enum LocalOCRFailure: String, Error, Codable, Sendable {
    case unsupported, permissionMissing, ownedState, identityUnlinked, metadataLimit
    case dimensions, imageFormat, observationLimit, candidateLimit, unsafeTerm, termLimit
    case revoked, expired, platform, oracleMismatch
}

public struct LocalOCRRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var finite: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

/// Direct owned fixture observations, never an AX/external-window security proof.
public struct LocalOCROwnedState: Equatable, Sendable {
    public var pid: Int32
    public var windowNumber: Int
    public var generation: UInt64
    public var frame, primaryScreen: LocalOCRRect
    public var scale: Double
    public var primary, key, visible, active, plain, collapsed: Bool
    public init(pid: Int32, windowNumber: Int, generation: UInt64, frame: LocalOCRRect,
                primaryScreen: LocalOCRRect, scale: Double, primary: Bool, key: Bool,
                visible: Bool, active: Bool, plain: Bool, collapsed: Bool) {
        self.pid = pid; self.windowNumber = windowNumber; self.generation = generation
        self.frame = frame; self.primaryScreen = primaryScreen; self.scale = scale
        self.primary = primary; self.key = key; self.visible = visible; self.active = active
        self.plain = plain; self.collapsed = collapsed
    }
    public var admissible: Bool {
        pid > 0 && windowNumber > 0 && UInt32(exactly: windowNumber) != nil && generation > 0
            && primary && key && visible && active && plain && collapsed
            && frame.finite && primaryScreen.finite && primaryScreen.x == 0 && primaryScreen.y == 0
            && scale.isFinite && scale >= 1 && scale <= 2
            && frame.width <= 640 && frame.height <= 384
            && frame.x >= 0 && frame.y >= 0
            && frame.x + frame.width <= primaryScreen.width
            && frame.y + frame.height <= primaryScreen.height
    }
    /// ONE hypothesis: primary origin (0,0), AppKit bottom-left to capture top-left.
    /// Compare each edge rounded to nearest physical pixel, ties away from zero.
    /// Never retry another coordinate rule. This does not document ID equivalence.
    public var captureFrame: LocalOCRRect {
        LocalOCRRect(x: frame.x, y: primaryScreen.height - frame.y - frame.height,
                     width: frame.width, height: frame.height)
    }
}

public struct LocalOCRDimensions: Equatable, Sendable {
    public let width, height: Int
    public static func checked(rect: LocalOCRRect, scale: Double) -> Self? {
        guard rect.finite, scale.isFinite, scale >= 1, scale <= 2,
              rect.width <= 640, rect.height <= 384 else { return nil }
        let w = (rect.width * scale).rounded(.toNearestOrAwayFromZero)
        let h = (rect.height * scale).rounded(.toNearestOrAwayFromZero)
        guard w >= 1, h >= 1, w <= 1536, h <= 1024,
              let width = Int(exactly: w), let height = Int(exactly: h) else { return nil }
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, area <= 1_048_576 else { return nil }
        return Self(width: width, height: height)
    }
    public static func framesMatch(_ lhs: LocalOCRRect, _ rhs: LocalOCRRect, scale: Double) -> Bool {
        guard lhs.finite, rhs.finite, scale.isFinite, scale >= 1, scale <= 2 else { return false }
        let a = [lhs.x, lhs.y, lhs.x + lhs.width, lhs.y + lhs.height]
        let b = [rhs.x, rhs.y, rhs.x + rhs.width, rhs.y + rhs.height]
        return zip(a, b).allSatisfy { x, y in
            let x = x * scale, y = y * scale
            return x.isFinite && y.isFinite && abs(x) < Double(Int.max) && abs(y) < Double(Int.max)
                && x.rounded(.toNearestOrAwayFromZero) == y.rounded(.toNearestOrAwayFromZero)
        }
    }
}

public struct LocalOCRImageHeader: Sendable {
    public enum Format: Sendable { case bgra8PremultipliedFirstLittleEndian, unknown }
    public var width, height, bitsPerPixel, bitsPerComponent, bytesPerRow: Int
    public var format: Format
    public init(width: Int, height: Int, bitsPerPixel: Int = 32, bitsPerComponent: Int = 8,
                bytesPerRow: Int, format: Format = .bgra8PremultipliedFirstLittleEndian) {
        self.width = width; self.height = height; self.bitsPerPixel = bitsPerPixel
        self.bitsPerComponent = bitsPerComponent; self.bytesPerRow = bytesPerRow; self.format = format
    }
    public func valid(for dimensions: LocalOCRDimensions) -> Bool {
        guard width == dimensions.width, height == dimensions.height,
              bitsPerPixel == 32, bitsPerComponent == 8,
              format == .bgra8PremultipliedFirstLittleEndian else { return false }
        let (minimum, a) = width.multipliedReportingOverflow(by: 4)
        let (bytes, b) = bytesPerRow.multipliedReportingOverflow(by: height)
        return !a && !b && bytesPerRow >= minimum && bytesPerRow > 0 && bytes <= 8 * 1_048_576
    }
}

public struct LocalOCRWindow<Handle: Sendable>: Sendable {
    public let pid: Int32?
    public let id: UInt32
    public let frame: LocalOCRRect
    public let handle: Handle
    public init(pid: Int32?, id: UInt32, frame: LocalOCRRect, handle: Handle) {
        self.pid = pid; self.id = id; self.frame = frame; self.handle = handle
    }
}
public struct LocalOCRFilter<Handle: Sendable>: Sendable {
    public let handle: Handle
    public let rect: LocalOCRRect
    public let scale: Double
    public init(handle: Handle, rect: LocalOCRRect, scale: Double) {
        self.handle = handle; self.rect = rect; self.scale = scale
    }
}
public struct LocalOCRImage<Handle: Sendable>: Sendable {
    public let handle: Handle
    public let header: LocalOCRImageHeader
    public init(handle: Handle, header: LocalOCRImageHeader) { self.handle = handle; self.header = header }
}

/// Single callback admission. Completion and owned-body exit are independent.
/// The extraction body returns before exit is marked and waiters resume. This
/// joins OUR body, never asserts that foreign framework internals have exited.
/// Lock protects every field; callback payload moves once to the awaited owner.
public final class LocalOCRCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false, completed = false, exited = false, consumed = false
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?
    public init() {}
    public var didComplete: Bool { lock.withLock { completed } }
    public var didExit: Bool { lock.withLock { exited } }
    @discardableResult public func begin() -> Bool {
        lock.withLock { guard !entered else { return false }; entered = true; return true }
    }
    public func complete(_ value: Value) {
        lock.withLock { guard entered, !completed else { return }; self.value = value; completed = true }
    }
    public func ownedBodyExited() {
        let delivery: (CheckedContinuation<Value, Never>, Value)? = lock.withLock {
            guard entered, completed, !exited else { return nil }
            exited = true
            guard let waiter, let value else { return nil }
            self.waiter = nil; self.value = nil; consumed = true
            return (waiter, value)
        }
        if let (waiter, value) = delivery { waiter.resume(returning: value) }
    }
    public func receive(_ body: () -> Value) {
        guard begin() else { return }
        complete(body()) // owned extraction has returned, including its defers
        ownedBodyExited()
    }
    public func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = lock.withLock {
                precondition(waiter == nil && !consumed, "single owned waiter")
                if exited, let value { self.value = nil; consumed = true; return value }
                waiter = continuation; return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Framework bottoms only. Issuance and owned UI proof stay on main; Vision's
/// awaited nonisolated body may occupy a generic executor until perform returns.
public protocol LocalOCRDriver: Sendable {
    associatedtype Window: Sendable
    associatedtype Filter: Sendable
    associatedtype Image: Sendable
    @MainActor var supported: Bool { get }
    @MainActor func preflight() -> Bool
    @MainActor func lookup(_ callback: LocalOCRCallback<Result<[LocalOCRWindow<Window>], LocalOCRFailure>>)
    @MainActor func filter(_ window: Window) -> Result<LocalOCRFilter<Filter>, LocalOCRFailure>
    @MainActor func capture(_ filter: Filter, dimensions: LocalOCRDimensions,
                           callback: LocalOCRCallback<Result<LocalOCRImage<Image>, LocalOCRFailure>>)
    func perform(_ image: Image, operation: PendingOperation,
                 callback: LocalOCRCallback<Result<LocalOCRProjection, LocalOCRFailure>>) async -> Bool
}

/// Candidate strings are checked individually before joins, splitting or copies.
/// Framework-created strings/observations can already exist; no foreign cap.
public struct LocalOCRProjection: Sendable {
    let terms: [String]
    public let observationCount, candidateBytes, termBytes: Int
    public static func bounded(observationCount: Int, top: (Int) -> String?) -> Result<Self, LocalOCRFailure> {
        guard observationCount >= 0, observationCount <= 64 else { return .failure(.observationLimit) }
        var candidates: [String] = [], bytes = 0
        for i in 0..<observationCount {
            guard let candidate = top(i) else { continue }
            let size = candidate.utf8.count
            guard size <= 256, bytes <= 4096 - size else { return .failure(.candidateLimit) }
            bytes += size; candidates.append(candidate)
        }
        var terms: [String] = [], seen = Set<String>(), total = 0
        for candidate in candidates {
            // Only ordinary spaces separate words; multiline/control/delimiter
            // content refuses the whole contribution, never trims into a pass.
            guard candidate.unicodeScalars.allSatisfy({ scalar in
                if scalar == " " { return true }
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                     .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
                     .nonspacingMark, .spacingMark: return true
                default: return scalar == "-" || scalar == "'"
                }
            }) else { return .failure(.unsafeTerm) }
            for word in candidate.split(separator: " ") {
                guard word.utf8.count <= 64, word.count <= 32,
                      word.allSatisfy({ $0.unicodeScalars.count <= 8 }) else { return .failure(.termLimit) }
                let normalized = String(word).precomposedStringWithCanonicalMapping.lowercased()
                guard normalized.utf8.count <= 64, normalized.count <= 32,
                      normalized.unicodeScalars.first.map({ CharacterSet.letters.union(.decimalDigits).contains($0) }) == true
                else { return .failure(.unsafeTerm) }
                guard seen.insert(normalized).inserted else { continue }
                let addition = normalized.utf8.count + (terms.isEmpty ? 0 : 1)
                guard terms.count < 16, total <= 512 - addition else { return .failure(.termLimit) }
                total += addition; terms.append(normalized)
            }
        }
        return .success(Self(terms: terms, observationCount: observationCount, candidateBytes: bytes, termBytes: total))
    }
}

public enum LocalOCROracle: String, Codable, Sendable { case pass, fail, notTested }
public enum LocalOCRFixture {
    public static let revision = 1
    public static let sentinels = ["amber", "cobalt", "willow"]
    public static let secondarySentinels = ["violet", "copper", "maple"]
    // Every rendered string is assembled from this fixed vocabulary, including
    // the title, variant selector, button and frozen status. At most 16 total.
    public static let chrome = ["owned", "ocr", "plain", "secure", "selection", "second", "close", "capture", "ready"]
    public static func oracle(_ projection: LocalOCRProjection) -> (LocalOCROracle, Int) {
        let terms = Set(projection.terms), required = Set(sentinels)
        let unexpected = terms.subtracting(required.union(chrome)).count
        return (required.isSubset(of: terms) && unexpected == 0 ? .pass : .fail, unexpected)
    }
}

/// Content-free by construction. No arbitrary platform strings or term fields.
public struct LocalOCRReceipt: Encodable, Sendable {
    public enum Overall: String, Codable, Sendable { case attemptedUnverified, notTested, fail }
    public var overall: Overall = .notTested
    public var reason: LocalOCRFailure?
    public var oracle: LocalOCROracle = .notTested
    public var unexpectedTerms = 0
    public var metadataCompleted = false, metadataOwnedBodyExited = false
    public var screenshotCompleted = false, screenshotOwnedBodyExited = false
    public var visionCompleted = false, visionOwnedBodyExited = false, visionPerformReturned = false
    public var operationExited = false, currentProcessMethodRequested = false
    public var width = 0, height = 0, observations = 0, candidateBytes = 0, terms = 0, termBytes = 0
    public var elapsedMilliseconds = 0
    public let fixtureRevision = LocalOCRFixture.revision
    public let identityProof = "UNVERIFIED"
    public let linkage = "windowNumber-equality-undocumented-observational"
    public let coordinateRule = "primary-origin-zero-top-left-edges-nearest-pixel-ties-away"
    public let metadataScope = "UNQUALIFIED"
    public let imageHasOwnerMetadata = false
    public let productQualified = false
    public let revision = 3, recognitionLevel = "accurate", language = "en-US"
    public let automaticallyDetectsLanguage = false, usesLanguageCorrection = false, customWordsCount = 0
    public let ignoreShadowsSingleWindow = true, includeChildWindows = false
    public let binaryIdentity = "UNRECORDED", signingIdentity = "UNRECORDED"
    public let osBuild = "UNRECORDED", hardware = "UNRECORDED", tccAttribution = "UNRECORDED"
    public init() {}
}

@MainActor public final class LocalOCRCapture<Driver: LocalOCRDriver> {
    private let driver: Driver
    private let clock: () -> TimeInterval
    private let state: () -> LocalOCROwnedState?
    private var started: TimeInterval = 0
    private var initial: LocalOCROwnedState?
    private var ran = false
    public private(set) var operation: PendingOperation?
    public private(set) var admitted = false
    public private(set) var receipt = LocalOCRReceipt()
    public var pending: Bool { operation.map { !$0.hasExited } ?? false }

    public init(driver: Driver, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                state: @escaping () -> LocalOCROwnedState?) {
        self.driver = driver; self.clock = clock; self.state = state
    }
    /// Called synchronously by the ONE click. Never reset this launch's latch.
    @discardableResult public func admitClick() -> Bool {
        guard !admitted else { return false }
        admitted = true; started = clock(); initial = state()
        operation = PendingOperation(name: "owned-ocr", diagnostics: nil)
        return true
    }
    public func revoke() { operation?.revoke(); operation?.requestAbort() }
    private func refusal() -> LocalOCRFailure? {
        guard let operation, !operation.shouldAbort else { return .revoked }
        let elapsed = clock() - started
        guard elapsed.isFinite, elapsed >= 0, elapsed < 2 else { return .expired }
        guard let initial, initial.admissible, state() == initial else { return .ownedState }
        return nil
    }
    private func requireCurrent() throws { if let reason = refusal() { throw reason } }
    private func linkedWindow() async throws -> Driver.Window {
        let metadata = LocalOCRCallback<Result<[LocalOCRWindow<Driver.Window>], LocalOCRFailure>>()
        receipt.currentProcessMethodRequested = true
        driver.lookup(metadata)
        let windows = await metadata.wait()
        receipt.metadataCompleted = metadata.didComplete; receipt.metadataOwnedBodyExited = metadata.didExit
        try requireCurrent()
        let catalog = try windows.get()
        guard catalog.count <= 8 else { throw LocalOCRFailure.metadataLimit }
        guard let initial else { throw LocalOCRFailure.ownedState }
        guard catalog.allSatisfy({ $0.pid == initial.pid }) else { throw LocalOCRFailure.identityUnlinked }
        let matches = catalog.filter {
            $0.id == UInt32(exactly: initial.windowNumber)
                && LocalOCRDimensions.framesMatch($0.frame, initial.captureFrame, scale: initial.scale)
        }
        guard matches.count == 1 else { throw LocalOCRFailure.identityUnlinked }
        return matches[0].handle
    }
    public func run() async -> LocalOCRReceipt {
        guard admitted, !ran, let operation else { return receipt }
        ran = true
        do {
            guard driver.supported else { throw LocalOCRFailure.unsupported }
            try requireCurrent()
            guard driver.preflight() else { throw LocalOCRFailure.permissionMissing }
            try requireCurrent()
            let selected = try await linkedWindow()
            try requireCurrent()
            let filter = try driver.filter(selected).get()
            defer { withExtendedLifetime(filter) {} }
            guard let initial, filter.scale == initial.scale,
                  LocalOCRDimensions.framesMatch(filter.rect, initial.captureFrame, scale: initial.scale),
                  let dimensions = LocalOCRDimensions.checked(rect: filter.rect, scale: filter.scale)
            else { throw LocalOCRFailure.dimensions }
            receipt.width = dimensions.width; receipt.height = dimensions.height
            try requireCurrent()
            let screenshot = LocalOCRCallback<Result<LocalOCRImage<Driver.Image>, LocalOCRFailure>>()
            driver.capture(filter.handle, dimensions: dimensions, callback: screenshot)
            let captured = await screenshot.wait()
            receipt.screenshotCompleted = screenshot.didComplete; receipt.screenshotOwnedBodyExited = screenshot.didExit
            try requireCurrent()
            let image = try captured.get()
            defer { withExtendedLifetime(image) {} }
            guard image.header.valid(for: dimensions) else { throw LocalOCRFailure.imageFormat }
            try requireCurrent()
            let vision = LocalOCRCallback<Result<LocalOCRProjection, LocalOCRFailure>>()
            let performed = await driver.perform(image.handle, operation: operation, callback: vision)
            receipt.visionPerformReturned = true
            // Do not throw/release at perform-return: a completion body can still
            // be held. Always join it even when revoked or perform failed.
            let result = await vision.wait()
            operation.requestExited()
            receipt.visionCompleted = vision.didComplete; receipt.visionOwnedBodyExited = vision.didExit
            try requireCurrent()
            guard performed else { throw LocalOCRFailure.platform }
            let projection = try result.get()
            receipt.observations = projection.observationCount; receipt.candidateBytes = projection.candidateBytes
            receipt.terms = projection.terms.count; receipt.termBytes = projection.termBytes
            let (oracle, unexpected) = LocalOCRFixture.oracle(projection)
            receipt.oracle = oracle; receipt.unexpectedTerms = unexpected
            guard oracle == .pass else { throw LocalOCRFailure.oracleMismatch }
            try requireCurrent()
            guard operation.claimFinalResult() else { throw LocalOCRFailure.revoked }
            receipt.overall = .attemptedUnverified // oracle never establishes identity
        } catch {
            receipt.reason = (error as? LocalOCRFailure) ?? .platform
            receipt.overall = receipt.currentProcessMethodRequested ? .fail : .notTested
        }
        let elapsed = clock() - started
        receipt.elapsedMilliseconds = elapsed.isFinite && elapsed >= 0 ? Int(min(elapsed * 1000, 2_147_483_647)) : 0
        operation.finish(); receipt.operationExited = operation.hasExited
        return receipt
    }
}
