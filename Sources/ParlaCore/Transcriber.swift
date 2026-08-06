import Foundation
import whisper

public struct TranscriberError: Error, CustomStringConvertible {
    public let description: String
}

public final class WhisperTranscriber {
    private let ctx: OpaquePointer

    public static func defaultModelPath() -> String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla/models/ggml-base.en.bin").path
    }

    public init(modelPath: String) throws {
        // Metal GPU on by default — the v1.9.1 xcframework embeds the compiled Metal
        // library in the binary, so init no longer hits the old broken resource bundle.
        var params = whisper_context_default_params()
        params.flash_attn = true  // Metal flash attention (xcframework is v1.9.1) — off by default.
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriberError(description: "failed to load whisper model at \(modelPath)")
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Returns nil when the pass did NOT complete — a whisper error, or a
    /// cooperative abort via `shouldAbort`. That is distinct from "", which is a
    /// completed pass that found no speech. The difference matters: the
    /// streaming loop freezes a confirmed prefix and advances its sample cut
    /// from a pass's result, so committing a failure as if it were silence
    /// permanently deletes that span of audio from the transcript.
    public func transcribe(_ samples: [Float], initialPrompt: String?, shouldAbort: (() -> Bool)? = nil) -> String? {
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
    /// "[MUSIC]", "(silence)", "*sigh*", and multi-word forms like
    /// "(upbeat music)" or "[typing sounds]" — which must never be typed or
    /// pasted. A transcript that is nothing BUT such markers becomes "".
    ///
    /// Marker spans are matched whole rather than per space-separated word: the
    /// old per-word test required every token to both open and close, so
    /// "(upbeat music)" tokenized to ["(upbeat", "music)"], neither of which is
    /// a marker, and the whole thing was typed into the user's field.
    /// The stripping is only used to decide emptiness — when real words survive,
    /// the ORIGINAL text is returned untouched, so "Array [0] is empty" is safe.
    public static func stripNonSpeech(_ text: String) -> String {
        let markerSpan = #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#
        let remainder = text
            .replacingOccurrences(of: markerSpan, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? "" : text
    }
}

/// Reference box so a Swift abort closure survives the trip through whisper's
/// C `void *` user-data pointer.
private final class AbortBox {
    let shouldAbort: () -> Bool
    init(_ shouldAbort: @escaping () -> Bool) { self.shouldAbort = shouldAbort }
}
