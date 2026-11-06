import Foundation
import CryptoKit

public enum SurroundingTextFailure: Error { case refused }

/// Raw-only authority. Settings Codable deliberately knows nothing about this key.
public struct SurroundingTextPolicy: Codable, Equatable, Sendable {
    public let version: Int
    public let profileID: UUID
    public let target: String
    public let signature: String
    public let primary: CleanupChainIdentity
    public let scope: String
    public let requestedUTF16: Int
    public let retainedUTF16: Int
    public let retainedUTF8: Int
    public let output: String
    public var revision: UUID?
    public var digest: String?

    init(profile: DictationProfile, signature: String, primary: CleanupChainIdentity) {
        version = 1; profileID = profile.id; target = profile.target
        self.signature = signature; self.primary = primary
        scope = "preceding-only"; requestedUTF16 = 512; retainedUTF16 = 256; retainedUTF8 = 1024
        output = "pending-insertion-only;raw-history;no-retrieval;no-learning"
    }
    func hash() throws -> String {
        var value = self; value.revision = nil; value.digest = nil
        return SurroundingTextAuthority.hash(try SurroundingTextAuthority.encode(value))
    }
    var reviewed: Bool { revision != nil && digest == (try? hash()) }
}

public struct SurroundingTextGrant: Equatable, Sendable {
    let epoch: UInt64
    public let policy: SurroundingTextPolicy
    public private(set) var operationID: UUID?
    public func bound(to id: UUID) -> Self {
        precondition(operationID == nil || operationID == id)
        var copy = self; copy.operationID = id; return copy
    }
}
public struct SurroundingTextReview {
    let original: Data
    public let policy: SurroundingTextPolicy
}

