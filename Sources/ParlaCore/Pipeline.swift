import Foundation

public struct Pipeline {
    public enum FailureLogging { case details, contentFree }
    public var failureLogging: FailureLogging = .details
    public var log: (String) -> Void = { NSLog("%@", $0) }
    private func logFailure(_ error: Error) {
        log(failureLogging == .contentFree ? "Parla cleanup failed; using local fallback"
            : "Parla cleanup failed, keeping raw transcript: \(error)")
    }
    /// nil ⇒ the whisper pass failed or was aborted (not "no speech" — that is "").
    public var transcribe: ([Float], String?) async -> String?
    public var cleanup: (String, CleanupContext) async throws -> String
    public var settings: () -> Settings
    /// The destination app's bundle ID, not its name: the only thing the prompt
    /// does with the destination is pick a tone hint by `AppCategory`, and that
    /// is keyed on the bundle ID (`CleanupContext.appName` reaches nothing).
    public var frontBundleID: () -> String?
    public var frontBrowserURL: () -> String? = { nil }
    public var singleLine: Bool = false
    public var diagnostics: DiagnosticOperation?
    public var failoverRun: CleanupFailoverRun?
    /// Lazy only after ordinary bypasses. nil means pre-issuance category eligibility.
    public var surroundingText: ((String, CleanupContext) async throws -> String?)?

