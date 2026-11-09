import Foundation

public enum DictationOutputMode: String, Codable, CaseIterable, Sendable {
    case cleanup, raw, selectedPreset
}

/// Intent is explicit; dictated/selected source text never supplies instructions.
public struct TransformPreset: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case rewrite, translation }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var instruction: String
    public var localPreserveSourceLanguage: Bool?
    public var targetLanguage: String

    public init(id: UUID = UUID(), name: String = "", kind: Kind = .rewrite,
                instruction: String = "", targetLanguage: String = "", localPreserveSourceLanguage: Bool? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.instruction = instruction; self.targetLanguage = targetLanguage
        self.localPreserveSourceLanguage = localPreserveSourceLanguage
    }

    public var validationError: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.utf8.count > 120 { return "Enter a preset name (up to 120 characters)." }
        let intent = (kind == .rewrite ? instruction : targetLanguage).trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = kind == .rewrite ? 8192 : 120
        if intent.isEmpty || intent.utf8.count > limit {
            return kind == .rewrite ? "Enter an instruction (it can’t be empty or very long)."
                : "Enter a target language."
        }
        return nil
    }

    public var intent: String {
        kind == .translation
            ? "Translate the source text into this explicitly chosen target language: \(targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)). Preserve its meaning."
            : instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Settings {
    public func selectedTransformPreset() throws -> TransformPreset {
        guard let id = selectedPresetID else { throw TransformError(description: "Choose a preset in Output & Presets") }
        let matches = transformPresets.filter { $0.id == id }
        guard matches.count == 1 else { throw TransformError(description: "Selected preset is missing — choose one in Output & Presets") }
        let preset = matches[0]
        if let error = preset.validationError { throw TransformError(description: error) }
        return preset
    }
}

/// Shared production request and result policy for spoken, saved-selection and
/// dictated presets. No ASR, local rewrites, settings reload or raw fallback.
public struct IntentionalTransform {
    public let source: String
    public let instruction: String
    public let settings: Settings
    public let preset: TransformPreset?

    public init(source: String, instruction: String, settings: Settings, preset: TransformPreset? = nil) {
        self.source = source; self.instruction = instruction; self.settings = settings; self.preset = preset
    }

    public func run(makeClient: (Settings) throws -> CleanupProviding) async throws -> String {
        guard settings.cleanupEnabled else { throw TransformError(description: "Turn on cleanup to use presets") }
        guard !source.isEmpty, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TransformError(description: "Nothing to change — select some text")
        }
        if settings.usesAppleIntelligence, preset?.kind != .rewrite || preset?.localPreserveSourceLanguage != true {
            throw LocalCleanupReason.unsupportedAction.error
        }
        var context = CleanupContext(dictionary: settings.dictionary, snippets: [:], appName: nil, selection: source)
        context.localIntent = preset?.kind == .rewrite && preset?.localPreserveSourceLanguage == true ? .savedSameLanguageRewrite : .unsupported
        return try Self.result(try await makeClient(settings).clean(transcript: instruction, context: context), source: source)
    }

    public static func result(_ text: String, source: String) throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= max(2000, 6 * source.count) else {
            throw TransformError(description: "The preset returned no usable text")
        }
        return result
    }
}

/// Provider usage defaults to the existing dictation sink. Intentional callers
/// inject an operation-owned collector so late requests cannot bill a new capture.
public typealias CleanupUsageSink = (String, Int?, Int?) -> Void

public func recordCleanupUsage(model: String, input: Int?, output: Int?) {
    Metrics.shared.update {
        $0.cleanupModel = model; $0.promptTokens = input; $0.completionTokens = output
    }
}

public final class TransformUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics = PipelineMetrics()
    public init() {}
    public func record(model: String, input: Int?, output: Int?) {
        lock.withLock {
            metrics.cleanupModel = model; metrics.promptTokens = input; metrics.completionTokens = output
        }
    }
    public func recordRecognition(model: String) { lock.withLock { metrics.model = model } }
    public func snapshot() -> PipelineMetrics? { lock.withLock { metrics.isEmpty ? nil : metrics } }
}

/// Minimal provenance; legacy history rows have no operation. No migration.
public struct TransformProvenance: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case selection, dictation, spoken }
    public enum Outcome: String, Codable, Sendable { case completed, parked, failed }
    public var origin: Origin
    public var presetID: UUID?
    public var name: String
    public var outcome: Outcome
    public init(origin: Origin, preset: TransformPreset? = nil, outcome: Outcome) {
        self.origin = origin; presetID = preset?.id; name = preset?.name ?? (origin == .spoken ? "Spoken transform" : "Selected preset unavailable"); self.outcome = outcome
    }
    public var label: String { "\(name) · \(origin.rawValue) · \(outcome.rawValue)" }
}

public struct TransformError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

extension IntentionalTransform {
    /// Provider descriptions may contain response bodies. Keep source text out
    /// of status messages, especially when history is disabled.
    public static func failureMessage(_ error: Error) -> String {
        if let error = error as? TransformError { return error.description }
        if let error = error as? CleanupError { return "Transform failed: " + error.userMessage }
        return "Transform failed"
    }
}
