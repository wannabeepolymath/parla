# Lane 12 — Internal experiment switches and native evidence in `parla-eval`

Wave 3 · Risk: Medium · Depends on: lane 04 (`parla-eval`, `EvalRecognition`), lane 07 (`Transcriber.swift`)

## Goal

Make decoder-policy questions answerable with evidence instead of opinion: non-speech-token
suppression, carried initial prompt, beam search, native VAD, a different model file. Every switch
is internal to the eval process. No product default changes and no setting is added to the apps.

## Files owned

- `Sources/ParlaCore/Transcriber.swift`
- `Sources/ParlaCore/RecognitionFactory.swift` — `EvalRecognition` only
- `Sources/parla-eval/main.swift`
- `eval/README.md`, `eval/experiments.md` (new)
- `Tests/ParlaCoreTests/TranscriberTests.swift`, `RecognitionFactoryTests.swift`

## Current code (anchors by symbol)

- `WhisperDecodeConfiguration`: fixed `let`s (greedy, native temperature fallback, full audio
  context). `WhisperTranscriber.decodeOutcome` constructs it per decode.
- `WhisperCContext.decodeNative`: sets `params.vad = false` with the comment "Every full call on
  this context has VAD disabled; no other entry can populate a VAD map" — the timed path's
  `whisper191PCM10ms` clock relies on that.
- `WhisperNativeDecode { status, segments, abortObserved, timing }`: no decoder-quality data.
- `WhisperCContext.API`: closures over the C API (`full`, `count`, `text`, `start`, `end`).
- `WhisperTranscriber.recognizeNative`: the guess-then-probe-then-retry language policy.
- `parla-eval/main.swift`: `takeOption`, the live run loop, `CaseResult`, `corpus-run` (lane 04).
- The xcframework exports `whisper_full_get_segment_no_speech_prob`, `whisper_full_n_tokens`,
  `whisper_full_get_token_p`, `whisper_vad_default_params`; `whisper_full_params` has
  `suppress_nst`, `carry_initial_prompt`, `vad`, `vad_model_path` (all checked in the 1.9.1 header
  and binary).

## Design

1. **Switches** in `Transcriber.swift`:

   ```swift
   public struct WhisperExperiment: Equatable, Sendable {
       public var suppressNonSpeechTokens = false
       public var carryInitialPrompt = false
       public var beamSize: Int32? = nil          // nil = greedy (shipping)
       public var vadModelPath: String? = nil     // nil = no VAD (shipping)
       public var collectEvidence = false
       public init() {}
   }
   ```

   - `WhisperDecodeConfiguration` gains `public let experiment: WhisperExperiment` (default `.init()`).
   - `WhisperTranscriber` gains `public var experiment = WhisperExperiment()` (lock-protected like
     `spoken`), passed into each `WhisperDecodeConfiguration` it builds.
   - `decodeNative` applies them: `suppress_nst`, `carry_initial_prompt`; beam →
     `whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)` with `beam_search.beam_size`; VAD →
     `params.vad = true` and `vad_model_path` kept alive across the call like the prompt C string.
   - **Timed decodes refuse any experiment**: `decodeTimed` returns `nil` unless
     `configuration.experiment == .init()`. VAD in particular rewrites timestamps, and a context
     that has run VAD is never used for a timed decode. Update the VAD comment to say exactly that.
   - Temperature fallback and full audio context stay on in every experiment.

2. **Evidence** (only when `collectEvidence`):
   - `API` gains `noSpeechProbability: (Int32) -> Float`, `tokenCount: (Int32) -> Int32`,
     `tokenProbability: (Int32, Int32) -> Float`, defaulted for existing fakes.
   - `public struct WhisperDecodeEvidence: Equatable, Sendable, Codable { segments: [Segment]; languageRetry: Bool; requestedLanguage: String; detectedLanguage: String? }`
     with `Segment { noSpeechProbability: Float; tokens: Int; meanTokenProbability: Float }`.
   - `WhisperTranscriber.lastEvidence` (lock-protected) is set at the end of `recognizeNative`.
     Read-after-call by the sequential eval loop. Deliberately **not** threaded through
     `RecognitionPayload` / `RecognitionPassResult` and not added to `Diagnostics`: product
     diagnostics keep their privacy boundary, and no production type grows.
   - Bound the copy: at most `RecognitionSegments.maximumCount` segments.
   - Doc comment: token probabilities are raw decoder probabilities, not calibrated accuracy, and
     not OpenAI's `avg_logprob` or compression ratio.

