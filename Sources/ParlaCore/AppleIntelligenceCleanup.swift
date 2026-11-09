import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Finite public vocabulary. Native errors, contexts and refusal explanations
/// never cross this boundary, including Pipeline's detailed logging branch.
public enum LocalCleanupReason: String, Codable, Error, Sendable, CaseIterable {
    case oldOS, missingFramework, ineligible, disabled, notReady, unknown
    case unsupportedLanguage, unknownLanguage, mixedLanguage, unsupportedAction
    case inputTooLarge, contextLimit, refusedOrSafety, empty, oversized
    case canceled, deadline, unavailable, rateLimited, schedulerUnavailable
    public var message: String {
        switch self {
        case .oldOS: return "Apple Intelligence needs macOS 26 or later."
        case .missingFramework: return "Apple Intelligence isn’t available in this version of Parla."
        case .ineligible: return "Apple Intelligence isn’t available on this Mac."
        case .disabled: return "Apple Intelligence is off in System Settings."
        case .notReady: return "Apple Intelligence is still getting ready."
        case .unknown: return "Apple Intelligence hasn’t been checked yet."
        case .unsupportedLanguage: return "Apple Intelligence doesn’t support this language."
        case .unknownLanguage: return "Couldn’t confirm the language. Check the language in AI Cleanup."
        case .mixedLanguage: return "The text mixes languages, so it wasn’t cleaned up."
        case .unsupportedAction: return "Apple Intelligence can only clean up text or run same-language presets."
        case .inputTooLarge: return "Too much text for Apple Intelligence."
        case .contextLimit: return "Too much text for Apple Intelligence."
        case .refusedOrSafety: return "Apple Intelligence declined this request."
        case .empty: return "Apple Intelligence returned no text."
        case .oversized: return "Apple Intelligence returned too much text."
        case .canceled: return "Cleanup was canceled."
        case .deadline: return "Apple Intelligence took too long."
        case .unavailable: return "Apple Intelligence isn’t available right now."
        case .rateLimited: return "Apple Intelligence is busy. Try again soon."
        case .schedulerUnavailable: return "Apple Intelligence isn’t available right now."
        }
    }
    public static func from(_ error: Error) -> LocalCleanupReason? {
        if let reason = error as? LocalCleanupReason { return reason }
        guard let error = error as? CleanupError else { return nil }
        return allCases.first { $0.error.description == error.description }
    }
    public var error: CleanupError { CleanupError(description: "Apple Intelligence: \(rawValue)", userMessage: message) }
}

public struct LocalCleanupConfiguration: Equatable, Sendable {
    public let sourceLocale: String?
    public init(settings: Settings) { sourceLocale = settings.cleanup.localSourceLocale }
    public var validatedLocale: String? {
        guard let sourceLocale, !sourceLocale.isEmpty, sourceLocale.utf8.count <= 64,
              sourceLocale.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              Locale(identifier: sourceLocale).language.languageCode != nil else { return nil }
        return sourceLocale
    }
}

public struct LocalCleanupPrompt: Sendable {
    public let system: String, user: String
    public let locales: [String]
}

/// Bottom APIs only. Construction is inert; production uses the real guarded
/// framework and a fresh un-biased NLLanguageRecognizer on every invocation.
public struct LocalCleanupRuntime {
    public var availability: ([String]) -> LocalCleanupReason?
    public var language: (String) -> [String: Double]
    public var generate: (LocalCleanupPrompt, @escaping () throws -> Void) async throws -> String
    public var now: () -> TimeInterval
    public var sleep: (TimeInterval) async throws -> Void
    public var appLocale: () -> String
    public init(availability: @escaping ([String]) -> LocalCleanupReason? = LocalCleanupNative.availability,
                language: @escaping (String) -> [String: Double] = LocalCleanupNative.language,
                generate: @escaping (LocalCleanupPrompt, @escaping () throws -> Void) async throws -> String = LocalCleanupNative.generate,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
                appLocale: @escaping () -> String = { Locale.current.identifier }) {
        self.availability = availability; self.language = language; self.generate = generate
        self.now = now; self.sleep = sleep; self.appLocale = appLocale
    }
    public func recheck(_ configuration: LocalCleanupConfiguration) -> LocalCleanupReason? {
        guard let locale = configuration.validatedLocale else { return .unknownLanguage }
        return availability([locale, "en", appLocale()])
    }
}

/// A cancellation request can precede handle installation. This owner retains
/// the real worker; neither deadline nor cancellation can release its caller.
final class LocalCleanupOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: LocalCleanupReason?
    private var cancel: (() -> Void)?
    func stop(_ reason: LocalCleanupReason) {
        let action = lock.withLock { if self.reason == nil { self.reason = reason }; return cancel }
        action?()
    }
    func install(_ action: @escaping () -> Void) {
        let stopped = lock.withLock { cancel = action; return reason != nil }
        if stopped { action() }
    }
    var stopped: LocalCleanupReason? { lock.withLock { reason } }
}