public enum SurroundingTextAuthority {
    static let key = "surroundingTextContext"
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value)
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func object(_ bytes: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SurroundingTextFailure.refused }
        return root
    }
    static func closed(_ value: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(value.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw SurroundingTextFailure.refused }
    }
    /// Whole raw profile shape/order and deliberate global word/rule/style edits.
    /// Recognition, hotkeys and independently latched History permission are unrelated.
    static func signature(_ root: [String: Any], settings: Settings) throws -> String {
        var value: [String: Any] = [:]
        for key in ["profiles", "dictionary", "snippets", "replacements", "cleanupStyle"] {
            value[key] = root[key] ?? NSNull()
        }
        value["primary"] = try (try? CleanupChainIdentity.primary(settings)).map { try JSONSerialization.jsonObject(with: encode($0)) } ?? NSNull()
        // The global primary may be incomplete while this app profile supplies an
        // exact model. Observe its key-free descriptor without inventing defaults.
        value["primarySettings"] = ["provider": settings.cleanup.provider,
            "endpoint": settings.cleanup.baseURL ?? "", "model": settings.cleanup.model ?? "",
            "anthropicModel": settings.cleanupModel, "environment": settings.cleanup.apiKeyEnvVar ?? "",
            "localLocale": settings.cleanup.localSourceLocale ?? "", "localContext": settings.cleanup.localSurroundingTextEnabled]
        value["cleanupEnabled"] = settings.cleanupEnabled
        value["outputMode"] = settings.outputMode.rawValue
        value["backupPresent"] = root["cleanupFailover"] != nil
        return hash(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    static func draftSignature(_ settings: Settings) -> String? {
        guard let bytes = try? encode(settings), let root = try? object(bytes) else { return nil }
        return try? signature(root, settings: settings)
    }
    static func selected(_ id: UUID, root: [String: Any], settings: Settings) throws -> DictationProfile {
        guard let rows = root["profiles"] as? [[String: Any]], rows.count == settings.profiles.count,
              Set(settings.profiles.map(\.id)).count == settings.profiles.count,
              Set(settings.profiles.map { $0.targetKind.rawValue + ":" + $0.target }).count == settings.profiles.count,
              let index = settings.profiles.firstIndex(where: { $0.id == id }) else { throw SurroundingTextFailure.refused }
        let profile = settings.profiles[index]
        try closed(rows[index], required: ["id", "name", "targetKind", "target"], optional: ["enabled", "cleanup", "style", "recognitionEngine", "appleSpeechLocale", "parakeetModelID", "parakeetLanguageFilter", "language", "whisperModelPath", "cleanupModel", "dictionary"])
        guard profile.enabled, profile.targetKind == .app, profile.normalizedTarget == profile.target,
              !TextRules.isBrowser(bundleID: profile.target), profile.validationError == nil else { throw SurroundingTextFailure.refused }
        return profile
    }
    public static func primary(_ settings: Settings) throws -> CleanupChainIdentity {
        if settings.usesAppleIntelligence {
            return CleanupChainIdentity(provider: "apple-intelligence", endpoint: "on-device", model: "Apple Intelligence · on-device", source: "on-device", access: "on-device")
        }
        return try CleanupChainIdentity.primary(settings)
    }
    static let globalProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static func localPolicy(_ bytes: Data, target: String) throws -> SurroundingTextPolicy {
        let root = try object(bytes), settings = try JSONDecoder().decode(Settings.self, from: bytes)
        let resolved = ProfileResolver.resolve(settings, at: .init(bundleID: target))
        guard settings.usesAppleIntelligence, settings.cleanup.localSurroundingTextEnabled,
              resolved.settings.cleanupEnabled, resolved.settings.outputMode == .cleanup,
              settings.cleanupFailover == nil, !target.isEmpty, !TextRules.isBrowser(bundleID: target) else { throw SurroundingTextFailure.refused }
        var profile = resolved.profile ?? DictationProfile()
        profile.id = resolved.profile?.id ?? globalProfileID; profile.target = target
        return SurroundingTextPolicy(profile: profile, signature: try signature(root, settings: settings), primary: try primary(resolved.settings))
    }
    public static func matches(_ policy: SurroundingTextPolicy, profileID: UUID?) -> Bool {
        policy.profileID == (profileID ?? globalProfileID)
    }
    static func candidate(_ bytes: Data, profileID: UUID) throws -> SurroundingTextPolicy {
        let root = try object(bytes), settings = try JSONDecoder().decode(Settings.self, from: bytes)
        guard root["cleanupFailover"] == nil, settings.outputMode == .cleanup, settings.cleanupEnabled,
              !settings.usesAppleIntelligence else { throw SurroundingTextFailure.refused }
        let profile = try selected(profileID, root: root, settings: settings)
        let resolved = ProfileResolver.resolve(settings, at: .init(bundleID: profile.target))
        guard resolved.profile?.id == profileID, resolved.settings.cleanupEnabled,
              resolved.settings.outputMode == .cleanup else { throw SurroundingTextFailure.refused }
        // Blank/autodiscovery is never an exact requested model (including Anthropic).
        let model = resolved.settings.cleanup.provider == "openai-compatible" ? resolved.settings.cleanup.model : resolved.settings.cleanupModel
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SurroundingTextFailure.refused }
        return SurroundingTextPolicy(profile: profile, signature: try signature(root, settings: settings),
            primary: try CleanupChainIdentity.primary(resolved.settings))
    }
    static func policy(_ bytes: Data) throws -> SurroundingTextPolicy? {
        let root = try object(bytes)
        guard let raw = root[key] else { return nil }
        guard let block = raw as? [String: Any] else { throw SurroundingTextFailure.refused }
        try closed(block, required: ["version", "profileID", "target", "signature", "primary", "scope", "requestedUTF16", "retainedUTF16", "retainedUTF8", "output"], optional: ["revision", "digest"])
        guard let primary = block["primary"] as? [String: Any] else { throw SurroundingTextFailure.refused }
        try closed(primary, required: ["provider", "endpoint", "model", "source", "access"])
        guard !(block["revision"] is NSNull), !(block["digest"] is NSNull) else { throw SurroundingTextFailure.refused }
        let value = try JSONDecoder().decode(SurroundingTextPolicy.self, from: JSONSerialization.data(withJSONObject: block))
        let expected = try candidate(bytes, profileID: value.profileID)
        var bare = value; bare.revision = nil; bare.digest = nil
        guard bare == expected, (value.revision == nil) == (value.digest == nil),
              value.digest == nil || value.reviewed else { throw SurroundingTextFailure.refused }
        return value
    }
    /// Semantic preservation, including null, future and malformed values. Never repairs.
    static func preserving(_ original: Data?, in output: Data, base: Settings?, incoming: Settings) throws -> Data {
        guard let original else { return output }
        let freshRoot = try object(original)
        guard let raw = freshRoot[key] else { return output }
        var destination = try object(output)
        let fresh = try JSONDecoder().decode(Settings.self, from: original)
        if draftSignature(incoming) != draftSignature(fresh) {
            guard let base, draftSignature(base) == draftSignature(fresh) else { throw SurroundingTextFailure.refused }
            // Invalid values are preserved without attempting to repair/invalidate their schema.
            if var block = raw as? [String: Any], (try? policy(original)) != nil {
                block.removeValue(forKey: "revision"); block.removeValue(forKey: "digest"); destination[key] = block
            } else { destination[key] = raw }
        } else { destination[key] = raw }
        return try JSONSerialization.data(withJSONObject: destination, options: [.prettyPrinted, .sortedKeys])
    }
    static func observation(_ bytes: Data?) -> Data? {
        guard let bytes, let root = try? object(bytes), let settings = try? JSONDecoder().decode(Settings.self, from: bytes),
              let signature = try? signature(root, settings: settings) else { return nil }
        let raw = root[key] ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return Data(signature.utf8) + data
    }
}

