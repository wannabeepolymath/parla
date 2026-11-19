# Lane 14 — Experimental word timing and readable captions (core only)

Wave 4 · Risk: High · Depends on: lane 12 (same file, `Transcriber.swift`)

## Goal

Add an explicit, separately labelled word-timing result for timed file recognition, and a pure
caption layout function that turns words into readable cues. Core only: no UI in this lane, and the
existing literal segment export stays exactly as it is.

## Recommendation recorded in the README

Word times here are whisper's heuristic token timestamps. They are estimates with no accuracy
evidence yet. Ship the capability behind the existing experimental timed-import mode and hold any
user-facing promise until a person has checked word times against audio (lane 10 clips).

## Why `token_timestamps`, not DTW

- DTW needs `dtw_token_timestamps = true` and a per-model alignment-heads preset in the **context**
  parameters. `WhisperCContext.init` pins `params.dtw_token_timestamps = false`, the context is
  shared with ordinary dictation, and `RecognitionSegments.Clock.whisper191PCM10ms` was qualified
  under that configuration. A second context configuration means new identity, memory and
  qualification work.
- `params.token_timestamps = true` is a per-call flag on the existing context. With `max_len == 0`
  it computes per-token times after decoding and should not change segment text or bounds — which
  this lane must **prove** with a test before relying on it.

## Files owned

- `Sources/ParlaCore/Transcriber.swift`
- `Sources/ParlaCore/RecognitionWords.swift` (new)
- `Sources/ParlaCore/CaptionLayout.swift` (new)
- `Sources/ParlaCore/RecognitionIdentity.swift` (`RecognitionPayload`, `RecognitionPassResult`,
  `RecognitionFinalResult` — one optional field each)
- `Tests/ParlaCoreTests/RecognitionWordsTests.swift`, `CaptionLayoutTests.swift` (new),
  `RecognitionSegmentsTests.swift`, `TranscriberTests.swift`
- `ios/Scripts/parlacore.py` (add `RecognitionWords` to `CORE_SWIFT`: the shared
  `RecognitionIdentity.swift` now references it) and the regenerated `ios/Parla.xcodeproj`
  (`python3 ios/Scripts/generate_project.py`, then `python3 ios/Scripts/validate_project.py`).
  `CaptionLayout.swift` stays desktop-only.

## Current code (anchors by symbol)

- `WhisperCContext.decodeNative`: for timed decodes sets `params.token_timestamps = false`,
  `max_len = 0`, `single_segment = false`, …; `copyTimedResult(sampleCount:)` copies segment text
  and `t0`/`t1` under `RecognitionSegments.maximumCount` / `maximumNativeBytes`.
- `WhisperNativeDecode.timing: RecognitionSegments?`; `RecognitionPayload.segments`;
  `RecognitionPassResult.segments` and `RecognitionFinalResult.segments` (both gate on full-final,
  not canceled, matching sample range).
- `RecognitionSegments` (validated cues, 10 ms ticks) and `SubtitleExport.encoded(_:format:)`.
- C API (exported, checked): `whisper_full_n_tokens`, `whisper_full_get_token_text`,
  `whisper_full_get_token_data` (`id`, `p`, `t0`, `t1`), `whisper_token_eot`.

## Design

1. **Result type** `RecognitionWords` (`Equatable`, `Sendable`), same shape and validation style as
   `RecognitionSegments`:
   - `Word { text: String; start: Int64; end: Int64; segment: Int }`, ticks of 10 ms from PCM zero.
   - `init(sourceSampleCount:words:) throws`: bounds within the source, `end >= start`,
     non-decreasing starts, count ≤ 100 000, total text bytes ≤ `RecognitionSegments.maximumNativeBytes`.
   - Doc comment: heuristic estimates from whisper token timestamps; no accuracy claim; words
     belong to the **raw recognized text**, never to cleaned text.
   - `static func assemble(tokens: [Token], eot: Int32) -> [Word]`, pure: drop tokens with
     `id >= eot` (special and timestamp tokens); a token whose text begins with a space starts a new
     word; other tokens extend the current word; a token that is only punctuation attaches to the
     previous word; a word's start is its first token's `t0`, its end its last token's `t1`; clamp
     `end >= start`. Tokens are bytes: accumulate UTF-8 bytes per word and decode once (a multi-byte
     character can span tokens), dropping a word that does not decode.