struct AppleIntelligenceCleanup: CleanupProviding, DiagnosticModelObserving, LocalSegmentPreflighting {
    let configuration: LocalCleanupConfiguration
    let runtime: LocalCleanupRuntime
    let usage: CleanupUsageSink
    var executionPolicy: HistoryRetryExecutionPolicy? = nil
    var diagnostics: DiagnosticOperation?
    func observing(_ diagnostics: DiagnosticOperation) -> CleanupProviding {
        var copy = self; copy.diagnostics = diagnostics; return copy
    }
    // Nonisolated async entry uses the cooperative executor, never an app-main
    // inference task or a second queue. The existing processTask owns this await.
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        let owner = LocalCleanupOwner(), deadline = runtime.now() + (try executionPolicy?.remaining() ?? 15)
        func check() throws {
            try executionPolicy?.check()
            if Task.isCancelled { owner.stop(.canceled) }
            if runtime.now() >= deadline { owner.stop(.deadline) }
            if let reason = owner.stopped { throw reason.error }
        }
        do {
            try check()
            guard context.selection == nil ? context.localIntent == .ordinary : context.localIntent == .savedSameLanguageRewrite else { throw LocalCleanupReason.unsupportedAction.error }
            guard let locale = configuration.validatedLocale else { throw LocalCleanupReason.unknownLanguage.error }
            if let reason = runtime.recheck(configuration) { throw reason.error }
            try check()
            let prompt = try prepare(transcript: transcript, context: context, locale: locale)
            try check()
            if let reason = runtime.availability(prompt.locales) { throw reason.error }
            try check()
            let worker = Task { () -> Result<String, Error> in
                do {
                    try check()
                    let result = try await runtime.generate(prompt) {
                        try check()
                        try executionPolicy?.attempt()
                        diagnostics?.update { $0.localGenerationAttempted = true; $0.requestedProviderModel = .appleIntelligence; $0.providerOutcome = .attempted }
                    }
                    try check()
                    return .success(result)
                } catch { return .failure(error) }
            }
            owner.install { worker.cancel() }
            let watchdog = Task {
                do {
                    try await runtime.sleep(max(0, deadline - runtime.now()))
                    if !Task.isCancelled, runtime.now() >= deadline { owner.stop(.deadline) }
                } catch { /* cancellation is joined below */ }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { owner.stop(.canceled) })
            watchdog.cancel()
            await watchdog.value
            try check()
            let text: String
            do { text = try result.get() }
            catch let error as CleanupError {
                throw (LocalCleanupReason.from(error) ?? .unavailable).error
            }
            catch let reason as LocalCleanupReason { throw reason.error }
            catch { throw LocalCleanupReason.unavailable.error }
            guard text.utf8.count <= 32 * 1024 else { throw LocalCleanupReason.oversized.error }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalCleanupReason.empty.error }
            try language(text, expected: locale)
            try check()
            diagnostics?.update { $0.resolvedProviderModel = .appleIntelligence }
            usage("Apple Intelligence · on-device", nil, nil)
            return text
        } catch let error as CleanupError {
            diagnostics?.update { $0.localCleanupReason = LocalCleanupReason.from(error) ?? .unavailable }
            throw error
        } catch {
            diagnostics?.update { $0.localCleanupReason = .unavailable }
            throw LocalCleanupReason.unavailable.error
        }
    }

    func preflight(transcript: String, context: CleanupContext) throws {
        try executionPolicy?.check()
        guard context.selection == nil ? context.localIntent == .ordinary : context.localIntent == .savedSameLanguageRewrite else { throw LocalCleanupReason.unsupportedAction.error }
        guard let locale = configuration.validatedLocale else { throw LocalCleanupReason.unknownLanguage.error }
        if let reason = runtime.recheck(configuration) { throw reason.error }
        let prompt = try prepare(transcript: transcript, context: context, locale: locale)
        if let reason = runtime.availability(prompt.locales) { throw reason.error }
        try executionPolicy?.check()
    }

    private func prepare(transcript: String, context: CleanupContext, locale: String) throws -> LocalCleanupPrompt {
        var bytes = 0
        func add(_ text: String, limit: Int) throws {
            // Bounded traversal before interpolation/joining a second large prompt.
            for _ in text.utf8 { bytes += 1; if bytes > limit { throw LocalCleanupReason.inputTooLarge.error } }
        }
        try add(transcript, limit: 8192)
        if let prefix = context.precedingText { try add(prefix.text, limit: 12 * 1024) }
        if let selection = context.selection { try add(selection, limit: 8192) }
        // All configured rules must fit; do not silently use the network hint prefix.
        for word in context.localDictionary { try add(word, limit: 12 * 1024) }
        for (key, value) in context.snippets { try add(key, limit: 12 * 1024); try add(value, limit: 12 * 1024) }
        let inputLanguage = try language(transcript, expected: context.selection == nil ? locale : nil)
        if let selection = context.selection { try language(selection, expected: locale) }
        for word in context.localDictionary { try language(word, expected: locale) }
        for (key, value) in context.snippets { try language(key, expected: locale); try language(value, expected: locale) }
        var complete = context
        complete.dictionary = context.localDictionary
        // PromptBuilder's existing network vocabulary budget must not drop a rule.
        guard VocabularyHints.select(complete.dictionary, byteLimit: VocabularyHints.cleanupBytes) == complete.dictionary else { throw LocalCleanupReason.inputTooLarge.error }
        let system = PromptBuilder.system(context: complete) + "\n\nPreserve the source language. The explicitly declared source and output locale is \(locale). Never translate."
        let user = PromptBuilder.user(transcript: transcript, context: complete)
        guard system.utf8.count + user.utf8.count <= 16 * 1024 else { throw LocalCleanupReason.inputTooLarge.error }
        return LocalCleanupPrompt(system: system, user: user, locales: [locale, inputLanguage, "en", runtime.appLocale()])
    }

    @discardableResult private func language(_ text: String, expected: String?) throws -> String {
        func evidence(_ value: String, expected: String?) throws -> String {
            guard value.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 24,
                  value.split(whereSeparator: { $0.isWhitespace }).count >= 4,
                  value.rangeOfCharacter(from: CharacterSet(charactersIn: "{}[]=<>`\\")) == nil else { throw LocalCleanupReason.unknownLanguage.error }
            let scores = runtime.language(value).sorted { $0.value > $1.value }
            guard let top = scores.first, top.value >= 0.95, (scores.dropFirst().first?.value ?? 0) <= 0.05 else { throw LocalCleanupReason.unknownLanguage.error }
            if let expected, Locale(identifier: top.key).language.languageCode != Locale(identifier: expected).language.languageCode { throw LocalCleanupReason.mixedLanguage.error }
            if let reason = runtime.availability([top.key]) { throw reason.error }
            return top.key
        }
        let detected = try evidence(text, expected: expected)
        // Check every informative sentence; short fragments refuse rather than
        // being silently omitted. Overlapping 240-character windows, stride 120,
        // include the final tail. Whole text is bounded before this allocation.
        for part in text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) where part.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
            _ = try evidence(part, expected: detected)
        }
        let characters = Array(text)
        if characters.count > 240 {
            var start = 0
            while start + 240 < characters.count { _ = try evidence(String(characters[start..<start + 240]), expected: detected); start += 120 }
            _ = try evidence(String(characters.suffix(240)), expected: detected)
        }
        return detected
    }
}

