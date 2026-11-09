import Foundation

public enum HistoryRetryMode: String, Codable, Sendable { case whole, segmentedV1 }
public enum SegmentedRetryFailure: String, Error, Codable, Sendable {
    case source, previous, rules, plan, singleSegment, snippets, configuration
    case request, headers, response, output, provider, canceled, deadline, payload
    public var message: String {
        switch self {
        case .singleSegment: return "This text is short enough. Use Clean up again instead."
        case .snippets: return "Text with snippets can’t be cleaned up in sections. Use Clean up again instead."
        case .deadline: return "Cleanup took too long. Try again."
        case .canceled: return "Cleanup was canceled."
        default: return "Cleanup didn’t finish. Try again."
        }
    }
}

public struct SegmentedRetrySummary: Codable, Equatable, Sendable {
    public enum Terminal: String, Codable, Sendable { case complete, refused, failed, canceled, deadline }
    public var planned: Int
    public var attempted = 0
    public var completed = 0
    public var terminal: Terminal = .refused
    public var failure: SegmentedRetryFailure?
    public var failureIndex: Int?
    public enum Usage: String, Codable, Sendable { case unknown, partial, reported, mixed }
    public struct Attempt: Codable, Equatable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?
    }
    public var attempts: [Attempt]? = nil
    public var usage: Usage? = nil
    public var inputTokens: Int? = nil
    public var outputTokens: Int? = nil
    public init(planned: Int) { self.planned = min(16, max(0, planned)) }
}

/// Ranges belong to this exact immutable String. Whitespace separators are never
/// sent independently or normalized. Scanning advances through at most 4096
/// content bytes plus one whitespace run; it does not rescan source prefixes.
public struct HistoryRetrySegmentPlan {
    public static let version = 1
    public struct Segment {
        public let content: Range<String.Index>
        public let separator: Range<String.Index>
    }
    public let original: String
    public let leading: Range<String.Index>
    public let segments: [Segment]
    public init(original: String) throws {
        guard !original.isEmpty, original.utf8.count <= 64 * 1024 else { throw SegmentedRetryFailure.source }
        var cursor = original.startIndex
        while cursor < original.endIndex, original[cursor].isWhitespace { cursor = original.index(after: cursor) }
        leading = original.startIndex..<cursor
        var planned: [Segment] = []
        while cursor < original.endIndex {
            guard planned.count < 16 else { throw SegmentedRetryFailure.plan }
            let start = cursor
            var bytes = 0, scan = start
            var paragraph: Range<String.Index>?, punctuation: Range<String.Index>?, whitespace: Range<String.Index>?
            var finalContent = start
            while scan < original.endIndex {
                let c = original[scan], size = c.utf8.count
                if c.isWhitespace {
                    let begin = scan
                    var end = scan, runBytes = 0, newlines = 0
                    while end < original.endIndex, original[end].isWhitespace {
                        let w = original[end]
                        runBytes += w.utf8.count
                        if w.isNewline { newlines += 1 }
                        end = original.index(after: end)
                    }
                    // A complete run can be an exact separator even if large.
                    if bytes <= 4096 {
                        let range = begin..<end
                        whitespace = range
                        if bytes >= 2048 {
                            if newlines >= 2 { paragraph = range }
                            if begin > start, ".!?".contains(original[original.index(before: begin)]) { punctuation = range }
                        }
                    }
                    if end == original.endIndex { finalContent = begin; scan = end; break }
                    if runBytes > 4096 - bytes { break }
                    bytes += runBytes; scan = end
                } else {
                    guard size <= 4096 - bytes else { break }
                    bytes += size; scan = original.index(after: scan); finalContent = scan
                }
            }
            let content: Range<String.Index>, separator: Range<String.Index>
            if scan == original.endIndex {
                content = start..<finalContent; separator = finalContent..<original.endIndex
            } else {
                guard let split = paragraph ?? punctuation ?? whitespace, split.lowerBound > start else { throw SegmentedRetryFailure.plan }
                content = start..<split.lowerBound; separator = split
            }
            guard !content.isEmpty, original[content].utf8.count <= 4096 else { throw SegmentedRetryFailure.plan }
            planned.append(Segment(content: content, separator: separator)); cursor = separator.upperBound
        }
        guard !planned.isEmpty else { throw SegmentedRetryFailure.source }
        guard planned.count >= 2 else { throw SegmentedRetryFailure.singleSegment }
        self.original = original; segments = planned
    }
    public func reconstructed() -> String {
        var text = String(original[leading])
        for segment in segments { text += original[segment.content]; text += original[segment.separator] }
        return text
    }
}

