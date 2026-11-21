import Foundation
import os
import whisper

public struct TranscriberError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public struct WhisperNativeDecode: Equatable {
    public let status: Int32
    public let segments: [String]
    public let abortObserved: Bool
    public let timing: RecognitionSegments?
    /// Only when `WhisperExperiment.collectEvidence` asked for it.
    public let evidence: [WhisperDecodeEvidence.Segment]?
    /// Only when a timed decode asked for word timing; never present without `timing`.
    public let words: RecognitionWords?
    public init(status: Int32, segments: [String] = [], abortObserved: Bool = false, timing: RecognitionSegments? = nil,
                evidence: [WhisperDecodeEvidence.Segment]? = nil, words: RecognitionWords? = nil) {
        self.status = status; self.segments = segments; self.abortObserved = abortObserved
        self.timing = timing; self.evidence = evidence; self.words = words
    }
}
/// Eval-process decoder switches. The defaults are the shipping decode; no app path sets any of them.
public struct WhisperExperiment: Equatable, Sendable {
    public var suppressNonSpeechTokens = false
    public var carryInitialPrompt = false
    public var beamSize: Int32? = nil          // nil = greedy (shipping)
    public var vadModelPath: String? = nil     // nil = no VAD (shipping)
    public var collectEvidence = false
    public init() {}
    /// `parla-eval --experiment` grammar: comma-separated `suppress-nst`, `carry-prompt`, `beam=N` (2…8),
    /// `vad=PATH` (must exist). Nil for any unknown, repeated or out-of-range token.
    public static func parse(_ list: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> WhisperExperiment? {
        var experiment = WhisperExperiment(), seen = Set<String>()
        for token in list.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, seen.insert(key).inserted else { return nil }
            switch (key, parts.count == 2 ? parts[1] : nil) {
            case ("suppress-nst", nil): experiment.suppressNonSpeechTokens = true
            case ("carry-prompt", nil): experiment.carryInitialPrompt = true
            case ("beam", let value?):
                guard let beam = Int32(value), (2...8).contains(beam) else { return nil }
                experiment.beamSize = beam
            case ("vad", let path?):
                guard !path.isEmpty, fileExists(path) else { return nil }
                experiment.vadModelPath = path
            default: return nil
            }
        }
        return experiment
    }
    /// Short suffix that makes the experiment visible in result labels; empty for the shipping decode.
    public var label: String {
        var parts: [String] = []
        if suppressNonSpeechTokens { parts.append("suppress-nst") }
        if carryInitialPrompt { parts.append("carry-prompt") }
        if let beamSize { parts.append("beam=\(beamSize)") }
        if let vadModelPath { parts.append("vad=" + (vadModelPath as NSString).lastPathComponent) }
        return parts.joined(separator: "+")
    }
}
/// Raw decoder evidence for eval runs. Token probabilities are the decoder's raw per-token
/// probabilities: not calibrated accuracy, and not OpenAI's `avg_logprob` or compression ratio.
public struct WhisperDecodeEvidence: Equatable, Sendable, Codable {
    public struct Segment: Equatable, Sendable, Codable {
        public let noSpeechProbability: Float
        public let tokens: Int
        public let meanTokenProbability: Float
    }
    public let segments: [Segment]
    public let languageRetry: Bool
    public let requestedLanguage: String
    public let detectedLanguage: String?
}
/// Values applied to the C params; defaults retain native temperature fallback and audio context.
public struct WhisperDecodeConfiguration: Equatable {
    public let threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    public let noTimestamps: Bool
    public let printProgress = false
    public let printRealtime = false
    public let printSpecial = false
    public let nativeTemperatureFallback = true
    public let nativeAudioContext = true
    public let experiment: WhisperExperiment
    /// Heuristic per-call `token_timestamps`; only a timed configuration can set it.
    public let wordTiming: Bool
    public var greedySampling: Bool { experiment.beamSize == nil }
    public init(experiment: WhisperExperiment = .init()) { noTimestamps = true; self.experiment = experiment; wordTiming = false }
    init(timed: Bool, experiment: WhisperExperiment = .init(), wordTiming: Bool = false) {
        noTimestamps = !timed; self.experiment = experiment; self.wordTiming = timed && wordTiming
    }
}
/// Raw native operations only. Language policy and text cleanup live in the real adapter.
public protocol WhisperNativeContext: AnyObject {
    var multilingual: Bool { get }
    var promptBudget: PromptBudget? { get }
    func knowsLanguage(_ code: String) -> Bool
    func spokenLanguage() -> String?
    func decode(_ samples: [Float], initialPrompt: String?, language: String,
                configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode
    func decodeTimed(_ samples: [Float], initialPrompt: String?, language: String,
                     configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode?
}
public extension WhisperNativeContext {
    var promptBudget: PromptBudget? { nil }
    func decodeTimed(_ samples: [Float], initialPrompt: String?, language: String,
                     configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode? { nil }
}

/// Last detected language per model path, in memory only. A hint is a first guess; a stale one costs one retry.
public final class WhisperLanguageHints {
    private let state = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    public init() {}
    public func last(for model: String) -> String? { state.withLock { $0[model] } }
    public func record(_ language: String, for model: String) { state.withLock { $0[model] = language } }
}

public final class WhisperTranscriber: RecognitionClient {
    private let native: WhisperNativeContext
    public var capabilities: RecognitionCapabilities {
        RecognitionCapabilities(modelLanguages: native.multilingual ? .multilingual : .englishOnly)
    }
    private let spoken: OSAllocatedUnfairLock<(pinned: String?, last: String)>
    private let hints: WhisperLanguageHints?
    private let modelPath: String
    private let eval = OSAllocatedUnfairLock(initialState: (experiment: WhisperExperiment(), evidence: WhisperDecodeEvidence?.none))
    /// Eval-only decoder switches for ordinary (untimed) decodes.
    public var experiment: WhisperExperiment {
        get { eval.withLock { $0.experiment } }
        set { eval.withLock { $0.experiment = newValue } }
    }
    /// Evidence of the last ordinary recognition when `experiment.collectEvidence`; read after the call.
    public var lastEvidence: WhisperDecodeEvidence? { eval.withLock { $0.evidence } }
    public static func defaultModelPath() -> String { ModelCatalog.path(for: ModelCatalog.default) }
    public static var languages: [(code: String, name: String)] { WhisperCContext.languages }
    public var promptBudget: PromptBudget? { native.promptBudget }
    public var language: String? {
        get { spoken.withLock { $0.pinned } }
        set { spoken.withLock { $0.pinned = newValue } }
    }
    public convenience init(modelPath: String, language: String? = nil) throws {
        try self.init(modelPath: modelPath, language: language, native: WhisperCContext(modelPath, .nativeDefaults))
    }
    public init(modelPath: String, language: String? = nil, native: WhisperNativeContext,
                hints: WhisperLanguageHints? = nil) throws {
        self.native = native; self.hints = hints; self.modelPath = modelPath
        spoken = OSAllocatedUnfairLock(initialState: (pinned: language, last: hints?.last(for: modelPath) ?? "en"))
    }
    public func transcribe(_ samples: [Float], initialPrompt: String?, shouldAbort: (() -> Bool)? = nil) async -> String? {
        await transcribe(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort)
    }
    public func transcribe(_ samples: [Float], initialPrompt: String?, language: String?,
                           shouldAbort: (() -> Bool)? = nil) async -> String? {
        let outcome = await recognize(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort)
        return shouldAbort?() == true ? nil : outcome.text
    }
    public func recognize(_ samples: [Float], initialPrompt: String?, language: String?,
                          shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        return recognizeNative(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort)
    }
    public func recognizeTimed(_ samples: [Float], initialPrompt: String?, language: String?,
                               shouldAbort: (() -> Bool)?) async -> RecognitionNativeOutcome {
        await recognizeTimed(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort, wordTiming: false)
    }
    /// `wordTiming` adds experimental heuristic word times; no app path sets it.
    public func recognizeTimed(_ samples: [Float], initialPrompt: String?, language: String?,
                               shouldAbort: (() -> Bool)?, wordTiming: Bool) async -> RecognitionNativeOutcome {
        guard shouldAbort?() != true else { return .canceled }
        // A pinned language removes the ordinary auto probe/retry. Never repair timing.
        let code: String
        if !native.multilingual { code = "en" }
        else if let language, native.knowsLanguage(language) { code = language }
        else { return .failed(.unsupportedCapability) }
        return decodeOutcome(samples, initialPrompt: initialPrompt, language: code, shouldAbort: shouldAbort, timed: true, wordTiming: wordTiming)
    }
    /// Synchronous native body; only the awaited adapter enters it in production.
    private func recognizeNative(_ samples: [Float], initialPrompt: String?, language: String?,
                                 shouldAbort: (() -> Bool)?) -> RecognitionNativeOutcome {
        let experiment = self.experiment
        var decodes: [(language: String, decode: WhisperNativeDecode)] = []
        func decode(_ code: String) -> RecognitionNativeOutcome {
            decodeOutcome(samples, initialPrompt: initialPrompt, language: code, shouldAbort: shouldAbort,
                          experiment: experiment) { decodes.append((code, $0)) }
        }
        let outcome = recognizeWithLanguagePolicy(language, shouldAbort: shouldAbort, decode: decode)
        let evidence = experiment.collectEvidence ? decodes.last.map { last in
            WhisperDecodeEvidence(segments: last.decode.evidence ?? [], languageRetry: decodes.count > 1,
                                  requestedLanguage: decodes[0].language,
                                  detectedLanguage: { if case .completed(let p) = outcome { return p.detectedLanguage }; return nil }())
        } : nil
        eval.withLock { $0.evidence = evidence }
        return outcome
    }
    private func recognizeWithLanguagePolicy(_ language: String?, shouldAbort: (() -> Bool)?,
                                             decode: (String) -> RecognitionNativeOutcome) -> RecognitionNativeOutcome {
        guard shouldAbort?() != true else { return .canceled }
        guard native.multilingual else { return decode("en") }
        if let language, native.knowsLanguage(language) { return decode(language) }
        let guess = spoken.withLock { $0.last }
        let first = decode(guess)
        guard shouldAbort?() != true, case .completed(let payload) = first, !payload.text.isEmpty,
              let actual = native.spokenLanguage() else { return first }
        guard actual != guess else { return .completed(.init(text: payload.text, detectedLanguage: actual)) }
        spoken.withLock { $0.last = actual }
        hints?.record(actual, for: modelPath)
        let retry = decode(actual)
        if case .completed(let result) = retry { return .completed(.init(text: result.text, detectedLanguage: actual)) }
        return retry
    }
    private func decodeOutcome(_ samples: [Float], initialPrompt: String?, language: String,
                               shouldAbort: (() -> Bool)?, timed: Bool = false, wordTiming: Bool = false, experiment: WhisperExperiment = .init(),
                               record: ((WhisperNativeDecode) -> Void)? = nil) -> RecognitionNativeOutcome {
        guard shouldAbort?() != true else { return .canceled }
        let result: WhisperNativeDecode
        if timed {
            guard !samples.isEmpty, samples.count <= Int32.max,
                  let decoded = native.decodeTimed(samples, initialPrompt: initialPrompt, language: language,
                      configuration: WhisperDecodeConfiguration(timed: true, wordTiming: wordTiming), shouldAbort: shouldAbort) else { return .failed(.unsupportedCapability) }
            result = decoded
            guard !result.abortObserved else { return .canceled }
        } else {
            result = native.decode(samples, initialPrompt: initialPrompt, language: language,
                                   configuration: WhisperDecodeConfiguration(experiment: experiment), shouldAbort: shouldAbort)
            record?(result)
        }
        guard result.status == 0 else { return result.abortObserved ? .canceled : .failed(.nativeDecode) }
        // Keep observed native success even if cancellation won delivery on return.
        return .completed(.init(text: Self.stripNonSpeech(result.segments.joined().trimmingCharacters(in: .whitespacesAndNewlines)),
                                segments: timed ? result.timing : nil, words: timed ? result.words : nil))
    }
    func decode(_ samples: [Float], initialPrompt: String?, language: String,
                shouldAbort: (() -> Bool)? = nil) -> String? {
        let result = decodeOutcome(samples, initialPrompt: initialPrompt, language: language, shouldAbort: shouldAbort)
        return shouldAbort?() == true ? nil : result.text
    }
    /// Whisper emits bracketed markers on non-speech audio — "[BLANK_AUDIO]",
    /// "[MUSIC]", "(silence)", "*sigh*" — which must never be typed or pasted.
    /// Two layers, each covering the other's blind spot:
    /// 1. Emptiness is decided on marker SPANS, so multi-word forms like
    ///    "(upbeat music)" count — per-token matching tokenized that to
    ///    ["(upbeat", "music)"], neither a marker, and typed the whole thing.
    ///    A transcript that is nothing but such spans becomes "".
    /// 2. Mixed content drops single-token markers only ("Hello. [BLANK_AUDIO]"
    ///    → "Hello."): a multi-word span beside real speech could be a spoken
    ///    parenthetical, and we cannot tell a hallucination from dictated
    ///    punctuation, so those survive verbatim.
    public static func stripNonSpeech(_ text: String) -> String {
        // Layer 1: nothing-but-markers → "". Spans, not tokens, so multi-word
        // markers count; only used for the emptiness decision.
        let markerSpan = #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#
        let remainder = text
            .replacingOccurrences(of: markerSpan, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.isEmpty { return "" }
        // Layer 2: real speech present — drop single-token markers.
        let wrapped = ["[": "]", "(": ")", "*": "*"]
        let isMarker = { (word: Substring) -> Bool in
            guard let first = word.first, let close = wrapped[String(first)] else { return false }
            // Two or more characters inside the wrapper: every marker whisper emits
            // qualifies, while dictated "[0]" and "(a)" survive. Per-token matching
            // has no all-or-nothing net under it, so this is the false-positive guard.
            return word.hasSuffix(close) && word.count > 3
        }
        // Split on any whitespace, not just " " — a marker on its own line was never
        // seen as a token before. Empty subsequences are dropped, so rejoining with a
        // single space leaves no doubled or edge spaces.
        return text.split(whereSeparator: { $0.isWhitespace }).filter { !isMarker($0) }.joined(separator: " ")
    }
}

/// The only raw-pointer owner. The context and abort userdata live through the actual C return.
public final class WhisperCContext: WhisperNativeContext {
    public static let languages: [(code: String, name: String)] = (0...whisper_lang_max_id())
        .compactMap { id in
            guard let code = whisper_lang_str(id), let name = whisper_lang_str_full(id) else { return nil }
            return (String(cString: code), String(cString: name).capitalized)
        }.sorted { $0.name < $1.name }
    /// The injected seam is below the real params/abort/getter mapper. Production
    /// captures one context here; getters cannot outlive its owning CContext.
    struct API {
        var multilingual = false
        var nTextLayer: Int32 = 6
        var nVocab: Int32 = 51_864
        var textContext: Int32 = 448
        var tokenize: (String) -> Int = { $0.utf8.count }
        var knowsLanguage: (String) -> Bool = { $0 == "en" }
        var spokenLanguage: () -> String? = { nil }
        var full: (whisper_full_params, UnsafePointer<Float>?, Int32) -> Int32 = { _, _, _ in -1 }
        var count: () -> Int32 = { 0 }
        var text: (Int32) -> UnsafePointer<CChar>? = { _ in nil }
        var start: (Int32) -> Int64 = { _ in -1 }
        var end: (Int32) -> Int64 = { _ in -1 }
        var noSpeechProbability: (Int32) -> Float = { _ in 0 }
        var tokenCount: (Int32) -> Int32 = { _ in 0 }
        var tokenProbability: (Int32, Int32) -> Float = { _, _ in 0 }
        var tokenText: (Int32, Int32) -> UnsafePointer<CChar>? = { _, _ in nil }
        var tokenData: (Int32, Int32) -> whisper_token_data = { _, _ in whisper_token_data() }
        var eot: Int32 = 50_256
        var release: () -> Void = {}
    }
    private let api: API
    public let multilingual: Bool
    private static let threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    /// Process-scoped build identity is deliberately conservative, not a claimed binary digest.
    public static let runtime = RecognitionRuntime(nativeVersion: String(cString: whisper_version()),
                                                   buildScope: UUID().uuidString)
    public init(_ modelPath: String, _ compute: WhisperComputeConfiguration, preparation: PreparationPermit? = nil) throws {
        // Preserve native v1.9.1 GPU/flash-attention defaults; actual device is unknown.
        guard compute == .nativeDefaults else { throw TranscriberError(description: "Unsupported native defaults revision") }
        var params = whisper_context_default_params()
        params.dtw_token_timestamps = false
        var returned: OpaquePointer?
        let initialize = {
            returned = whisper_init_from_file_with_params(modelPath, params)
            guard let returned else { throw TranscriberError(description: "failed to load whisper model at \(modelPath)") }
            return returned
        }
        let ctx: OpaquePointer
        do {
            ctx = try preparation.map { try $0.nativeEntry(initialize) } ?? initialize()
        } catch {
            if let returned { whisper_free(returned) } // terminal persistence failure must not leak a returned pointer
            throw error
        }
        // A 51865 vocabulary has 99 languages: id 99 would index the translate token.
        let languages = Self.languageCount(sot: whisper_token_sot(ctx), translate: whisper_token_translate(ctx))
        api = API(multilingual: whisper_is_multilingual(ctx) != 0,
            nTextLayer: whisper_model_n_text_layer(ctx), nVocab: whisper_model_n_vocab(ctx),
            textContext: whisper_n_text_ctx(ctx),
            // A token consumes at least one byte, so a byte-sized buffer always fits.
            // Never whisper_token_count: it logs on every call and is not WHISPER_API.
            tokenize: { text in
                var tokens = [whisper_token](repeating: 0, count: max(1, text.utf8.count))
                return max(0, Int(whisper_tokenize(ctx, text, &tokens, Int32(tokens.count))))
            },
            knowsLanguage: { let id = whisper_lang_id($0); return id >= 0 && id < languages },
            spokenLanguage: { Self.detectedLanguage(ctx, languages: languages) },
            full: { whisper_full(ctx, $0, $1, $2) }, count: { whisper_full_n_segments(ctx) },
            text: { whisper_full_get_segment_text(ctx, $0) }, start: { whisper_full_get_segment_t0(ctx, $0) },
            end: { whisper_full_get_segment_t1(ctx, $0) },
            noSpeechProbability: { whisper_full_get_segment_no_speech_prob(ctx, $0) },
            tokenCount: { whisper_full_n_tokens(ctx, $0) }, tokenProbability: { whisper_full_get_token_p(ctx, $0, $1) },
            tokenText: { whisper_full_get_token_text(ctx, $0, $1) }, tokenData: { whisper_full_get_token_data(ctx, $0, $1) },
            eot: whisper_token_eot(ctx),
            release: { whisper_free(ctx) })
        multilingual = api.multilingual
    }
    init(api: API) { self.api = api; multilingual = api.multilingual }
    /// Set by the first experiment decode; native state (VAD mappings) may outlive that call.
    private var ranExperiment = false
    deinit { api.release() }
    /// whisper_tokenize only reads the vocabulary, so it is safe beside whisper_full.
    /// The closure keeps this context alive; callers must not store the budget.
    public var promptBudget: PromptBudget? {
        PromptBudget(capacity: max(0, Int(api.textContext) / 2 - 1), count: { [self] in api.tokenize($0) })
    }
    public func knowsLanguage(_ code: String) -> Bool { api.knowsLanguage(code) }
    public func spokenLanguage() -> String? { api.spokenLanguage() }
    static func languageCount(sot: Int32, translate: Int32) -> Int32 { max(0, translate - sot - 1) }
    private static func detectedLanguage(_ ctx: OpaquePointer, languages: Int32) -> String? {
        let ids = 0..<min(languages, whisper_lang_max_id() + 1)
        guard !ids.isEmpty else { return nil }
        var sot = whisper_token_sot(ctx)
        guard whisper_decode(ctx, &sot, 1, 0, Self.threads) == 0, let logits = whisper_get_logits(ctx) else { return nil }
        let best = ids.max {
            logits[Int(whisper_token_lang(ctx, $0))] < logits[Int(whisper_token_lang(ctx, $1))]
        }
        return best.flatMap { whisper_lang_str($0) }.map { String(cString: $0) }
    }
    public func decode(_ samples: [Float], initialPrompt: String?, language: String,
                       configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
        guard configuration.noTimestamps else { return .init(status: -1) }
        return decodeNative(samples, initialPrompt: initialPrompt, language: language, configuration: configuration, shouldAbort: shouldAbort)
    }
    public func decodeTimed(_ samples: [Float], initialPrompt: String?, language: String,
                            configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode? {
        // Exact pinned implementation predicate; no filename/family guessing. Never with an experiment.
        guard configuration.experiment == .init(), !ranExperiment, !(api.nTextLayer == 2 && api.nVocab != 51_866), !configuration.noTimestamps,
              !samples.isEmpty, samples.count <= Int32.max else { return nil }
        return decodeNative(samples, initialPrompt: initialPrompt, language: language, configuration: configuration, shouldAbort: shouldAbort)
    }
    private func decodeNative(_ samples: [Float], initialPrompt: String?, language: String,
                              configuration: WhisperDecodeConfiguration, shouldAbort: (() -> Bool)?) -> WhisperNativeDecode {
        let experiment = configuration.experiment
        if experiment != .init() { ranExperiment = true }
        var params = whisper_full_default_params(experiment.beamSize == nil ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH)
        if let beam = experiment.beamSize { params.beam_search.beam_size = beam }
        params.suppress_nst = experiment.suppressNonSpeechTokens
        params.carry_initial_prompt = experiment.carryInitialPrompt
        params.print_progress = configuration.printProgress
        params.print_realtime = configuration.printRealtime
        params.print_special = configuration.printSpecial
        params.no_timestamps = configuration.noTimestamps
        // VAD runs only for an eval experiment, and decodeTimed refuses any context that ever ran
        // one (`ranExperiment`), so the whisper191PCM10ms clock never sees a VAD map left over
        // from an earlier call. Context DTW is disabled at construction too.
        params.vad = experiment.vadModelPath != nil
        if !configuration.noTimestamps {
            params.offset_ms = 0; params.duration_ms = 0
            // Word timing is the per-call heuristic flag only (max_len stays 0); never context DTW.
            params.single_segment = false; params.token_timestamps = configuration.wordTiming
            params.translate = false; params.detect_language = false
            params.max_len = 0; params.max_tokens = 0; params.tdrz_enable = false
            params.print_timestamps = false
            params.encoder_begin_callback = nil; params.encoder_begin_callback_user_data = nil
        }
        // temperature fallback stays ENABLED (default temperature_inc): it's whisper's
        // guardrail against greedy-decode repetition loops ("same sentence × 28") —
        // observed in the wild when this was set to 0. Clean audio still decodes once;
        // only degenerate decodes pay for a retry.
        params.n_threads = configuration.threads
        // audio_ctx stays at the default full window: measured A/B showed restricting
        // it to the clip length collapses one-word clips into garbage ("branch" → "*")
        // and triggers multi-second retry storms, while a full 30s encode is only
        // ~130-200ms warm with Metal + flash-attn.

        // A C function pointer can't capture a Swift closure — pass the boxed closure through
        // abort_callback_user_data and unwrap it in the C-convention trampoline. Return true aborts.
        let abortBox = shouldAbort.map { AbortBox($0) }
        if let box = abortBox {
            params.abort_callback = { data in
                guard let data else { return false }
                return Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().poll()
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        }

        // vad_model_path is borrowed for the whisper_full call like the prompt below.
        func full(_ vadModel: UnsafePointer<CChar>?) -> Int32 {
            params.vad_model_path = vadModel
            return fullCall()
        }
        func fullCall() -> Int32 { withExtendedLifetime(abortBox) {
            samples.withUnsafeBufferPointer { buf in
                // Always set, never whisper's compiled default. The English
                // initial_prompt below (dictionary + cross-cut context) stays on for
                // every language: voxtype #233 saw one drag a detected-Portuguese
                // decode into English, but Hindi and Spanish clips on large-v3-turbo
                // kept their language with it here.
                // language is borrowed for the whisper_full call, so it needs withCString too.
                return language.withCString { lang -> Int32 in
                    params.language = lang
                    if let prompt = initialPrompt, !prompt.isEmpty {
                        // initial_prompt must stay alive through whisper_full → nested withCString.
                        return prompt.withCString { c in
                            params.initial_prompt = c
                            return api.full(params, buf.baseAddress, Int32(buf.count))
                        }
                    }
                    return api.full(params, buf.baseAddress, Int32(buf.count))
                }
            }
        } }
        let result = experiment.vadModelPath.map { $0.withCString(full) } ?? full(nil)
        if !configuration.noTimestamps {
            guard result == 0, abortBox?.observed != true else {
                return .init(status: result, abortObserved: abortBox?.observed == true)
            }
            return copyTimedResult(sampleCount: samples.count, wordTiming: configuration.wordTiming)
        }
        var segments: [String] = []
        if result == 0 {
            for i in 0..<api.count() {
                if let seg = api.text(i) { segments.append(String(cString: seg)) }
            }
        }
        let evidence = experiment.collectEvidence && result == 0
            ? (0..<min(max(0, api.count()), Int32(RecognitionSegments.maximumCount))).map { segment in
                let tokens = max(0, api.tokenCount(segment))
                let total = (0..<tokens).reduce(Float(0)) { $0 + api.tokenProbability(segment, $1) }
                return WhisperDecodeEvidence.Segment(noSpeechProbability: api.noSpeechProbability(segment), tokens: Int(tokens),
                                                     meanTokenProbability: tokens > 0 ? total / Float(tokens) : 0)
            } : nil
        return WhisperNativeDecode(status: result, segments: segments, abortObserved: abortBox?.observed == true, evidence: evidence)
    }

    private func copyTimedResult(sampleCount: Int, wordTiming: Bool) -> WhisperNativeDecode {
        let count = api.count()
        guard count >= 0, count <= RecognitionSegments.maximumCount else { return .init(status: 0) }
        var cues: [RecognitionSegments.Cue] = []
        cues.reserveCapacity(Int(count))
        var total = 0
        for index in 0..<count {
            guard let pointer = api.text(index) else { return .init(status: 0) }
            let remaining = RecognitionSegments.maximumNativeBytes - total
            var length = 0
            // The public C string must terminate within the remaining byte
            // budget. Never strlen/String(cString:) before enforcing this cap.
            while length <= remaining, pointer[length] != 0 { length += 1 }
            guard length <= remaining,
                  let text = String(bytes: UnsafeRawBufferPointer(start: pointer, count: length), encoding: .utf8) else { return .init(status: 0) }
            let size = total.addingReportingOverflow(length)
            guard !size.overflow, size.partialValue <= RecognitionSegments.maximumNativeBytes else { return .init(status: 0) }
            total = size.partialValue
            // Same native index, copied before any reuse/free. No prefix salvage.
            cues.append(.init(text: text, start: api.start(index), end: api.end(index)))
        }
        let timing = try? RecognitionSegments(clock: .whisper191PCM10ms, sourceSampleCount: sampleCount, cues: cues)
        // Words never invalidate the qualified segments: any refusal drops only the words.
        let words = wordTiming && timing != nil ? copyWords(segments: count, sampleCount: sampleCount) : nil
        // A timing-only refusal may retain the complete independently bounded raw text.
        return .init(status: 0, segments: cues.map(\.text), timing: timing, words: words)
    }
    private func copyWords(segments: Int32, sampleCount: Int) -> RecognitionWords? {
        var tokens: [RecognitionWords.Token] = [], total = 0
        for segment in 0..<segments {
            let count = api.tokenCount(segment)
            guard count >= 0, tokens.count + Int(count) <= RecognitionWords.maximumCount * 2 else { return nil }
            for index in 0..<count {
                guard let pointer = api.tokenText(segment, index) else { return nil }
                let remaining = RecognitionSegments.maximumNativeBytes - total
                var length = 0
                while length <= remaining, pointer[length] != 0 { length += 1 }
                guard length <= remaining else { return nil }
                total += length
                let data = api.tokenData(segment, index)
                tokens.append(.init(id: data.id, bytes: Array(UnsafeRawBufferPointer(start: pointer, count: length)),
                                    start: data.t0, end: data.t1, segment: Int(segment)))
            }
        }
        return try? RecognitionWords(sourceSampleCount: sampleCount,
                                     words: RecognitionWords.assemble(tokens: tokens, eot: api.eot))
    }
}

/// When the whisper context is freed after going idle. Holding it for the whole
/// process lifetime was free at 148 MB and is wrong at 574 MB+: vocalinux #591
/// measured an idle GPU context draining a laptop battery in 1-1.5 h with zero
/// transcription, which is why they shipped `model_keepalive.py`.
public enum ModelUnloadPolicy: Equatable, Sendable {
    case never
    /// Free the context after each transcription. Deliberately *not* reachable
    /// from the idle tick: the watcher runs every 10 s and would otherwise be
    /// free to fire between two passes of one dictation.
    case immediately
    case afterIdle(seconds: TimeInterval)

    public static let `default` = ModelUnloadPolicy.afterIdle(seconds: 300)

    /// The 10 s watcher's decision. Recording always wins — Handy's watcher
    /// touches the activity stamp instead of unloading, so a six-minute
    /// dictation can never be interrupted by its own idle timer.
    public func shouldUnloadOnTick(idle: TimeInterval, recording: Bool) -> Bool {
        guard !recording else { return false }
        switch self {
        case .never, .immediately: return false
        case .afterIdle(let seconds): return idle >= seconds
        }
    }

    /// Checked after a transcription completes, where "not recording" is
    /// already established by the caller.
    public var unloadsAfterTranscription: Bool { self == .immediately }
}

/// Reference box so a Swift abort closure survives the trip through whisper's
/// C `void *` user-data pointer.
private final class AbortBox {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var observed: Bool { state.withLock { $0 } }
    func poll() -> Bool {
        let abort = shouldAbort()
        if abort { state.withLock { $0 = true } }
        return abort
    }
    let shouldAbort: () -> Bool
    init(_ shouldAbort: @escaping () -> Bool) { self.shouldAbort = shouldAbort }
}