/// Positive nontext proof; completely separate from paste, selected-text or full-value helpers.
public struct SurroundingTextField: Equatable, Sendable {
    public let pid: Int32
    public let window: UInt64
    public let field: UInt64
    public let app: String
    public let caret: Int
    public let selectionLength: Int
    public let safe: Bool
    public let qualified: Bool
    public let caretBoundaryProved: Bool
    public init(pid: Int32, window: UInt64, field: UInt64, app: String, caret: Int,
                selectionLength: Int = 0, safe: Bool = true, qualified: Bool = true, caretBoundaryProved: Bool = true) {
        self.pid = pid; self.window = window; self.field = field; self.app = app; self.caret = caret
        self.selectionLength = selectionLength; self.safe = safe; self.qualified = qualified; self.caretBoundaryProved = caretBoundaryProved
    }
    public var eligible: Bool { pid > 0 && window > 0 && field > 0 && caret >= 0 && selectionLength == 0 && safe && qualified && caretBoundaryProved }
    public var request: NSRange { NSRange(location: max(0, caret - min(caret, 512)), length: min(caret, 512)) }
}
public struct SurroundingTextResponse: Sendable {
    public let field: SurroundingTextField
    public let range: NSRange
    public let units: [UInt16]
    /// A qualified port proves a boundary after any explicitly discarded leading fragment.
    public let startBoundaryProved: Bool
    /// Native readers may discard an unproved leading fragment through a proved break.
    public let discardLeadingUnits: Int
    public init(field: SurroundingTextField, range: NSRange, units: [UInt16], startBoundaryProved: Bool, discardLeadingUnits: Int = 0) {
        self.field = field; self.range = range; self.units = units; self.startBoundaryProved = startBoundaryProved; self.discardLeadingUnits = discardLeadingUnits
    }
    public func prefix(expected: SurroundingTextField) throws -> SurroundingTextPrefix? {
        guard expected.eligible, field == expected, range == expected.request, range.length <= 512,
              units.count == range.length, range.location <= Int.max - range.length,
              range.location + range.length == expected.caret, startBoundaryProved,
              discardLeadingUnits >= 0, discardLeadingUnits <= units.count else { throw SurroundingTextFailure.refused }
        if units.isEmpty {
            guard expected.caret == 0, range.location == 0 else { throw SurroundingTextFailure.refused }
            return nil // ONLY exact successful zero-unit document-start response.
        }
        let bounded = Array(units.dropFirst(discardLeadingUnits))
        let text = String(decoding: bounded, as: UTF16.self)
        guard Array(text.utf16) == bounded else { throw SurroundingTextFailure.refused }
        // Starting from a proved boundary, Swift's grapheme walk cannot manufacture
        // a boundary by slicing or normalization. An overlarge final cluster refuses.
        var start = text.endIndex, size = 0, bytes = 0
        while start > text.startIndex {
            let previous = text.index(before: start), character = text[previous..<start]
            let n = character.utf16.count, b = character.utf8.count
            if size + n > 256 || bytes + b > 1024 { break }
            size += n; bytes += b; start = previous
        }
        guard size > 0 else { throw SurroundingTextFailure.refused }
        return SurroundingTextPrefix(text: String(text[start...]))
    }
}
/// Ephemeral request material, never Codable, printable, persisted or put on Session.
public struct SurroundingTextPrefix: Sendable {
    let text: String
}

/// Finite operation-owned output disposition and monotonic main-observation latch.
/// No source text, range, model response or focus token is retained here.
public final class SurroundingTextRun: @unchecked Sendable, Equatable {
    public static func == (lhs: SurroundingTextRun, rhs: SurroundingTextRun) -> Bool { lhs === rhs }
    private let lock = NSLock()
    private var attempted = false, influenced = false, accepted = false, closed = false, mismatch = false
    private var releaseAuthority: (() -> Void)?
    public init() {}
    deinit { finish() }
    /// Stores only the subscription release token, never field/prompt material.
    public func holdAuthority(_ release: @escaping () -> Void) {
        let previous = lock.withLock { let old = releaseAuthority; releaseAuthority = release; return old }
        previous?()
    }
    public func finish() {
        let release = lock.withLock { let old = releaseAuthority; releaseAuthority = nil; return old }
        release?()
    }
    public func discardAcceptedOutput() { lock.withLock { accepted = false } }
    public var participated: Bool { lock.withLock { attempted } }
    public var insertionOnly: Bool { lock.withLock { influenced } }
    public func readIssued() { lock.withLock { attempted = true } }
    public func willSend() { lock.withLock { influenced = true } }
    public func acceptedOutput() { lock.withLock { accepted = true } }
    public var insertionRequiresAuthority: Bool { lock.withLock { accepted } }
    public func revoke() { lock.withLock { closed = true } }
    public func check() throws { guard !lock.withLock({ closed || mismatch }) else { throw SurroundingTextFailure.refused } }
    public func observeModel(_ model: String, requested: String) {
        // Compare bytes, never canonically equivalent Swift String equality. No retention.
        if !model.utf8.elementsEqual(requested.utf8) { lock.withLock { mismatch = true } }
    }
    public var metrics: PipelineMetrics? { participated ? PipelineMetrics() : nil }
}
