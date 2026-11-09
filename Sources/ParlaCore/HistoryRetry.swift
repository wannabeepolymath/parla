import Foundation
import CryptoKit

/// Only this whitelist is persisted. Credentials, endpoint paths, headers and
/// environment names/values never enter retry provenance.
public struct HistoryRetryConfiguration: Codable, Equatable, Sendable {
    public let provider: String
    public let endpointOrigin: String
    public let model: String
    public let style: String
    public let language: String
    public let kind: Kind
    public let presetName: String?
    public let vocabularySummary: String
    public let rulesDigest: String
    public enum Execution: String, Codable, Sendable { case deterministic, network, onDevice }
    public var execution: Execution? = nil
    public var executionKind: Execution { execution ?? (localOnly ? .deterministic : .network) }
    public var localOnly: Bool
    public var mode: HistoryRetryMode? = nil
    public var planVersion: Int? = nil
    public var retryMode: HistoryRetryMode { mode ?? .whole }
    public enum Kind: String, Codable, Sendable { case cleanup, preset }

    /// Display only. The stored fields keep their original wording.
    public var summary: String {
        let destination = executionKind == .onDevice ? "Apple Intelligence on this Mac"
            : localOnly ? "Local rules only, nothing sent online" : "\(provider) · \(endpointOrigin) · \(model)"
        let action = kind == .cleanup ? "Cleanup" : "Preset: " + (presetName ?? "Unknown")
        let vocabulary = vocabularySummary
            .replacingOccurrences(of: " (8,192-byte budget)", with: "").replacingOccurrences(of: " (8192-byte budget)", with: "")
            .replacingOccurrences(of: "cleanup hints", with: "dictionary words").replacingOccurrences(of: "literal rules", with: "replacements")
        return action + " · " + destination + "\nStyle: \(style) · " + vocabulary
    }
}

public struct HistoryRetryProvenance: Codable, Equatable, Sendable {
    public let date: Date
    public let configuration: HistoryRetryConfiguration
    public let usage: PipelineMetrics?
    public var segmented: SegmentedRetrySummary? = nil
    public init(date: Date, configuration: HistoryRetryConfiguration, usage: PipelineMetrics?, segmented: SegmentedRetrySummary? = nil) {
        self.date = date; self.configuration = configuration; self.usage = usage; self.segmented = segmented
    }
}

/// A frozen, text-only operation. Its dependencies cannot capture audio, load
/// models, inspect the frontmost app, or insert text. Storage is a separate step.
public struct HistoryRetryRequest {
    public typealias Factory = (Settings, [String: String], CleanupAccess, @escaping CleanupUsageSink) throws -> CleanupProviding
    public let configuration: HistoryRetryConfiguration
    public let presetReview: String?
    private let settings: Settings
    private let environment: [String: String]
    private let preset: TransformPreset?
    private let secrets: [String]
    private let access: CleanupAccess?
    private var segmentedReview: SegmentedOriginalReview? = nil
    public var isSegmented: Bool { segmentedReview != nil }
    public func sameExperimentalRequest(as other: Self) -> Bool {
        guard let a = segmentedReview, let b = other.segmentedReview else { return !isSegmented && !other.isSegmented }
        return a.identity == b.identity && a.consent == b.consent && a.version == b.version
            && a.source.id == b.source.id && a.source.raw == b.source.raw
    }
    public var plannedSegments: Int { segmentedReview?.planned ?? 0 }
    public var disclosure: String? { segmentedReview?.disclosure }
    public typealias SegmentedFactory = (Settings, [String: String], CleanupAccess, HistoryRetryExecutionPolicy, @escaping CleanupUsageSink) throws -> CleanupProviding

    public init(segmentedSettings settings: Settings, source: HistoryEntry, version: UUID) throws {
        let review = try SegmentedOriginalReview(settings: settings, source: source, version: version)
        segmentedReview = review; configuration = review.configuration; presetReview = nil
        self.settings = review.settings; environment = [:]; preset = nil; secrets = []; access = nil
    }
    public func runSegmented(policy: HistoryRetryExecutionPolicy, environment: () -> [String: String], credentials: () -> CredentialStore,
                             factory: SegmentedFactory, now: () -> Date = Date.init, diagnostics: DiagnosticOperation? = nil,
                             progress: (Int, Int) async -> Void = { _, _ in }) async throws -> (String, HistoryRetryProvenance) {
        guard let review = segmentedReview else { throw SegmentedRetryFailure.configuration }
        return try await review.run(policy: policy, environment: environment, credentials: credentials, factory: factory, now: now, diagnostics: diagnostics, progress: progress)
    }
    static func segmentedRulesDigest(_ settings: Settings) throws -> String {
        struct Rules: Encodable { let words: [String]; let snippets: [String: String]; let replacements: [LiteralReplacement] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(Rules(words: settings.dictionary, snippets: settings.snippets, replacements: settings.replacements)))
            .map { String(format: "%02x", $0) }.joined()
    }