/// One monotonic acceptance budget, created at explicit Start, shared by the
/// real adapters. Cancellation revokes acceptance, never represents actual exit.
public final class HistoryRetryExecutionPolicy: @unchecked Sendable {
    public let deadline: TimeInterval
    public let now: () -> TimeInterval
    public let sleep: (TimeInterval) async throws -> Void
    private let lock = NSLock()
    private var stopped: SegmentedRetryFailure?
    private var cancelOwned: (() -> Void)?
    private var summary: SegmentedRetrySummary
    private var payload = 0
    private var usageCount = 0, input = 0, output = 0
    private var knownInput = true, knownOutput = true
    private var responseModel: String?, mixedModels = false
    // Keep the async default implementation in this module for cross-module callers.
    @usableFromInline
    internal static func defaultSleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    public init(planned: Int, budget: TimeInterval = 60, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) async throws -> Void = HistoryRetryExecutionPolicy.defaultSleep) {
        precondition(budget.isFinite && budget > 0)
        self.now = now; self.sleep = sleep; deadline = now() + budget
        summary = SegmentedRetrySummary(planned: planned)
    }
    public func installCancellation(_ action: @escaping () -> Void) {
        let stop = lock.withLock { cancelOwned = action; return stopped != nil }
        if stop { action() }
    }
    public func stop(_ failure: SegmentedRetryFailure) {
        let action: (() -> Void)? = lock.withLock {
            guard stopped == nil else { return nil }
            stopped = failure; return cancelOwned
        }
        action?()
    }
    public func check() throws {
        if now() >= deadline { stop(.deadline) }
        if Task.isCancelled { stop(.canceled) }
        if let failure = lock.withLock({ stopped }) { throw failure }
    }
    public func remaining() throws -> TimeInterval { try check(); return min(15, max(0, deadline - now())) }
    public func attempt() throws {
        try check()
        try lock.withLock {
            guard summary.attempted < summary.planned, summary.attempted < 16 else { throw SegmentedRetryFailure.request }
            summary.attempted += 1
            if summary.attempts == nil { summary.attempts = [] }
            summary.attempts?.append(.init(inputTokens: nil, outputTokens: nil))
        }
    }
    public func reserve(_ count: Int) throws {
        try lock.withLock {
            guard count >= 0, count <= 1024 * 1024 - payload else { throw SegmentedRetryFailure.payload }
            payload += count
        }
    }
    public func release(_ count: Int) { lock.withLock { payload -= count; precondition(payload >= 0) } }
    func completed() { lock.withLock { summary.completed += 1 } }
    public func recordUsage(model: String, input: Int?, output: Int?) {
        lock.withLock {
            guard usageCount < summary.attempted, usageCount < 16 else { knownInput = false; knownOutput = false; return }
            usageCount += 1
            summary.attempts?[usageCount - 1] = .init(inputTokens: input.flatMap { $0 >= 0 ? $0 : nil },
                                                     outputTokens: output.flatMap { $0 >= 0 ? $0 : nil })
            if model.utf8.count > 160 { mixedModels = true }
            else if let responseModel, responseModel != model { mixedModels = true }
            else if responseModel == nil { responseModel = model }
            func add(_ value: Int?, to total: inout Int, known: inout Bool) {
                guard let value, value >= 0 else { known = false; return }
                let sum = total.addingReportingOverflow(value)
                if sum.overflow { known = false } else { total = sum.partialValue }
            }
            add(input, to: &self.input, known: &knownInput); add(output, to: &self.output, known: &knownOutput)
        }
    }
    public func finish(_ failure: SegmentedRetryFailure? = nil) -> SegmentedRetrySummary {
        lock.withLock {
            let failure = stopped ?? failure
            summary.inputTokens = knownInput && usageCount == summary.attempted && summary.attempted > 0 ? input : nil
            summary.outputTokens = knownOutput && usageCount == summary.attempted && summary.attempted > 0 ? output : nil
            summary.usage = mixedModels ? .mixed : !(summary.attempts ?? []).contains(where: { $0.inputTokens != nil || $0.outputTokens != nil }) ? .unknown
                : summary.inputTokens != nil && summary.outputTokens != nil ? .reported : .partial
            summary.failure = failure
            summary.failureIndex = failure == nil ? nil : min(16, summary.completed + 1)
            summary.terminal = failure == .deadline ? .deadline : failure == .canceled ? .canceled : failure == nil ? .complete : .failed
            return summary
        }
    }
    func metrics() -> PipelineMetrics {
        lock.withLock {
            var metrics = PipelineMetrics()
            metrics.cleanupModel = mixedModels ? "Mixed response models; usage not priced" : "Experimental response usage; model identity unverified"
            metrics.promptTokens = knownInput && usageCount == summary.attempted && summary.attempted > 0 ? input : nil
            metrics.completionTokens = knownOutput && usageCount == summary.attempted && summary.attempted > 0 ? output : nil
            return metrics
        }
    }
    /// The retained child and watchdog are both joined, including ignored cancel.
    public func joined<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let child = Task { try check(); return try await work() }
        let watchdog = Task {
            do { try await sleep(max(0, deadline - now())); if !Task.isCancelled, now() >= deadline { stop(.deadline); child.cancel() } }
            catch { /* joined below */ }
        }
        let result = await withTaskCancellationHandler(operation: { await child.result }, onCancel: { self.stop(.canceled); child.cancel() })
        watchdog.cancel(); await watchdog.value
        try check(); return try result.get()
    }
}

