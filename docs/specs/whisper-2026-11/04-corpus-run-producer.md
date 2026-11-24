# Lane 04 — Human-corpus saved-run producer (`parla-eval corpus-run`)

Wave 1 · Risk: Medium · Depends on: nothing (benefits from lane 01 once merged)

## Goal

`eval/human-corpus-protocol.md` defines an exact saved-run schema that `corpus-check` validates and
re-scores, but nothing in the repo can produce one. Add the producer for the ASR leg, and make the
existing live eval measure the prompt the app actually ships.

This deliberately supersedes the protocol's "No producer is added" sentence and ROOTPOLICY8A.1's
"No new live run producer in this slice". `corpus-check` itself stays read-only and unchanged.

## Files owned

- `Sources/ParlaCore/EvalCorpusRun.swift` (new)
- `Sources/ParlaCore/EvalCorpus.swift` (only if a member must be reachable from the new file; same
  module, so prefer no edit)
- `Sources/ParlaCore/RecognitionFactory.swift` — **`EvalRecognition` class only**
- `Sources/parla-eval/main.swift`
- `eval/human-corpus-protocol.md`, `eval/README.md`
- `Tests/ParlaCoreTests/EvalCorpusRunTests.swift` (new), `EvalCorpusCLITests.swift`,
  `RecognitionFactoryTests.swift` (only the source-text assertions about `parla-eval`, if they need
  updating)

## Current code (anchors by symbol)

- `parla-eval/main.swift`: the early `if args.contains("corpus-check")` dispatch; `var transcriber: EvalRecognition?`
  acquired with `RecognitionRequest(settings: Settings())` **before** `eval/context.json` is loaded;
  the `Pipeline(transcribe: { samples, prompt in await transcriber?.transcribe(samples, prompt: prompt) }, …)`.
- `EvalRecognition.acquire(needsASR:request:factory:)`, `transcribe(_:prompt:)` (passes
  `initialPrompt: prompt` to the handle), `release()`.
- `EvalCorpus.evaluate`, `EvalCorpus.Manifest`, `EvalCorpus.Case`, `EvalCorpus.Run`, `EvalCorpus.Row`
  (the row rules the producer must satisfy), `EvalCorpusIO` (descriptor-rooted reads, digests).
- `Eval.loadSamples(url:)`, `Pipeline.recognitionSkip(samples:)`.
- `RecognitionFactoryTests` contains assertions on the text of `parla-eval`'s offline branches
  (for example that they never contain `WhisperTranscriber(modelPath:`). Keep them true.

## Design

### A. Live eval measures the shipped prompt (small fix)

- In `parla-eval/main.swift`, load `eval/context.json` before acquiring the engine and build the
  request from settings that carry the fixture dictionary, so `handle.request.dictionary` is the
  eval dictionary.
- `EvalRecognition.transcribe(_:prompt:)` stops forwarding the prompt (`initialPrompt: nil`); the
  handle derives it from its frozen request, the same path iOS already uses. Keep the parameter so
  `Pipeline`'s closure shape is unchanged; document that it is ignored.
- Add `EvalRecognition.recognize(_ samples: [Float]) async -> RecognitionPassResult?` for the
  producer (typed outcome, not just text).

Note in `eval/README.md` that committed `eval/results.json` ASR rows were produced with the old
explicit prompt path. Do not regenerate them in this lane.

### B. `corpus-run`

```
parla-eval corpus-run MANIFEST --out RUN.json --run-id ID --config-revision ID [--whisper-model PATH]
```

- Strict dispatch placed right after `corpus-check`, with the same refusal rules: unknown,
  duplicate or missing flags exit 2. `--out` must not already exist; it is created with
  `O_CREAT | O_EXCL`, mode `0600`, and is the only file written.
- Route is `asr-only` in this lane. Engine entry: `{leg: "asr", id: <catalog id or "custom">,
  revision: <catalog sha256 prefix or "unknown">, configRevision: <--config-revision>, transport: "local"}`.
  IDs must satisfy the schema's ID grammar (1–64 ASCII alphanumerics, hyphen, underscore), so map
  `base.en` → `base-en` and use the first 16 hex characters of the digest.
