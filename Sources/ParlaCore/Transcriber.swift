import Foundation
import whisper

public struct TranscriberError: Error, CustomStringConvertible {
    public let description: String
}

public final class WhisperTranscriber {
    private let ctx: OpaquePointer

    /// Where the catalog's default model lives. Kept as the fallback for a
    /// `settings.whisperModelPath` that isn't set — the model *choice* is the
    /// catalog's, not this file's.
    public static func defaultModelPath() -> String {
        ModelCatalog.path(for: ModelCatalog.default)
    }

    public init(modelPath: String) throws {
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
    }

    deinit { whisper_free(ctx) }

    public func transcribe(_ samples: [Float], initialPrompt: String?, shouldAbort: (() -> Bool)? = nil) -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        // temperature fallback stays ENABLED (default temperature_inc): it's whisper's
        // guardrail against greedy-decode repetition loops ("same sentence × 28") —
        // observed in the wild when this was set to 0. Clean audio still decodes once;
        // only degenerate decodes pay for a retry.
        // Default caps at min(4, cores); give the encode more threads, leaving headroom for the UI.
        params.n_threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
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
                // Pin the decode to English instead of inheriting whisper's compiled default
                // (which happens to be "en" today — don't let a model swap decide it). With an
                // unpinned decoder, the English initial_prompt below (dictionary + cross-cut
                // context) drags the decoder into *translating* non-English speech: voxtype #233
                // logged "auto-detected: pt (p=1.00)" and typed English anyway.
                //
                // The other half of that fix — suppress the English prompt when the speaker
                // isn't English — is deliberately absent: whisper only reports the language
                // after the fact (whisper_full_lang_id), and learning it up front costs a whole
                // extra encode (whisper_pcm_to_mel + whisper_lang_auto_detect), more than the
                // prompt is worth. If Parla ever unpins language, do it as a conditional
                // re-decode instead: check whisper_full_lang_id, and only when it isn't English
                // run the pass again promptless — then only non-English speakers pay.
                // language is borrowed for the whisper_full call, so it needs withCString too.
                return "en".withCString { lang -> Int32 in
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
        guard result == 0 else { return "" }  // non-zero on error or cooperative abort.

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
    /// Dropped token by token, not all-or-nothing: whisper mixes a marker into a
    /// real sentence ("Hello there. [BLANK_AUDIO]") and the all-or-nothing form
    /// typed the brackets straight into the user's document. A transcript that is
    /// nothing but markers still becomes "".
    public static func stripNonSpeech(_ text: String) -> String {
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