    public init(settings: Settings, environment: @autoclosure () -> [String: String], source: HistoryEntry, applyPreset: Bool, credentials: @autoclosure () -> CredentialStore, diagnostics: DiagnosticOperation? = nil) throws {
        let environment = settings.usesAppleIntelligence ? [:] : environment()
        var frozen = settings
        frozen.outputMode = .cleanup // never inherit raw/preset dictation mode
        let preset = applyPreset ? try settings.selectedTransformPreset() : nil
        guard applyPreset || source.operation == nil else {
            throw TransformError(description: "The original instruction wasn’t saved. Apply your selected preset to the original instead.")
        }
        if applyPreset, !cleanupIsConfigured(settings: frozen, env: environment, credentials: credentials()) {
            throw TransformError(description: "Presets need cleanup turned on and set up.")
        }
        if settings.usesAppleIntelligence { frozen.anthropicApiKey = nil; frozen.cleanup.apiKey = nil }
        self.settings = frozen; self.environment = environment; self.preset = preset
        let locked = !applyPreset && Pipeline.snippetExpansion(transcript: source.raw, snippets: settings.snippets) != nil
        let local = !applyPreset && (locked || !cleanupIsConfigured(settings: frozen, env: environment, credentials: credentials()))
        diagnostics?.providerSettings(frozen)
        let access: CleanupAccess?
        do {
            if local || source.raw.isEmpty { access = nil }
            else {
                let setup = diagnostics?.begin(.providerSetup); defer { setup?.end() }
                access = try prepareCleanupAccess(settings: frozen, env: environment, credentials: credentials())
            }
        }
        catch { diagnostics?.providerRefusal(error); throw error }
        self.access = access
        let secrets = settings.usesAppleIntelligence ? [] : [settings.anthropicApiKey, settings.cleanup.apiKey,
                       environment["ANTHROPIC_API_KEY"], settings.cleanup.apiKeyEnvVar.flatMap { environment[$0] }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        self.secrets = secrets
        func safe(_ value: String) -> String { access?.redacting(Self.redact(value, secrets: secrets)) ?? Self.redact(value, secrets: secrets) }
        let provider: String
        let origin: String
        let model: String
        switch settings.cleanup.provider {
        case "", "anthropic":
            provider = "anthropic"; origin = "https://api.anthropic.com"
            model = safe(Self.modelLabel(settings.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Settings().cleanupModel : settings.cleanupModel))
        case "apple-intelligence":
            provider = "apple-intelligence"; origin = "on-device; no endpoint"; model = "Apple Intelligence · on-device"
        case "openai-compatible":
            provider = "openai-compatible"
            var components = settings.cleanup.baseURL.flatMap { URLComponents(string: $0) }
            if let scheme = components?.scheme?.lowercased(), ["http", "https"].contains(scheme), components?.host != nil {
                components?.user = nil; components?.password = nil; components?.path = ""
                components?.query = nil; components?.fragment = nil
                origin = safe(components?.string ?? "Invalid endpoint")
            } else { origin = "Invalid or missing endpoint" }
            let chosen = settings.cleanup.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            model = chosen.isEmpty ? "server chooses" : safe(Self.modelLabel(chosen))
        default: provider = "Unsupported provider"; origin = "Unavailable"; model = "Unknown"
        }
        // Digest only the rules/intent, with deterministic encoding; no provider
        // credentials or omitted endpoint portions participate in equivalence.
        struct Rules: Encodable {
            let words: [String]; let snippets: [String: String]; let replacements: [LiteralReplacement]
            let intent: String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Rules(words: settings.dictionary, snippets: settings.snippets,
                                            replacements: settings.replacements, intent: preset?.intent))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let language = settings.language.flatMap { code in WhisperTranscriber.languages.first { $0.code == code }?.code } ?? "auto / preserve source"
        configuration = .init(provider: provider, endpointOrigin: origin, model: model,
                              style: settings.cleanupStyle.rawValue, language: language,
                              kind: applyPreset ? .preset : .cleanup, presetName: preset.map { safe($0.name) },
                              vocabularySummary: "\(VocabularyHints.select(settings.dictionary, byteLimit: VocabularyHints.cleanupBytes).count) cleanup hints (8,192-byte budget), \(settings.snippets.count) snippets, \(settings.replacements.count) literal rules" + (locked ? "; exact snippet locked" : ""),
                              rulesDigest: digest, execution: local ? .deterministic : settings.usesAppleIntelligence ? .onDevice : .network, localOnly: local)
        presetReview = preset.map { safe("\($0.name) · \($0.kind.rawValue)\nInstruction: \($0.intent)\nTarget: \($0.kind == .translation ? $0.targetLanguage : "preserve source language")") }
    }

    public func run(source: String, factory: @escaping Factory,
                    now: () -> Date = Date.init, diagnostics: DiagnosticOperation? = nil) async throws -> (String, HistoryRetryProvenance) {
        guard !isSegmented else { throw SegmentedRetryFailure.configuration }
        guard !source.isEmpty else { throw TransformError(description: "The original text is empty.") }
        let cleanup = diagnostics?.begin(.cleanup); defer { cleanup?.end() }
        let usage = TransformUsage()
        let make: (Settings) throws -> CleanupProviding = { settings in
            // Avoid leaking raw server/factory descriptions through Pipeline logs.
            do {
                guard let access else { throw CredentialFailure("Nothing to send. Try again.") }
                let create = { try factory(settings, environment, access, { model, input, output in
                    usage.record(model: settings.usesAppleIntelligence ? "Apple Intelligence · on-device" : access.redacting(Self.redact(Self.modelLabel(model), secrets: secrets)), input: input, output: output)
                }) }
                let provider = try diagnostics.map { diagnostic in try diagnostic.makeProvider(settings: settings, factory: create) } ?? create()
                return RetryProvider(base: provider, local: settings.usesAppleIntelligence)
            } catch { throw TransformError(description: "Provider configuration unavailable") }
        }
        let text: String
        if let preset {
            // Check before invoking even an injected factory.
            guard access != nil else {
                throw TransformError(description: "Presets need cleanup turned on and set up.")
            }
            do { text = try await IntentionalTransform(source: source, instruction: preset.intent, settings: settings, preset: preset).run(makeClient: make) }
            catch {
                diagnostics?.update { if $0.providerOutcome == .returned { $0.providerOutcome = .invalidResult } }
                if let reason = LocalCleanupReason.from(error), settings.usesAppleIntelligence { throw reason.error }
                throw TransformError(description: "The preset didn’t work. Try again.") }
        } else {
            var effective = settings
            if configuration.localOnly { effective.cleanupEnabled = false }
            // The frozen factory observes actual setup/request boundaries; only
            // local policy is observed here to avoid wrapping it twice.
            var pipeline = Pipeline(outputSettings: effective, bundleID: nil, makeClient: make)
            pipeline.diagnostics = diagnostics
            let result = await pipeline.clean(transcript: source)
            guard result.failure == nil else {
                if settings.usesAppleIntelligence, let reason = LocalCleanupReason.allCases.first(where: { $0.message == result.failure }) { throw reason.error }
                throw TransformError(description: "Cleanup didn’t work. Try again.")
            }
            text = result.text
        }
        return (text, HistoryRetryProvenance(date: now(), configuration: configuration, usage: usage.snapshot()))
    }

    static func modelLabel(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
        // A model identifier is not a URL or an arbitrary provider response.
        guard !text.contains("://"), text.utf8.count <= 160, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "Unavailable model label" }
        return text
    }
    private static func redact(_ text: String, secrets: [String]) -> String {
        secrets.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
}

private struct RetryProvider: CleanupProviding {
    let base: CleanupProviding
    let local: Bool
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        do { return try await base.clean(transcript: transcript, context: context) }
        catch {
            if local, let reason = LocalCleanupReason.from(error) { throw reason.error }
            throw TransformError(description: "Provider request failed")
        }
    }
}