- Steps:
  1. Admit the manifest with the existing checker (`EvalCorpus.evaluate` on the manifest alone). A
     manifest that `corpus-check` refuses is refused here with the same finite error. Consent must
     cover use `asr` and destination `local`; reuse `Manifest.permission` rather than re-deriving it.
  2. For each case, in manifest order: read the audio through `EvalCorpusIO` (digest must equal the
     manifest's), decode with `Eval.loadSamples`, then:
     - `Pipeline.recognitionSkip` hit → `status: skipped, reason: policy, hypothesis: null, seconds: null`.
       (The schema reserves `silence-gate` for the cleanup leg.)
     - `recognize` → `.completed` → `success`, hypothesis = trimmed text (empty allowed), seconds measured.
     - `.failed(.nativeDecode)` → `failed/decode`; other `.failed` → `failed/engine`; canceled → `failed/cancelled`.
     - unreadable or undecodable audio → `failed/engine` (never drop a row).
     - Every row: `inputOrigin: "audio"`, `inputSHA256` = audio digest, `audioSHA256`,
       `referenceSHA256` and `referenceRevision` copied from the manifest's verbatim reference.
  3. Encode with sorted keys, exactly the schema's fields, no extras. Write once at the end.
  4. Self-verify: run the existing `EvalCorpus.evaluate` with `results:` set to the new file. If it
     refuses, delete the file and exit 3. Print the checker's report on success.
- Exit codes: 0 written and admitted · 2 refused input or arguments · 3 infrastructure. Quality is
  never an exit code here; `corpus-check` reports it.
- The dictionary for a corpus run is empty unless `--context FILE` is given (same shape as
  `eval/context.json`); the operator records what was used in `--config-revision`. One flag, no
  auto-discovery.

### C. Protocol and README

- `eval/human-corpus-protocol.md`: replace the "No producer is added" paragraph with a description
  of `corpus-run`, its single write, and the unchanged limitation that engine/config identity in a
  run file is an attestation by whoever ran it. Mark B02 as still PARTIAL: the producer exists, the
  human corpus does not.
- `eval/README.md`: a short "Human corpus" section (collect → `corpus-check MANIFEST` →
  `corpus-run` → `corpus-check MANIFEST --results RUN [--against OTHER]`), and one paragraph on
  running OpenAI's normalizer **externally** for benchmark-comparable WER: export hypotheses and
  references from a run file and score them with the upstream Python package in a separate
  environment. No script and no native port in this lane.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test |
|---|---|
| Produced run is admitted by the existing checker | `EvalCorpusRunTests`: test-authored `nonhuman-regression` manifest with two tiny WAVs and an injected recognizer closure → `EvalCorpus.evaluate(manifest, results: out)` succeeds |
| Typed outcomes map to schema rows | Same suite: injected outcomes completed / completed-empty / `.failed(.nativeDecode)` / canceled / gate-skip → `success`, `success` with `""`, `failed/decode`, `failed/cancelled`, `skipped/policy` |
| Never overwrites | `--out` pointing at an existing file exits 2 and leaves it byte-identical |
| Strict arguments | `EvalCorpusCLITests`: unknown flag, duplicate flag, missing `--out` → exit 2; `corpus-check` behaviour unchanged |
| Refused manifest is refused, nothing written | Manifest with a digest mismatch → exit 2, no output file |
| Live eval uses the handle-derived prompt | `RecognitionFactoryTests`: `EvalRecognition.transcribe(samples, prompt: "ignored")` reaches a fake client with the prompt derived from `request.dictionary`, not `"ignored"` |

Test data must be test-authored and labelled as such (`provenance: tts` / `synthetic-signal`,
purpose `nonhuman-regression`). Never commit anything that looks like human corpus evidence.

## Checks to run

- `swift test --filter 'EvalCorpusRunTests|EvalCorpusCLITests|EvalCorpusTests|RecognitionFactoryTests|EvalQualityTests'`
- `swift run parla-eval verify` only if the eval executable is already built by the test run;
  otherwise skip and say so (no extra build).

## Out of scope

- `reference-cleanup` and `asr-pipeline` routes (cleanup leg, provider consent, transport rows).
- Any collection tooling, recording UI, retention change or corpus discovery.
- Regenerating `eval/results.json`.
- Porting or vendoring the upstream normalizer.

## Needs a human (no code can stand in for this)

- [ ] Approve scope, custodian, storage, retention and withdrawal route (protocol step 1).
- [ ] Obtain real consent from every audible speaker; keep identities outside the repo (step 2).
- [ ] Predeclare cohorts: Hindi, English, code-switching, technical names, numerals, quiet, noisy,
      several microphones, short and multi-minute takes, no-speech controls (step 3).
- [ ] Record, then have real reviewers write verbatim and cleaned references against the exact
      audio (steps 4–5).
- [ ] Assign whole speakers to development or holdout; author `manifest.json`; run
      `parla-eval corpus-check MANIFEST`.
- [ ] Run `corpus-run` once per model/configuration under comparison; compare with
      `corpus-check MANIFEST --results A --against B`.
- [ ] Keep the corpus and run files out of git unless consent explicitly covers publication.

## Open question

Gate-skipped ASR rows are written as `skipped/policy`. The alternative is `success` with an empty
hypothesis ("what the product would have typed"). The first keeps "model not invoked" visible; the
second scores no-speech controls as correct silence. This spec picks `skipped/policy`.
