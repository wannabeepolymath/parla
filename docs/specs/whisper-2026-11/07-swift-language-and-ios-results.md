# Lane 07 — Model-scoped language hint, model-derived language range, iOS typed results

Wave 2 · Risk: Medium · Depends on: lane 01 (same file, `Transcriber.swift`)

Three small behaviours that share two files. Keep them as three commits.

## Files owned

- `Sources/ParlaCore/Transcriber.swift`
- `Sources/ParlaCore/RecognitionFactory.swift`
- `Sources/Parla/main.swift` (one argument in the `recognitionFactory` initializer)
- `ios/Sources/App/DictationEngine.swift`, `ios/Sources/App/DictationCoordinator.swift`
- `ios/Tests/ParlaTests.swift`
- `Tests/ParlaCoreTests/TranscriberTests.swift`, `RecognitionFactoryTests.swift`

## A. Model-scoped language hint (in memory)

### Current code

- `WhisperTranscriber.init(modelPath:language:native:)` seeds `spoken` with `last: "en"`;
  `recognizeNative` decodes with `guess = spoken.last`, probes with `native.spokenLanguage()`, and
  re-decodes when the guess was wrong.
- iOS `DictationEngine.localRecognizer` acquires a fresh handle per dictation ("no idle resident
  model"), so a Hindi speaker pays the wrong-guess decode on every dictation.
- macOS has the same reset whenever the resident is rebuilt (`ModelUnloadPolicy.afterIdle(300)`).
- `RecognitionFactory.acquire` is the only production construction site of `WhisperTranscriber`.
- Android already keeps `lastLanguage` keyed by `lastModel` in `bridge.cpp`. Nothing to do there.

### Design

- `public final class WhisperLanguageHints` in `Transcriber.swift`: an
  `OSAllocatedUnfairLock<[String: String]>` with `func last(for model: String) -> String?` and
  `func record(_ language: String, for model: String)`. Memory only. No disk, no `static shared`
  (a process-wide default would leak guesses between unrelated tests that share fake model paths).
- `WhisperTranscriber.init(modelPath:language:native:hints: WhisperLanguageHints? = nil)`: seed
  `last` from `hints?.last(for: modelPath) ?? "en"`; store `hints` and the key. Where
  `recognizeNative` does `spoken.withLock { $0.last = actual }`, also `hints?.record(actual, for:)`.
- `RecognitionFactory` gains `public var languageHints: WhisperLanguageHints?` (init parameter,
  default `nil`) and passes it at the `WhisperTranscriber(...)` construction.
- iOS: `static let factory = RecognitionFactory(..., languageHints: WhisperLanguageHints())`.
- macOS: the `lazy var recognitionFactory` initializer in `main.swift` passes one app-lifetime
  `WhisperLanguageHints()`. Check that `recognitionFactory(for:)` derives from that property so
  per-request factories share the same instance; if it builds a fresh factory, hand it the same
  instance.
- The key is the model path. A hint is only a first guess; a stale one costs one retry, exactly
  like today's `"en"`.

### Acceptance

| Behaviour | Test |
|---|---|
| A second transcriber for the same model starts at the detected language | `RecognitionFactoryTests`: fake native detects `"hi"`; first handle decodes `en` then `hi`; a second, non-resident handle from the same factory decodes `hi` first and does not retry |
| Different model path → English again | Same test, other path → first decode `en` |
| No hints → unchanged | Existing tests pass with the default `nil` |
| Pinned language never writes a hint | Pinned `"es"` leaves `last(for:)` nil |

## B. Model-derived language range

### Current code

- `WhisperCContext.init`: `knowsLanguage: { whisper_lang_id($0) >= 0 }`.
- `WhisperCContext.detectedLanguage(_:)` scans `0...whisper_lang_max_id()` and indexes logits at
  `whisper_token_lang(ctx, id)`. On a 51865-token multilingual vocabulary, id 99 (`yue`) is the
  translate token.
- `WhisperCContext.languages` (static picker list) uses the global registry.

### Design

- `static func languageCount(sot: Int32, translate: Int32) -> Int32 { max(0, translate - sot - 1) }`.
- In `init`, `let languages = Self.languageCount(sot: whisper_token_sot(ctx), translate: whisper_token_translate(ctx))`.
  - `knowsLanguage: { let id = whisper_lang_id($0); return id >= 0 && id < languages }`
  - `spokenLanguage: { Self.detectedLanguage(ctx, languages: languages) }`, scanning
    `0..<min(languages, whisper_lang_max_id() + 1)`; return nil when the range is empty.
- English-only models never reach either path (`native.multilingual` is checked first); do not
  special-case them.
- A pinned language the model lacks falls through to auto, which is the existing policy for any
  unknown code (`recognizeTimed` already refuses with `.unsupportedCapability`). The static picker
  list is unchanged — see the README's drop table.

### Acceptance

| Behaviour | Test |
|---|---|
| Arithmetic for both layouts | `TranscriberTests`: `languageCount(sot: 50258, translate: 50358) == 99`, `(50258, 50359) == 100` |
| Shipped multilingual model keeps Cantonese | Model-gated (skip without `large-v3-turbo-q5_0`): `knowsLanguage("yue")` is true |
| Existing auto-detect parity | `testMultilingualModelFollowsTheSpeakerLikeWhisperAutoDetect` still passes where it can run |

## C. iOS typed-result preservation

### Current code

- `DictationEngine.Transcribe = ([Float], String?) async -> String?`.
- `localRecognizer` returns `{ samples, _ in await handle.recognize(samples, pass: .fullFinal, …).text }`.
- `recognize(_:pipeline:acquire:)` sets `pipeline.transcribe`, calls `pipeline.transcript`, and maps
  every nil to "Speech recognition returned no text. Retry from History." A native decode failure,
  an unavailable model and genuine silence are indistinguishable.
- Caller: `DictationCoordinator.process`. Tests: two call sites in `ios/Tests/ParlaTests.swift`.

### Design

- `typealias Transcribe = ([Float]) async -> RecognitionPassResult`.
- `localRecognizer` returns the pass result itself.
- `recognize(_ samples:, acquire:)` (drop the unused `pipeline` parameter; the handle already
  derives the prompt from its frozen request):
  1. Keep the existing `Pipeline.recognitionSkip` refusals.
  2. `let result = await (try await acquire())(samples)`; `try Task.checkCancellation()`.
  3. `result.canceled` or `.canceled` → `throw CancellationError()`.
  4. `.completed` → `Pipeline.transcriptProjection(text)`; nil → "No speech was recognized in that
     recording."
  5. `.failed(reason)` → one message per group:
     - `.nativeDecode`, `.deadline`, `.appleSpeech`, `.parakeet` → "Speech recognition failed on
       this recording. Retry from History."
     - `.clientUnavailable`, `.preparationUnavailable`, `.unsupportedCapability` → "The speech model
       isn't ready. Open Models, then retry from History."
- Update the `DictationCoordinator.process` call and the two tests.

### Acceptance

| Behaviour | Test (`ios/Tests/ParlaTests.swift`) |
|---|---|
| Empty completion → "no speech" message | Injected `.completed("")` |
| Native failure → failure message, not "no speech" | Injected `.failed(.nativeDecode)` |
| Cancellation is not an error message | Injected canceled result → `CancellationError` |
| Gate still runs before acquisition | Existing test (silence never calls `acquire`) |

## Checks to run

- `swift test --filter 'TranscriberTests|RecognitionFactoryTests|AsyncRecognitionTests|RecognitionPreparationTests|RecognitionSegmentsTests'`
- `python3 ios/Scripts/typecheck.py`
- Final: `swift test` once (many suites build fake natives through the factory).

iOS unit tests need a simulator run; do not start one. `typecheck.py`'s `test-sources` job
type-checks them. Report that they were type-checked, not executed.

## Out of scope

- Persisting the hint. Changing the decode-then-probe policy. Android (lane 08). Linux.
- A model-aware language picker. Changing `Pipeline`.

## Needs a human

- [ ] iPhone: two consecutive Hindi dictations on the multilingual model; the second should finish
      noticeably faster than the first.
- [ ] Run the iOS test target in Xcode or on a simulator.
- [ ] If an older multilingual ggml model (51865 vocabulary, e.g. `medium` or `large-v2`) is
      available as a custom model, confirm `knowsLanguage("yue")` is false and auto-detect works.
