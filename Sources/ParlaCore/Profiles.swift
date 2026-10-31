import Foundation

public enum ProfileTargetKind: String, Codable, CaseIterable, Sendable { case app, host }
public enum ProfileCleanup: String, Codable, CaseIterable, Sendable { case inherit, off, on }
public enum ProfileStyle: String, Codable, CaseIterable, Sendable {
    case standard, conversational, formal

    var instruction: String? {
        switch self {
        case .standard: return nil
        case .conversational: return "Keep the speaker's conversational tone and natural wording. Do not add greetings, sign-offs, emoji or facts."
        case .formal: return "Use complete sentences and polished grammar while preserving the speaker's meaning, content and language. Do not add facts or invented structure."
        }
    }
}

public struct DictationProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String = ""
    public var enabled = true
    public var targetKind: ProfileTargetKind = .app
    public var target: String = ""
    public var cleanup: ProfileCleanup = .inherit
    public var style: ProfileStyle? = nil
    /// nil inherits; "auto" explicitly follows the speaker; otherwise a whisper code.
    public var recognitionEngine: RecognitionEngine? = nil
    public var appleSpeechLocale: String? = nil
    public var parakeetModelID: String? = nil
    /// nil inherits; "none" explicitly clears the inherited script filter.
    public var parakeetLanguageFilter: String? = nil
    public var language: String? = nil
    public var whisperModelPath: String? = nil
    public var cleanupModel: String? = nil
    public var dictionary: [String] = []
    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        targetKind = try c.decode(ProfileTargetKind.self, forKey: .targetKind)
        target = try c.decode(String.self, forKey: .target)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cleanup = try c.decodeIfPresent(ProfileCleanup.self, forKey: .cleanup) ?? .inherit
        style = try c.decodeIfPresent(ProfileStyle.self, forKey: .style)
        recognitionEngine = try c.decodeIfPresent(RecognitionEngine.self, forKey: .recognitionEngine)
        if c.contains(.appleSpeechLocale), !(try c.decodeNil(forKey: .appleSpeechLocale)) {
            if let value = try? c.decode(String.self, forKey: .appleSpeechLocale), AppleSpeechLocale.isValid(value) { appleSpeechLocale = value }
            else { recognitionEngine = .invalid }
        }
        if c.contains(.parakeetModelID), !(try c.decodeNil(forKey: .parakeetModelID)) {
            if let value = try? c.decode(String.self, forKey: .parakeetModelID), value == ParakeetWire.model { parakeetModelID = value }
            else { recognitionEngine = .invalid }
        }
        if c.contains(.parakeetLanguageFilter), !(try c.decodeNil(forKey: .parakeetLanguageFilter)) {
            if let value = try? c.decode(String.self, forKey: .parakeetLanguageFilter), value == "none" || ParakeetWire.filters.contains(value) { parakeetLanguageFilter = value }
            else { recognitionEngine = .invalid }
        }
        language = try c.decodeIfPresent(String.self, forKey: .language)
        whisperModelPath = try c.decodeIfPresent(String.self, forKey: .whisperModelPath)
        cleanupModel = try c.decodeIfPresent(String.self, forKey: .cleanupModel)
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? []
        if let error = validationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error))
        }
    }

    public var normalizedTarget: String? {
        if targetKind == .host { return ProfileDestination.normalizeHost(target) }
        guard !target.isEmpty, target.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }), target.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return nil }
        return target
    }

    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the profile a name." }
        if normalizedTarget == nil { return "Enter an exact bundle ID or an ASCII host without a scheme, port or path." }
        if let language, language != "auto", !WhisperTranscriber.languages.contains(where: { $0.code == language }) {
            return "Choose a supported spoken language."
        }
        if let whisperModelPath, whisperModelPath.isEmpty { return "Choose a local model or inherit." }
        if let cleanupModel, cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a cleanup model ID or inherit."
        }
        if dictionary.contains(where: { VocabularyHints.normalized($0).utf8.count > VocabularyHints.maxHintBytes }) {
            return "Profile words must be at most 256 UTF-8 bytes each."
        }
        return nil
    }
}

/// Contains only the local host, never a URL path, query or fragment.
public struct ProfileDestination: Equatable, Sendable {
    public let bundleID: String?
    public let host: String?
    public init(bundleID: String? = nil, browserURL: String? = nil) {
        self.bundleID = bundleID
        if TextRules.isBrowser(bundleID: bundleID), let browserURL, let url = URL(string: browserURL),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host {
            self.host = Self.normalizeHost(host)
        } else { host = nil }
    }

    /// ASCII DNS/IPv4 labels only. Case folds; one trailing root dot is ignored.
    /// Unicode hosts must be entered as their exact ASCII (punycode) spelling.
    public static func normalizeHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-"
              }) else { return nil }
        return host
    }
}

public struct ProfileResolution: Equatable, Sendable {
    public let profile: DictationProfile?
    public let settings: Settings
    public var name: String { profile?.name ?? "Global settings" }
}

public enum ProfileResolver {
    public static func resolve(_ globals: Settings, at destination: ProfileDestination) -> ProfileResolution {
        let enabled = globals.profiles.filter { $0.enabled && $0.validationError == nil }
        let winner = destination.host.flatMap { host in
            enabled.first { $0.targetKind == .host && $0.normalizedTarget == host }
        } ?? enabled.first { $0.targetKind == .app && $0.normalizedTarget == destination.bundleID }
        var effective = globals
        if let winner {
            effective.recognitionEngine = winner.recognitionEngine ?? globals.recognitionEngine
            if let locale = winner.appleSpeechLocale { effective.appleSpeechLocale = locale }
            if effective.recognitionEngine == .appleSpeech, winner.appleSpeechLocale == nil, winner.language != nil || winner.whisperModelPath != nil {
                effective.recognitionConfigurationInvalid = true
            }
            if let model = winner.parakeetModelID { effective.parakeetModelID = model }
            if let filter = winner.parakeetLanguageFilter { effective.parakeetLanguageFilter = filter == "none" ? nil : filter }
            if effective.recognitionEngine == .parakeet, winner.recognitionEngine == nil,
               winner.language != nil || winner.whisperModelPath != nil {
                effective.recognitionConfigurationInvalid = true
            }
            switch winner.cleanup {
            case .inherit: break
            case .off: effective.cleanupEnabled = false
            case .on: effective.cleanupEnabled = true
            }
            if let style = winner.style { effective.cleanupStyle = style }
            if let language = winner.language { effective.language = language == "auto" ? nil : language }
            if let model = winner.whisperModelPath { effective.whisperModelPath = model }
            if let model = winner.cleanupModel, !effective.usesAppleIntelligence {
                if effective.cleanup.provider == "openai-compatible" { effective.cleanup.model = model }
                else { effective.cleanupModel = model }
            }
            effective.dictionary = winner.dictionary + globals.dictionary
        }
        return ProfileResolution(profile: winner, settings: effective)
    }

    public static func warnings(_ profiles: [DictationProfile]) -> [String] {
        var targets = Set<String>(), ids = Set<UUID>()
        return profiles.compactMap { profile in
            if let error = profile.validationError { return "\(profile.name): \(error)" }
            guard let target = profile.normalizedTarget else { return nil }
            if !ids.insert(profile.id).inserted { return "Duplicate profile ID: \(profile.name). Fix settings.json before editing profiles." }
            if !targets.insert("\(profile.targetKind.rawValue):\(target)").inserted {
                return "Duplicate target: \(target). First saved enabled profile wins."
            }
            return nil
        }
    }
}