2. **Native copy.** `WhisperDecodeConfiguration` gains `wordTiming: Bool` (false by default; only
   the timed initializer can set it). When set, `decodeNative` uses `params.token_timestamps = true`
   and keeps every other timed parameter as today. `API` gains `tokenCount`, `tokenText`,
   `tokenData` closures (lane 12 adds `tokenCount`; reuse it). `copyTimedResult` additionally
   collects tokens under the same byte budget and builds `RecognitionWords`; any refusal drops the
   words and keeps the segments (words never invalidate the qualified segment result).
   `WhisperNativeDecode.words: RecognitionWords?`.

3. **Plumbing.** `RecognitionPayload.words`, and `words` accessors on `RecognitionPassResult` and
   `RecognitionFinalResult` with exactly the same gating as `segments`.
   `WhisperTranscriber.recognizeTimed` gains a `wordTiming: Bool = false` parameter; the protocol
   default stays unsupported. Lane 12's rule stands: a non-default experiment refuses timed decodes.

4. **Caption layout** `CaptionLayout.cues(from: RecognitionWords, maxLineCharacters: 42, maxLines: 2, maxCueTicks: 700, pauseTicks: 60) throws -> RecognitionSegments`:
   - Greedy: add words to the current cue until adding one would exceed
     `maxLineCharacters × maxLines`, the cue would exceed `maxCueTicks`, or the gap to the next word
     is ≥ `pauseTicks`. Prefer breaking after sentence-final punctuation when one occurred in the
     last third of the cue.
   - Line wrap inside a cue with `"\n"` at the word boundary nearest the midpoint when the text
     exceeds `maxLineCharacters`.
   - Character counts are grapheme counts. A single word longer than a line stays whole.
   - Returns a `RecognitionSegments` (its initializer re-validates bounds and order), so
     `SubtitleExport.encoded` works unchanged. No karaoke markup.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test |
|---|---|
| Token → word assembly | `RecognitionWordsTests`: `" Hello"`, `","`, `" wor"`, `"ld"`, `"."`, a timestamp token and EOT → `["Hello,", "world."]` with the right ticks |
| Multi-byte characters across tokens | A Devanagari word split mid-character across two tokens decodes as one word |
| Validation refuses bad timing | Out-of-bounds end, decreasing start → throws |
| Word timing is opt-in | Fake `API.full` capture: default timed decode has `token_timestamps == false`; with `wordTiming` it is true and `max_len == 0` |
| Words never break segments | Fake API returning an invalid token time → `timing` present, `words == nil` |
| **Segments are unchanged by word timing** | Model-gated (skip without the default model): the same clip decoded timed with and without `wordTiming` yields identical cue texts, starts and ends |
| Caption wrapping | `CaptionLayoutTests`: 30 synthetic words → every line ≤ 42 graphemes, ≤ 2 lines, cues ≤ 7 s, a 0.8 s gap forces a new cue |
| Layout output is exportable | The layout result round-trips through `SubtitleExport.encoded(.webVTT)` |

If the model-gated equality test fails, stop: the per-call flag perturbs the qualified segment
result, and this lane must not ship on the shared path. Report it instead of working around it.

## Checks to run

- `swift test --filter 'RecognitionWordsTests|CaptionLayoutTests|RecognitionSegmentsTests|SubtitleExportTests|TranscriberTests|AudioImportTests'`
- `python3 ios/Scripts/typecheck.py` and `python3 ios/Scripts/validate_project.py`
- Final: `swift test` once.

## Out of scope

- DTW alignment, alignment-head presets, a second context configuration.
- Any UI, playback, click-to-seek or highlight. Word timing for dictation, streaming, compressed
  sources or cleaned text. Android, iOS product use, Linux.

## Needs a human

- [ ] On 3–5 real clips, compare word start times with the audio in an editor; record typical and
      worst error. This decides whether lane 16 exposes readable captions.
- [ ] Run the model-gated equality test locally with the default model installed.
