import Foundation
import os
import whisper

public struct TranscriberError: Error, CustomStringConvertible {
    public let description: String
}

public final class WhisperTranscriber {
    private let ctx: OpaquePointer
    private let multilingual: Bool
    /// `pinned` is `Settings.language`; `last` is the language the previous
    /// pass was spoken in, which is the next pass's first guess. Locked because
    /// the Hub writes `pinned` on main while a pass reads it off main.
    private let spoken: OSAllocatedUnfairLock<(pinned: String?, last: String)>
    // Default caps at min(4, cores); give the encode more threads, leaving headroom for the UI.
    private static let threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

    /// Where the catalog's default model lives. Kept as the fallback for a
    /// `settings.whisperModelPath` that isn't set — the model *choice* is the
    /// catalog's, not this file's.
    public static func defaultModelPath() -> String {
        ModelCatalog.path(for: ModelCatalog.default)
    }

    /// Every language whisper knows, by name — the Hub's picker.
    public static let languages: [(code: String, name: String)] = (0...whisper_lang_max_id())
        .compactMap { id in
            guard let code = whisper_lang_str(id), let name = whisper_lang_str_full(id) else { return nil }
            return (String(cString: code), String(cString: name).capitalized)
        }
        .sorted { $0.name < $1.name }

    /// `Settings.language`: nil follows the speaker, a code ("en", "hi") is
    /// used for every pass. A change applies from the next pass.
    public var language: String? {
        get { spoken.withLock { $0.pinned } }
        set { spoken.withLock { $0.pinned = newValue } }
    }

    public init(modelPath: String, language: String? = nil) throws {
        // Metal GPU *and* flash attention are already on: v1.9.1's
        // whisper_context_default_params() returns use_gpu=1, flash_attn=1, and the
        // xcframework embeds the compiled Metal library so init no longer hits the old
        // broken resource bundle. Nothing to override — an explicit flash_attn = true
        // here was a no-op carrying a comment that claimed the opposite.
        let params = whisper_context_default_params()
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriberError(description: "failed to load whisper model at \(modelPath)")
        }
        self.ctx = ctx
        multilingual = whisper_is_multilingual(ctx) != 0
        spoken = OSAllocatedUnfairLock(initialState: (pinned: language, last: "en"))
    }

    deinit { whisper_free(ctx) }

    /// Returns nil when the pass did NOT complete — a whisper error, or a
    /// cooperative abort via `shouldAbort`. That is distinct from "", which is a
    /// completed pass that found no speech. The difference matters: the
    /// streaming loop freezes a confirmed prefix and advances its sample cut
    /// from a pass's result, so committing a failure as if it were silence
    /// permanently deletes that span of audio from the transcript.
    ///
    /// A multilingual model told the wrong language doesn't transcribe, it
    /// translates: pinned to English, Hindi speech came out as an English
    /// sentence. Whisper's own answer ("auto") detects first and then decodes,
    /// encoding the audio twice — measured on large-v3-turbo, 1.1 s → 2.2 s on
    /// every pass. This gets the same text for one encode in the usual case:
    /// decode in the language the last pass was spoken in, then ask which
    /// language this one was. Only a pass that switches language decodes
    /// again, and that one is slow — a wrong-language decode is the kind that
    /// retries: 3–6 s measured, against 1.2–1.5 s for a pass that stayed put.
    public func transcribe(_ samples: [Float], initialPrompt: String?, shouldAbort: (() -> Bool)? = nil) -> String? {
        // An English-only model has one language whatever the setting says, and
        // asking it for any other fails the pass.
        guard multilingual else {
            return decode(samples, initialPrompt: initialPrompt, language: "en", shouldAbort: shouldAbort)
        }
        let (pinned, guess) = spoken.withLock { ($0.pinned, $0.last) }
        // An unknown code would fail every pass, so it reads as unset.
        if let pinned, whisper_lang_id(pinned) >= 0 {
            return decode(samples, initialPrompt: initialPrompt, language: pinned, shouldAbort: shouldAbort)
        }
        guard let text = decode(samples, initialPrompt: initialPrompt, language: guess,
                                shouldAbort: shouldAbort) else { return nil }
        // Nothing heard is not asked: silence "detects" as an arbitrary language,
        // and the next real pass would start from that guess.
        guard !text.isEmpty, let actual = spokenLanguage(), actual != guess else { return text }
        spoken.withLock { $0.last = actual }
        return decode(samples, initialPrompt: initialPrompt, language: actual, shouldAbort: shouldAbort)
    }

    /// The language of the audio the last decode() encoded. This is whisper's
    /// own detection — one decoder step from start-of-transcript, then the
    /// likeliest language token — minus the encoder pass it would repeat: the
    /// encoding is language-independent and decode() has just left it in place.
    private func spokenLanguage() -> String? {
        var sot = whisper_token_sot(ctx)
        guard whisper_decode(ctx, &sot, 1, 0, Self.threads) == 0,
              let logits = whisper_get_logits(ctx) else { return nil }
        let best = (0...whisper_lang_max_id()).max {
            logits[Int(whisper_token_lang(ctx, $0))] < logits[Int(whisper_token_lang(ctx, $1))]
        }
        return best.flatMap { whisper_lang_str($0) }.map { String(cString: $0) }
    }

    /// One whisper pass in `language` — a code, or "auto" for whisper's own
    /// detect-then-decode (the reference the tests hold transcribe() to).
    func decode(_ samples: [Float], initialPrompt: String?, language: String,
                shouldAbort: (() -> Bool)? = nil) -> String? {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        // temperature fallback stays ENABLED (default temperature_inc): it's whisper's
        // guardrail against greedy-decode repetition loops ("same sentence × 28") —
        // observed in the wild when this was set to 0. Clean audio still decodes once;
        // only degenerate decodes pay for a retry.
        params.n_threads = Self.threads
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
                return Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().shouldAbort()
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        }

        let result: Int32 = withExtendedLifetime(abortBox) {
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
                            return whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                        }
                    }
                    return whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        guard result == 0 else { return nil }  // non-zero on error or cooperative abort: the pass did NOT complete.

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return Self.stripNonSpeech(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
    let shouldAbort: () -> Bool
    init(_ shouldAbort: @escaping () -> Bool) { self.shouldAbort = shouldAbort }
}