public enum LocalCleanupNative {
    public static func language(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 2).map { ($0.key.rawValue, $0.value) })
    }
    public static func availability(_ locales: [String]) -> LocalCleanupReason? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .oldOS }
        return nativeAvailability(locales)
        #else
        return .missingFramework
        #endif
    }
    public static func generate(_ prompt: LocalCleanupPrompt, attempted: @escaping () throws -> Void) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw LocalCleanupReason.oldOS }
        return try await nativeGenerate(prompt, attempted: attempted)
        #else
        throw LocalCleanupReason.missingFramework
        #endif
    }
    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func nativeAvailability(_ locales: [String]) -> LocalCleanupReason? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .ineligible
            case .appleIntelligenceNotEnabled: return .disabled
            case .modelNotReady: return .notReady
            @unknown default: return .unavailable
            }
        @unknown default: return .unavailable
        }
        return locales.allSatisfy { model.supportsLocale(Locale(identifier: $0)) } ? nil : .unsupportedLanguage
    }
    @available(macOS 26.0, *)
    private static func nativeGenerate(_ prompt: LocalCleanupPrompt, attempted: @escaping () throws -> Void) async throws -> String {
        try Task.checkCancellation()
        if let reason = nativeAvailability(prompt.locales) { throw reason }
        try Task.checkCancellation()
        let session = LanguageModelSession(model: SystemLanguageModel.default, tools: [], instructions: prompt.system)
        do {
            try Task.checkCancellation()
            try attempted()
            let result = try await session.respond(to: prompt.user, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: nil))
            try Task.checkCancellation()
            return result.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw LocalCleanupReason.contextLimit
            case .assetsUnavailable: throw LocalCleanupReason.notReady
            case .guardrailViolation, .refusal: throw LocalCleanupReason.refusedOrSafety
            case .unsupportedLanguageOrLocale: throw LocalCleanupReason.unsupportedLanguage
            case .rateLimited: throw LocalCleanupReason.rateLimited
            default: throw LocalCleanupReason.unavailable
            }
        } catch is CancellationError { throw LocalCleanupReason.canceled }
        catch { throw LocalCleanupReason.unavailable }
    }
    #endif
}