3. **`EvalRecognition`**: `func configure(_ experiment: WhisperExperiment)` (casts the handle's
   client to `WhisperTranscriber`; no-op for other engines) and `var lastEvidence: WhisperDecodeEvidence?`.

4. **`parla-eval` flags** (live modes and `corpus-run`):
   - `--experiment LIST` — comma-separated: `suppress-nst`, `carry-prompt`, `beam=N` (2…8),
     `vad=PATH`. Unknown token → exit 2. A `vad` path that does not exist → exit 2.
   - `--whisper-model PATH` — recognition model file for this run (sets `settings.whisperModelPath`
     for the request only; `settings.json` is never written). Lane 04 already defines it for
     `corpus-run`; make the legacy live modes honour it too.
   - `--language CODE` — pins the request language for this run.
   - `--evidence-out FILE` — implies `collectEvidence`; writes one JSON line per ASR case:
     `{name, audioSeconds, decodeSeconds, model, experiment, evidence}`. Must not already exist.
     No transcript text in this file.
   - The `engine` label on ASR `CaseResult`s (and `corpus-run`'s `configRevision`, which the
     operator supplies) must make the experiment visible: append a short suffix such as
     `ggml-base.en.bin+suppress-nst` to the legacy label.
   - With no experiment flags, output is byte-identical to before this lane.

5. **`eval/experiments.md`**: the experiment matrix and how to read it.
   - For each switch: the question, the command pair (baseline vs variant, each with `--out` and
     `--evidence-out`), what to compare (`parla-eval compare a b`, no-speech hallucination counts,
     per-case regressions, decode seconds), and what would justify shipping it.
   - `suppress-nst`: must include cases with code symbols, brackets, URLs and literal punctuation —
     upstream's suppression list contains symbols dictation needs.
   - `carry-prompt`: only meaningful on clips longer than 30 s with dictionary terms after the first
     window (the dictionary conditions only the first window today).
   - `vad`: experiment only. Never for timed output. Record the VAD model file and its sha256 in the
     run notes.
   - Model choice: any local ggml file via `--whisper-model`; no catalog change.
   - State plainly that synthetic `syn-*` cases cannot settle any of these; they need the human
     corpus (lane 04) and the smoke clips (lane 10).

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test |
|---|---|
| Switches reach the C params | `TranscriberTests` with a fake `API.full` capturing `whisper_full_params`: `suppress_nst`, `carry_initial_prompt`, strategy and beam size, `vad` + non-nil model path are set as configured |
| Defaults are untouched | Same seam: default experiment → greedy, `suppress_nst == false`, `carry_initial_prompt == false`, `vad == false` |
| Timed decode refuses experiments | `decodeTimed` with any non-default experiment returns `nil` |
| Evidence is collected and bounded | Fake API with 3 segments → 3 evidence segments with the injected probabilities; `collectEvidence == false` → `lastEvidence == nil` |
| Language retry is recorded | Fake native that detects `hi` after an `en` guess → `languageRetry == true` |
| Flag parsing is strict | `RecognitionFactoryTests` or a small pure parser test: `suppress-nst,beam=5` parses; `beam=99`, `foo` are refused |

## Checks to run

- `swift test --filter 'TranscriberTests|RecognitionFactoryTests|RecognitionSegmentsTests|AsyncRecognitionTests'`
- `python3 ios/Scripts/typecheck.py` (shared file)
- Final: `swift test` once.

## Out of scope

- Any app setting, Hub control or default change. Android, iOS and Linux switches (whisper-rs 0.16
  has no `carry_initial_prompt` setter).
- Streaming-boundary and language-policy experiments (the harness can host them later).
- Downloading or pinning a VAD model. Mobile residency measurements.
- Running the experiments and drawing conclusions.

## Needs a human

- [ ] Obtain the whisper.cpp VAD model file from the upstream project, record its sha256, keep it
      outside the repo.
- [ ] Run the matrix in `eval/experiments.md` on the human corpus (lane 04) and smoke clips
      (lane 10); file the `compare` output and evidence files with the run notes.
- [ ] Decide from that evidence whether any switch becomes a product default — a separate change.