/// Private full configuration/source binding. Only configuration's safe whitelist
/// leaves this value; exact raw/version/config/consent identities stay in memory.
struct SegmentedOriginalReview {
    let source: HistoryEntry
    let version: UUID
    let identity = UUID()
    let consent = UUID()
    let settings: Settings
    let plan: HistoryRetrySegmentPlan?
    let locked: String?
    let ruleBytes: Int
    let configuration: HistoryRetryConfiguration
    var planned: Int { plan?.segments.count ?? 0 }
    init(settings: Settings, source: HistoryEntry, version: UUID) throws {
        guard source.operation == nil, !source.raw.isEmpty, source.raw.utf8.count <= 64 * 1024, source.raw.contains(where: { !$0.isWhitespace }) else { throw SegmentedRetryFailure.source }
        guard source.best.utf8.count <= 128 * 1024 else { throw SegmentedRetryFailure.previous }
        guard settings.dictionary.count <= 256, settings.snippets.count <= 256, settings.replacements.count <= 256 else { throw SegmentedRetryFailure.rules }
        var bytes = 0
        func add(_ text: String) throws {
            guard text.utf8.count <= 64 * 1024 - bytes else { throw SegmentedRetryFailure.rules }; bytes += text.utf8.count
        }
        for word in settings.dictionary { try add(word) }
        for (key, value) in settings.snippets { try add(key); try add(value) }
        for rule in settings.replacements { try add(rule.source); try add(rule.replacement) }
        let locked = Pipeline.snippetExpansion(transcript: source.raw, snippets: settings.snippets)
        if let locked, locked.utf8.count > 128 * 1024 { throw SegmentedRetryFailure.output }
        var frozen = settings; frozen.outputMode = .cleanup
        let deterministic = locked != nil || !settings.cleanupEnabled
            || (settings.cleanup.provider == "openai-compatible" && (settings.cleanup.baseURL ?? "").isEmpty)
        if !deterministic {
            guard settings.snippets.isEmpty else { throw SegmentedRetryFailure.snippets }
            if !settings.usesAppleIntelligence {
                let scope = try CredentialScope.selected(settings)
                guard scope.baseURL.utf8.count <= 4096 else { throw SegmentedRetryFailure.configuration }
                let model = settings.cleanup.provider == "openai-compatible" ? settings.cleanup.model ?? "" : settings.cleanupModel
                guard model.utf8.count <= 160 else { throw SegmentedRetryFailure.configuration }
                if settings.cleanup.provider == "openai-compatible" {
                    guard !(settings.cleanup.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else { throw SegmentedRetryFailure.configuration }
                }
            }
        }
        if settings.usesAppleIntelligence { frozen.anthropicApiKey = nil; frozen.cleanup.apiKey = nil }
        self.settings = frozen; self.source = source; self.version = version; self.locked = locked; ruleBytes = bytes
        plan = deterministic ? nil : try HistoryRetrySegmentPlan(original: source.raw)
        func safe(_ text: String) -> String {
            [settings.anthropicApiKey, settings.cleanup.apiKey].compactMap { $0 }.filter { !$0.isEmpty }
                .reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
        }
        let provider: String, origin: String, model: String
        switch settings.cleanup.provider {
        case "apple-intelligence": provider = "apple-intelligence"; origin = "on-device; no endpoint"; model = "Apple Intelligence · on-device"
        case "openai-compatible":
            provider = "openai-compatible"
            var url = settings.cleanup.baseURL.flatMap { URLComponents(string: $0) }
            url?.path = ""; url?.query = nil; url?.fragment = nil; url?.user = nil; url?.password = nil
            origin = safe(url?.string ?? "Unconfigured endpoint")
            model = safe(HistoryRetryRequest.modelLabel(settings.cleanup.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        case "", "anthropic":
            provider = "anthropic"; origin = "https://api.anthropic.com"
            model = safe(HistoryRetryRequest.modelLabel(settings.cleanupModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Settings().cleanupModel : settings.cleanupModel))
        default: provider = "Unsupported provider"; origin = "Unavailable"; model = "Unknown"
        }
        configuration = HistoryRetryConfiguration(provider: provider, endpointOrigin: origin, model: model,
            style: settings.cleanupStyle.rawValue, language: settings.usesAppleIntelligence ? (LocalCleanupConfiguration(settings: settings).validatedLocale ?? "Unknown declared local locale") : "Preserve source; no ASR",
            kind: .cleanup, presetName: nil, vocabularySummary: "\(VocabularyHints.select(settings.dictionary, byteLimit: VocabularyHints.cleanupBytes).count) cleanup hints (8192-byte budget), \(settings.snippets.count) snippets, \(settings.replacements.count) literal rules" + (locked != nil ? "; exact snippet locked" : ""),
            rulesDigest: try HistoryRetryRequest.segmentedRulesDigest(settings),
            execution: deterministic ? .deterministic : settings.usesAppleIntelligence ? .onDevice : .network,
            localOnly: deterministic, mode: .segmentedV1, planVersion: HistoryRetrySegmentPlan.version)
    }
    var disclosure: String {
        let scope: String
        switch configuration.executionKind {
        case .deterministic: scope = "Uses local rules only; nothing is sent online."
        case .onDevice: scope = "At most \(planned) requests to Apple Intelligence on this Mac."
        case .network: scope = "At most \(planned) requests to \(configuration.provider) (\(configuration.endpointOrigin), model \(configuration.model))."
        }
        return "Long text is cleaned up one section at a time. " + scope + " Check the result before saving."
    }
    typealias Factory = (Settings, [String: String], CleanupAccess, HistoryRetryExecutionPolicy, @escaping CleanupUsageSink) throws -> CleanupProviding
    func run(policy: HistoryRetryExecutionPolicy, environment: () -> [String: String], credentials: () -> CredentialStore,
             factory: Factory, now: () -> Date, diagnostics: DiagnosticOperation?, progress: (Int, Int) async -> Void) async throws -> (String, HistoryRetryProvenance) {
        let cleanup = diagnostics?.begin(.cleanup); defer { cleanup?.end() }
        diagnostics?.providerSettings(settings)
        let retained = source.raw.utf8.count + source.best.utf8.count + ruleBytes
        try policy.reserve(retained); defer { policy.release(retained) }
        var assembledBytes = 0
        defer { policy.release(assembledBytes) }
        do {
            try policy.check()
            func result(_ text: String, configuration: HistoryRetryConfiguration) throws -> (String, HistoryRetryProvenance) {
                try policy.check()
                guard text.utf8.count <= 128 * 1024 else { throw SegmentedRetryFailure.output }
                let summary = policy.finish(); diagnostics?.update { $0.segmentedRetry = summary }
                return (text, HistoryRetryProvenance(date: now(), configuration: configuration, usage: policy.metrics(), segmented: summary))
            }
            if let locked {
                diagnostics?.update { $0.providerOutcome = .localSnippet }
                return try result(locked, configuration: configuration)
            }
            let environment = configuration.executionKind == .network ? environment() : [:]
            let configured = configuration.executionKind == .deterministic ? false
                : cleanupIsConfigured(settings: settings, env: environment, credentials: credentials())
            if !configured {
                diagnostics?.update { $0.providerOutcome = .off }
                var deterministic = configuration; deterministic.execution = .deterministic; deterministic.localOnly = true
                try policy.reserve(128 * 1024); defer { policy.release(128 * 1024) }
                let text = try LiteralReplacement.boundedApply(settings.replacements, to: source.raw, maximumBytes: 128 * 1024)
                return try result(text, configuration: deterministic)
            }
            guard let plan else { throw SegmentedRetryFailure.plan }
            try policy.check()
            let access = try prepareCleanupAccess(settings: settings, env: environment, credentials: credentials())
            try policy.check()
            let context = CleanupContext(dictionary: settings.dictionary, snippets: [:], appName: nil, style: settings.cleanupStyle)
            // Complete-source and every segment local preflight precede generation.
            var localPreflight: LocalSegmentPreflighting?
            func create() throws -> CleanupProviding {
                let provider = try factory(settings, environment, access, policy, { model, input, output in policy.recordUsage(model: model, input: input, output: output) })
                localPreflight = provider as? LocalSegmentPreflighting
                return provider
            }
            let provider = try diagnostics.map { try $0.makeProvider(settings: settings, factory: create) } ?? create()
            if settings.usesAppleIntelligence {
                guard let local = localPreflight else { throw SegmentedRetryFailure.configuration }
                try local.preflight(transcript: source.raw, context: context)
                for segment in plan.segments { try policy.check(); try local.preflight(transcript: String(source.raw[segment.content]), context: context) }
            }
            // Preflight framing for every request before the first POST, with no
            // private app/site context and no segment-level snippet rematching.
            for segment in plan.segments {
                let userBytes = 13 + source.raw[segment.content].utf8.count
                guard PromptBuilder.system(context: context).utf8.count + userBytes <= 16 * 1024 else { throw SegmentedRetryFailure.request }
            }
            var assembled = String(source.raw[plan.leading])
            assembledBytes = assembled.utf8.count; try policy.reserve(assembledBytes)
            for (index, segment) in plan.segments.enumerated() {
                try policy.check()
                // Reserve content, returned native acceptance and sanitized output
                // before materializing them. Native allocator memory is not covered.
                try policy.reserve(52 * 1024)
                defer { policy.release(52 * 1024) }
                let content = String(source.raw[segment.content])
                let returned = try await provider.clean(transcript: content, context: context)
                try policy.check()
                guard returned.utf8.count <= 16 * 1024 else { throw SegmentedRetryFailure.output }
                let cleaned = CleanupSanitizer.sanitize(returned)
                guard cleaned.utf8.count <= 16 * 1024, CleanupOutput.validationFailure(cleaned, source: content) == nil else { throw SegmentedRetryFailure.output }
                let addition = cleaned.utf8.count + source.raw[segment.separator].utf8.count
                guard addition <= 128 * 1024 - assembledBytes else { throw SegmentedRetryFailure.output }
                try policy.reserve(addition); assembledBytes += addition
                assembled += cleaned; assembled += source.raw[segment.separator]
                policy.completed(); try policy.check(); await progress(index + 1, planned)
            }
            guard CleanupOutput.validationFailure(assembled, source: source.raw) == nil else { throw SegmentedRetryFailure.output }
            // Reserve the bounded writer's possible result before materialization.
            try policy.reserve(128 * 1024); defer { policy.release(128 * 1024) }
            let text = try LiteralReplacement.boundedApply(settings.replacements, to: assembled, maximumBytes: 128 * 1024)
            return try result(text, configuration: configuration)
        } catch {
            diagnostics?.update { if $0.providerOutcome == .returned { $0.providerOutcome = .invalidResult } }
            let failure = (error as? SegmentedRetryFailure) ?? (LocalCleanupReason.from(error) == .deadline ? .deadline : LocalCleanupReason.from(error) == .canceled ? .canceled : .provider)
            let summary = policy.finish(failure); diagnostics?.update { $0.segmentedRetry = summary }
            throw failure
        }
    }
}

public protocol LocalSegmentPreflighting {
    func preflight(transcript: String, context: CleanupContext) throws
}