    public init(transcribe: @escaping ([Float], String?) async -> String?,
                cleanup: @escaping (String, CleanupContext) async throws -> String,
                settings: @escaping () -> Settings,
                frontBundleID: @escaping () -> String?) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.settings = settings
        self.frontBundleID = frontBundleID
    }

    /// Production output seam: the resolved settings are captured by value, including
    /// the provider's model. Disabled cleanup and locked snippets never call the factory.
    public init(outputSettings: Settings, bundleID: String?, browserURL: String? = nil,
                singleLine: Bool = false, diagnostics: DiagnosticOperation? = nil, failureLogging: FailureLogging = .details,
                makeClient: @escaping (Settings) throws -> CleanupProviding) {
        self.init(transcribe: { _, _ in nil }, cleanup: { text, context in
            let client = try diagnostics.map { diagnostic in
                try diagnostic.makeProvider(settings: outputSettings) { try makeClient(outputSettings) }
            } ?? makeClient(outputSettings)
            return try await client.clean(transcript: text, context: context)
        }, settings: { outputSettings }, frontBundleID: { bundleID })
        frontBrowserURL = { browserURL }
        self.singleLine = singleLine
        self.diagnostics = diagnostics
        self.failureLogging = failureLogging
    }

    /// Whisper pass only: trimmed transcript, nil when empty OR when the pass
    /// failed. Split from clean() so the caller can finalize raw text instantly
    /// and polish behind it.
    public func transcript(samples: [Float]) async -> String? {
        // The min-audio floor lives HERE, on the shared path, not on each caller:
        // whisper invents content on near-silence, and while the app happened to
        // check first, parla-eval — driving this same Pipeline — did not, so it
        // decoded 1.6s of room tone (rms 8.3e-5) as "Testosterone.swift," and
        // scored it. One guard, so the eval measures what ships.
        if let skip = Self.recognitionSkip(samples: samples) {
            diagnostics?.update { $0.asr = skip == .minimumDuration ? .minimumDuration : .silence }
            return nil
        }
        let s = settings()
        let prompt = VocabularyHints.asrPrompt(s.dictionary)
        return Self.transcriptProjection(await transcribe(samples, prompt))
    }
    public static func recognitionSkip(samples: [Float]) -> RecognitionSkip? {
        TextRules.audioWorthTranscribing(sampleCount: samples.count, rms: AudioRecorder.rms(samples))
            ? nil : samples.count < 6400 ? .minimumDuration : .silence
    }
    public static func transcriptProjection(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Whole-transcript snippet match — TypeWhisper's `literal_locked`. When the
    /// whole transcript IS a trigger the expansion is a pure string substitution,
    /// so doing it here is instant and right every time, where asking the LLM for
    /// it was neither. Whole-transcript only on purpose: expanding a trigger buried
    /// in a longer utterance re-introduces the "did they mean the phrase or the
    /// snippet" ambiguity this removes, so those stay with the prompt block.
    /// Case and punctuation fold because this matches ASR output, via the same
    /// normalizer the eval harness scores with. Longest trigger wins so two
    /// triggers that fold alike resolve identically every run — a Dictionary has
    /// no order to fall back on.
    public static func snippetExpansion(transcript: String,
                                        snippets: [String: String]) -> String? {
        let key = Eval.normalizeForWER(transcript)
        guard !key.isEmpty else { return nil }
        return snippets.filter { Eval.normalizeForWER($0.key) == key }
            .sorted {
                $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count > $1.key.count
            }.first?.value
    }

    /// LLM cleanup, sanitized. Never throws — cleanup must never kill a
    /// dictation, so failures hand back the raw transcript and a safe message
    /// so the caller can tell the user why nothing changed.
    public func clean(transcript: String) async -> (text: String, failure: String?) {
        let s = settings()
        diagnostics?.providerSettings(s)
        if s.outputMode == .raw { diagnostics?.update { $0.providerOutcome = .off }; return (transcript, nil) }
        if s.outputMode == .selectedPreset {
            do {
                let preset = try s.selectedTransformPreset()
                let operation = IntentionalTransform(source: transcript, instruction: preset.intent, settings: s, preset: preset)
                let result = try await operation.run { _ in
                    // Adapter keeps the same injectable production provider seam.
                    TransformCleanup(cleanup: cleanup)
                }
                return (result, nil)
            } catch {
                if s.usesAppleIntelligence { diagnostics?.update { $0.localCleanupReason = LocalCleanupReason.from(error) } }
                diagnostics?.update { if $0.providerOutcome == .returned { $0.providerOutcome = .invalidResult } else if $0.providerOutcome == .unknown { $0.providerOutcome = .refused } }
                return (transcript, IntentionalTransform.failureMessage(error))
            }
        }
        // Locked snippets bypass both the provider and local replacements.
        if let expansion = Pipeline.snippetExpansion(transcript: transcript, snippets: s.snippets) {
            diagnostics?.update { $0.providerOutcome = .localSnippet }
            return (expansion, nil)
        }
        guard s.cleanupEnabled else {
            diagnostics?.update { $0.providerOutcome = .off }
            return (LiteralReplacement.apply(s.replacements, to: transcript), nil)
        }
        let result = await cleanWithProvider(transcript: transcript, settings: s)
        return (LiteralReplacement.apply(s.replacements, to: result.text), result.failure)
    }

    private func cleanWithProvider(transcript: String, settings s: Settings) async -> (text: String, failure: String?) {
        let ctx = CleanupContext(dictionary: s.dictionary, snippets: s.snippets,
                                 appName: nil, bundleID: frontBundleID(),
                                 browserURL: frontBrowserURL(), singleLine: singleLine, style: s.cleanupStyle)
        do {
            let contextual = try await surroundingText?(transcript, ctx)
            let candidate: String
            if let contextual { candidate = contextual } else { candidate = try await cleanup(transcript, ctx) }
            let cleaned = CleanupSanitizer.sanitize(candidate)
            if let failure = CleanupOutput.validationFailure(cleaned, source: transcript, snippets: s.snippets) {
                NSLog("Parla cleanup returned invalid text, keeping raw transcript")
                diagnostics?.update { $0.providerOutcome = .invalidResult }
                try failoverRun?.adjudicate(accepted: false)
                return (transcript, failure)
            }
            try failoverRun?.adjudicate(accepted: true)
            return (cleaned, nil)
        } catch let error as CleanupError {
            logFailure(error)
            return (transcript, error.userMessage)
        } catch let error as URLError {
            logFailure(error)
            return (transcript, error.code == .timedOut
                    ? "cleanup timed out" : "cleanup network unavailable")
        } catch {
            logFailure(error)
            return (transcript, "cleanup failed")
        }
    }

    public func process(samples: [Float]) async -> String? {
        guard let t = await transcript(samples: samples) else { return nil }
        return await clean(transcript: t).text
    }
}

private struct TransformCleanup: CleanupProviding {
    let cleanup: (String, CleanupContext) async throws -> String
    func clean(transcript: String, context: CleanupContext) async throws -> String {
        try await cleanup(transcript, context)
    }
}

/// Shared acceptance guards, not a semantic preservation test. Call sanitation
/// once on each provider output; assembly uses validation without re-sanitation.
public enum CleanupOutput {
    public static func validationFailure(_ cleaned: String, source: String, snippets: [String: String] = [:]) -> String? {
        if cleaned.isEmpty { return "cleanup returned no text" }
        let rawLower = source.lowercased()
        let allowance = 2 * source.count + 200 + snippets.reduce(0) { total, snippet in
            let key = snippet.key.lowercased()
            guard !key.isEmpty else { return total }
            var count = 0, start = rawLower.startIndex
            while let range = rawLower.range(of: key, range: start..<rawLower.endIndex) {
                count += 1; start = range.upperBound
            }
            return total + snippet.value.count * count
        }
        if cleaned.count > allowance { return "cleanup returned invalid text" }
        if source.count >= 80, cleaned.count < source.count / 5 { return "cleanup returned truncated text" }
        return nil
    }
}
