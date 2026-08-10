# Correctness & Evaluation

How 24 open-source dictation apps prove (or fail to prove) that they work: test suites, golden files, WER harnesses, latency instrumentation, CI. Plus a complete catalogue of every hallucination/garbage guard found in the corpus — the `[BLANK_AUDIO]` family, repetition-loop detectors, silence gates, confidence thresholds, VAD gating — measured against what Parla has today. Ends with a concrete design for the eval suite Parla should ship and exactly what to add to `Sources/ParlaCore/` and `Sources/parla-eval/`.

---

## 1. The headline: almost nobody measures transcription quality

Of 24 audited repos, **exactly one** has a real WER harness.

| Repo | Quality harness | What it measures |
|---|---|---|
| **moona3k/macparakeet** | `benchmarks/asr/` | WER (space-delimited langs) / CER (ko·ja·zh), p90, failure rate, RTFx, paired bootstrap CIs |
| watzon/pindrop | `PindropTests/DiarizationQualityIntegrationTests.swift` | **DER only** — diarization, not transcription |
| cjpais/Handy | `handy --transcribe-file --repeat N --json` | **Speed only** — `{audio_secs, load_ms, transcribe_ms[], best_ms, rtf}`. Handy's own audit: *"No WER measurement anywhere."* |
| TypeWhisper/typewhisper-mac | `scripts/meeting-diarization-eval.js` | Fixture diff via `isDeepStrictEqual` — diarization structure |
| **Parla** | `Sources/parla-eval/main.swift` | Zero-edit rate (exact match) + asr/llm p50/p95 — **2 cases** |
| Beingpax/VoiceInk | `SessionMetric` (SwiftData) | Production telemetry: `speedFactor = audioDuration/transcriptionDuration`. No accuracy. |
| everyone else (18) | — | none |

The rest of the field has *zero* automated protection against transcription-quality regressions. Representative admissions from the corpus:

- **altic-dev/FluidVoice** ships one audio E2E (`testDictationEndToEnd_whisperTiny_transcribesFixture`) whose assertion literally accepts a wrong word — `XCTAssertTrue(normalized.contains("voice") || normalized.contains("fluidvoice") || normalized.contains("boys"))` — and CI **skips it**: `# Tiny Whisper GGUF output is nondeterministic on hosted macOS runners.`
- **Kieirra/murmure** advertises `"eval:dictionary": "cargo test --release dictionary_eval -- --ignored"` in `package.json`, and cites an eval corpus in a source comment calibrating `POSTCORR_CONF_THRESHOLD = 0.45`. **Neither the test nor the `eval/` directory exists in the repo.**
- **moinulmoin/voicetypr**: 1,431 Rust tests, zero measure output text quality. Its own `plans/028` doc concedes the WER numbers in the README are *"quoted from public leaderboards, not produced by this repo."*
- **peteonrails/voxtype**: 952 tests, one integration test file (VAD), `rg -i 'wer|golden|benchmark'` returns nothing.

**Parla is already in the top 5 for having any golden-file harness at all.** It is also 2 cases against its own README's stated target of ~50 (`eval/README.md:44`).

### macparakeet's harness is the one to copy

From `benchmarks/asr/README.md`, the design rules that make it trustworthy:

- **One canonical normalizer for every engine** — Whisper's `EnglishTextNormalizer` for English, `BasicTextNormalizer` for ko/ja/zh, applied identically to reference *and* hypothesis. Curly apostrophes folded to straight **first**, with a regression test in `test_scorers.py` proving that alone moves WER.
- **WER for space-delimited languages, CER for ko/ja/zh** — "Korean spacing is inconsistent, word-WER there is segmentation noise."
- **Paired bootstrap, not CI overlap**: `paired_delta.py` resamples the per-utterance *delta*; "a difference is significant only if its paired CI excludes 0… overlap is over-conservative and under-detects real gaps." 2000 resamples, seed 1234. They then document a case where marginal-CI overlap would have mislabelled a real win as a tie.
- **Reports p90 and failure rate (WER > 20%), not just corpus WER** — corpus WER hides the dictations that actually annoy people.
- **`run_all.sh verify` re-scores committed JSONL fixtures without downloading models** — a repo-only regression gate that runs in seconds.
- Runners drive `macparakeet-cli transcribe` — **the real shipping path**, not a bench-only code path.

That last two bullets are the highest-value steal in this entire document. Parla's harness already drives the shipping path (`WhisperTranscriber` + `makeCleanupClient`, `Sources/parla-eval/main.swift:54-63`); it lacks the offline re-score.

---

## 2. Hallucination & garbage guards — complete catalogue

Whisper emits `[BLANK_AUDIO]`, `[MUSIC]`, "Thank you.", "Thanks for watching!", and n-gram loops on silence and near-silence. Here is every defense found in the corpus, by layer.

### 2a. Marker / phrase filters

| Repo | File | Mechanism |
|---|---|---|
| **OpenWhispr/openwhispr** | `src/data/hallucination-phrases.ts` | **7,422 phrases** from `huggingface.co/datasets/sachaarbonel/whisper-hallucinations`, NFC+lowercase normalized `Set` |
| **VocaHQ/vocalinux** | `recognition_manager.py:751` `_filter_non_speech` | 9 regexes: `^\[BLANK_AUDIO\]$`, `^\[.*\]$`, pure-punctuation, `^[♪♫♬♩♭♮♯]+$`, `^[「」『』]+$`, `^[<>]+$`, `^[-]{2,}$`, `^\.{2,}$`, whitespace-only — **plus a density heuristic: drop if alnum + `.,!?-'"` < 30% of characters** |
| **goodroot/hyprwhspr** | `lib/main.py:23` | 12-marker set: `blank audio, blank, silence, no speech, you, thank you, thanks for watching, thank you for watching, video playback, music, music playing, keyboard clicking` + `text.startswith('♪')` |
| **zachlatta/freeflow** | `Sources/Fluid/…/TranscriptionService.swift:308` | 10 phrases incl. `"you"`, `"please subscribe"`, `"subtitles by the amara.org community"` — **gated on `no_speech_prob`** (§2c) |
| **Beingpax/VoiceInk** | `TranscriptionOutputFilter` | Strips `<TAG>…</TAG>`, then **all** `\[.*?\]`, `\(.*?\)`, `\{.*?\}` — over-broad, eats legitimate parentheticals |
| matthartman/ghost-pepper | `SpeechTranscriber.artifacts` | 7 literals: `[BLANK_AUDIO]`, `[NO_SPEECH]`, `(blank audio)`, `(no speech)`, `[MUSIC]`, `[APPLAUSE]`, `[LAUGHTER]` |
| Starmel/OpenSuperWhisper | `WhisperEngine.transcribeAudio` | `[MUSIC]` + `[BLANK_AUDIO]` string replace |
| digimata/parrot | `Transcription/WhisperKitTranscriber.swift:40-53` | 4 regexes: `\[[^\]]*\]`, `\([^)]*\)`, `<\|[^\|]*\|>`, `\*[^*]*\*` |
| Muesli-HQ/muesli | `AppCoordinator.isTranscriptionEffectivelyEmpty` | **One** case-insensitive compare against `"[BLANK AUDIO]"` |
| voquill/voquill | — | `[BLANK AUDIO]` string check only |
| Open-Less/openless | `d31bf5b` | `is_placeholder_heading` — GLM-ASR returns literal `#`/`##`/`###` on silence |
| **Parla** | `Sources/ParlaCore/Transcriber.swift:84-91` | Bracket/paren/asterisk markers — **all-or-nothing**: only a transcript that is *entirely* markers becomes `""` |
| FluidVoice, epicenter, ququ | — | **none** — `rg -i 'BLANK_AUDIO\|hallucinat'` returns zero hits |

**Parla's specific hole**: `stripNonSpeech` returns the input unchanged if *any* word is real. `"Hello there. [BLANK_AUDIO]"` is typed into the user's document verbatim. It also splits on `" "` only, so a newline-separated marker isn't seen as its own word. Everyone except Parla and vibe uses per-token replacement, not all-or-nothing.

### 2b. Repetition-loop detection

Only **2 of 24** detect degenerate repetition in text.

| Repo | Mechanism |
|---|---|
| **cjpais/Handy** | `audio_toolkit/text.rs::collapse_stutters` — 3+ consecutive identical alphabetic words → one. Test: `"Check data doc doc doc doc documentation." → "Check data doc documentation."` Originally capped at 1–2-letter words; PR #976 lifted the cap after Parakeet v3 emitted long-word loops. |
| **altic-dev/FluidVoice** | `hasRepeatedAdjacentPhrase` (any 2–5-word phrase repeated back-to-back), `hasRepeatedWordTail` (≥5-char suffix of a ≥12-char word already present earlier — catches `transcriptioncription`), `hasSuspiciousAdjacentPunctuation` (`.,` `,.` `..`) |
| peteonrails/voxtype | `is_degenerate_transcript` — empty **or contains no alphanumeric character**. Catches punctuation soup, not loops. On trip, re-runs with `BeamSearch{beam_size:5}`; if still degenerate, returns `""`. |
| **Parla** | none — delegated entirely to whisper's temperature fallback |

### 2c. Confidence gating (`no_speech_prob`)

**2 of 24.** This is the most under-used signal in the entire field.

- **OpenWhispr/openwhispr**, `src/pipeline/utils/segment-filter.ts`: drop if `noSpeechProb > 0.8`; drop at the lower threshold `> 0.4` **only if** the segment text is in the 7,422-phrase hallucination set. Two thresholds, one strict and one phrase-gated.
- **zachlatta/freeflow**, `TranscriptionService.swift:329`: phrase-list match **AND** `segments[0].no_speech_prob >= 0.1`. Comment: *"Thresholds tuned on ~500 samples from quiet and noisy environments, including both positive cases (real 'thank you' speech) and empty-audio cases. Kept conservative to minimize false positives."* Falls **open** (no filtering) when the provider omits `segments`/`no_speech_prob` — that graceful degradation is what let them switch response formats without breaking anything.
- **thewh1teagle/vibe**: sona *computes* `no_speech_prob`, serializes it into the ndjson `segment` event — and Vibe's `SonaEvent::Segment` enum doesn't declare the field, **so serde silently drops it**. Free signal thrown on the floor.
- **Parla**: `whisper_full_get_segment_no_speech_prob` is never called. Confirmed in the Parla audit: *"available and ignored — no low-confidence suppression."*

⚠️ **Caveat before building on this**: openwhispr ships `packages/whisper-wrapper/patches/fix-no-speech-prob-sot-position.patch`, which changes whisper.cpp to read logits at the SOT index rather than the last position, matching OpenAI's reference (`decoding.py#L480-L493`). Their own writeup: *"Without this patch, any no-speech-based hallucination filter is built on garbage."* Verify against Parla's vendored v1.9.1 before trusting the value.

### 2d. Silence / minimum-audio gates — threshold comparison

| Repo | Duration floor | Energy floor |
|---|---|---|
| **Parla** (`TextRules.swift:45-48`) | 6400 samples ≈ **0.4 s** | **RMS ≥ 1e-4** |
| OpenWhispr (`localSpeechGate.js`) | `MIN_AUDIO_BYTES = 256` | `SILENCE_RMS 0.002`, `SPEECH_WINDOW_RMS 0.003`, `SPEECH_WINDOW_PEAK 0.02`, `STRONG_SPEECH_RMS 0.006` |
| goodroot/hyprwhspr (`silence_detector.py`) | `MIN_VOICE_DURATION = 300 ms` continuous | `VOICE_RMS_THRESHOLD = 0.005` |
| Muesli-HQ/muesli (`classifyShortSpeech`) | `< 0.04 s` → discard | `< 1.0 s` + peak `< 0.003` → configurable; `≥ 1.0 s` + peak `< 0.006` → discard |
| altic-dev/FluidVoice | ≤ 4 s clips only, **opt-in, default OFF** | `peak < 0.01 && rms < 0.002 && maxFrameRMS < 0.0045` |
| Starmel/OpenSuperWhisper | `minimumRecordingDuration = 1.0 s` | — |
| peteonrails/voxtype | 0.3 s | — |
| voquill/voquill | — | raw level `< 5e-7` for 10 consecutive 100 ms samples, after a 0.5 s grace |

**Parla's RMS floor of `1e-4` is 20× lower than OpenWhispr's silence threshold and 50× lower than hyprwhspr's.** In practice it never trips on anything but digital silence — room tone passes straight through to whisper. The Parla source comment already flags it: `// ponytail: fixed thresholds, no VAD — bump if quiet speech gets dropped.` The corpus says the risk is the opposite direction.

**Second Parla hole**: `audioWorthTranscribing` is called at `main.swift:358`, `main.swift:368` and `main.swift:588` — **never inside `stream()`**. A silent lead-in can seed `confirmed` with a hallucination, which is then frozen at the cut and fed forward as `initial_prompt` context for every subsequent pass.

### 2e. Padding short clips

| Repo | Behavior |
|---|---|
| cjpais/Handy | recordings < 1 s zero-padded to **1.25 s** |
| Muesli-HQ/muesli | pad to **0.75 s** if shorter; else append a **0.3 s** silent tail |
| moona3k/macparakeet | `dictationTrailingSilenceSeconds = 0.5` appended for TDT — *"the TDT decoder can drop a fast final word that lands right on the end of the recording"* — and **explicitly never for Whisper: "trailing silence there can trigger hallucinations"** |
| Parla | none |

macparakeet's asymmetry is the important detail: padding helps transducers, hurts Whisper. Parla is on Whisper, so the correct action is *not* to pad.

### 2f. Dictionary-echo — the guard Parla most specifically needs

**OpenWhispr/openwhispr, `src/utils/dictionaryEchoFilter.js`** is the only implementation in the corpus, and Parla has the exact same exposure.

Whisper seeded with an `initial_prompt` will **continue the prompt** when it decodes near-silence. The user's glossary gets typed into their document instead of their sentence. openwhispr's issue #1454 reports it hitting *"3 to 5 out of every 10 uses"*.

Detection: normalize transcript and prompt, flag an echo when
`(unique transcript words ∩ prompt words) / unique transcript words ≥ 0.9` **AND** `/ prompt words ≥ 0.7`.
On a hit, re-decode **once** with no initial prompt and VAD disabled — real speech returns the true transcript, real silence returns empty. Second echo → report "no audio detected."

Parla feeds the dictionary as `initial_prompt` in **four** places: `Pipeline.swift:23`, `Streaming.swift:48-54` (tail prompt), `main.swift:593` (transform), `parla-eval/main.swift:69`. There is no echo guard anywhere.

### 2g. Decoder parameters — and one genuine disagreement in the field

Parla, `Sources/ParlaCore/Transcriber.swift:36-39`:

```swift
// temperature fallback stays ENABLED (default temperature_inc): it's whisper's
// guardrail against greedy-decode repetition loops ("same sentence × 28") —
// observed in the wild when this was set to 0. Clean audio still decodes once;
// only degenerate decodes pay for a retry.
```

VocaHQ/vocalinux, PR #415, does the exact opposite: `temperature=0.0, temperature_inc=-1.0` — fallback **disabled**, on the theory that *"the retry loop is what generates the loops."*

Both are load-bearing in-repo comments; both claim field observation. This is an empirically resolvable question and neither project resolved it. It is a perfect first entry in a Parla eval A/B.

Everyone converges on the rest: `suppress_blank=true` (Parla inherits it as the v1.9.1 default), `no_speech_thold=0.6` (Parla inherits), `no_context=true` (Parla inherits — macparakeet sets it explicitly as an anti-hallucination measure: *"a hallucination on silence cannot poison the next one"*).

### 2h. LLM-output guards (cleanup leg)

| Repo | Guard |
|---|---|
| **zachlatta/freeflow** | `appearsToHaveExecutedInstruction` — fires when the raw transcript contains an instruction marker (`ask, write, summarize, translate, claude, chatgpt, ai, llm`, …) AND either (a) the output gained an assistant preamble the input lacked (`^\s*(sure\|certainly\|absolutely\|here(?:'s\| is)\|i(?:'d\| would) be happy to\|i can)\b`) or (b) **token overlap dropped below 0.35**. On trip: retry on fallback model, then **paste the raw transcript**. Disabled when translating. |
| **Open-Less/openless** | `GUARD_DIVERGENCE = 0.35` / `GUARD_MIN_TOKENS = 24` — replays the unboosted greedy decode (encoder already computed) and discards the boosted result if normalized token-level Levenshtein exceeds 0.35 |
| **Beingpax/VoiceInk** | `Qwen3PostProcessorOutputCleaner.shouldFallbackToInput` — tiered expansion ratio: `<50 chars` reject if ratio > 4.0 AND output > 80; `<150` reject if > 2.5 AND > 150; else > 2.0 AND > 200. Plus placeholder detection and 5 assistant-marker strings. |
| Kieirra/murmure, VoiceInk | strip `<think>…</think>` / `<thinking>` / `<reasoning>` from reasoning-model output |
| **Parla** | `Pipeline.swift:44-62` degenerate-length ceiling: `2 × transcript.count + 200 + Σ(snippet expansions)`. `main.swift:624` transform ceiling: `max(2000, 6 × selection.count)`. `CleanupSanitizer` strips one wrapping quote pair. |

Parla has the *length* half of freeflow's guard but not the *semantic* half. A cleanup response that answers the dictated question at roughly the same length passes Parla's ceiling and gets typed. Parla's prompt already says `Do not add, summarize, or answer.` (`Cleanup.swift:52`) — the guard is what catches the prompt failing.

### 2i. Summary scoreboard

| Guard | Repos with it | Parla |
|---|---|---|
| Marker/phrase filter | 12 / 24 | ⚠️ all-or-nothing only |
| Repetition-loop detection | 2 / 24 | ❌ |
| `no_speech_prob` gating | 2 / 24 | ❌ |
| Min-duration gate | ~8 / 24 | ✅ 0.4 s |
| Energy/RMS gate | ~6 / 24 | ⚠️ 1e-4, 20–50× too permissive |
| VAD before decode | ~7 / 24 (Silero) | ❌ (framework ships `whisper_vad_*`, unused) |
| Dictionary-echo guard | 1 / 24 | ❌ (4 prompt-injection sites) |
| LLM instruction-execution guard | 2 / 24 | ⚠️ length-only |
| Empty-after-strip short-circuit | most | ✅ |

---

## 3. Latency instrumentation

Six repos ship structured timing. The pattern is identical everywhere and Parla has none of it in-app.

**altic-dev/FluidVoice** is the reference — `DebugLogger.benchmark(marker:message:source:)` stamps `ProcessInfo.processInfo.systemUptime` at 6 decimals across three namespaces (`ASR_BENCH`, `TYPING_BENCH`, `APP_BENCH`). The emitted waterfall: `recording_start`, `first_pcm_wait_begin/end`, `chunk_start/done/skip/fail` (with rtf), `stop_start`, `stop_audio_drained`, `silence_gate`, `stop_ensure_ready`, `final_done` (rtf), `text_ready`, `focus_restore_result`, `worker_start queueDelayMs`, `settle_delay_done`, `insert_return`, `complete totalMs textReadyToCompleteMs`. You can reconstruct hotkey→character latency from one log file.

**EpicenterHQ/epicenter**, `src-tauri/src/timing.rs` (70 lines) — env-gated by `WHISPERING_TIMING` into a `OnceLock<bool>`; when unset every helper is a branch-and-return (no clock read, no allocation). It shipped **before** the optimizations it measures, and ADR-0016 used it to *refuse* four of five candidate optimizations with numbers:

> Cold recording (Parakeet, Apple Silicon, 4 s clip): **1245 ms**. Warm inference: **~60 ms per second of audio** ⇒ cold model load alone ≈ 1 s. WAV write + fsync + read + decode: **14–79 ms**.

**moinulmoin/voicetypr** emits `transcription_stage_timing stage=<audio_preparation|deterministic|ai_polish> duration_ms=`. **watzon/pindrop** persists a per-dictation `PipelineMetrics` JSON column so latency is queryable from history. **cjpais/Handy** logs `"Transcription completed in {:.2}s for {:.2}s of audio ({:.2}x real-time)"`.

Measured user-facing numbers from the corpus worth having as targets:

| Span | Value | Source |
|---|---|---|
| keypress → first audio buffer, median | **953 ms** (p90 1214, max 1849, n=118) | FluidVoice issue #179 |
| activation → first buffer, built-in mic | 240–270 ms | hyprwhspr `docs/research/instant-dictation-warm-mic-2026-06.md` |
| activation → first buffer, USB mic | 650–700 ms | same |
| whisper.cpp cold model load | ~1 s | epicenter ADR-0016 |
| Parakeet v3 cold start | 0.38 s; whisper-turbo 2.29 s | macparakeet `benchmarks/asr/README.md` |
| fixed plumbing tail before text appears | **~450 ms** (+500 ms blocking clipboard restore) | pindrop `plans/028` |

Parla's `parla-eval` reports `asr` and `llm` p50/p95 (`parla-eval/main.swift:124`) — good stages, wrong spans. Neither is the user-facing number, which for Parla is **fn-up → raw text at cursor** (should be O(tail ≤ 15 s) given shadow streaming) and **raw → cleaned swap**. Parla's README claims *"Release latency is therefore independent of how long you dictated"* — the Parla audit flags this as false (no cut until the tail exceeds 15 s), and nothing measures it.

---

## 4. CI reality

Repos where CI actually runs the test suite: **Handy, openwhispr, typewhisper-mac, amical, muesli, voicetypr, pindrop, macparakeet, voxtype, vocalinux** (10 / 24).

The instructive failures:

- **thewh1teagle/vibe**: `lint_rust.yml`'s `push` trigger is **commented out**, its path filter references a nonexistent `cli/src/**`, and **no workflow invokes `pnpm test`** — the vitest suite never runs.
- **Open-Less/openless**: `ci.yaml` is PR-only, runs `cargo fmt` + `clippy` + three dry-run compiles. **1,194 unit tests are never run in CI.**
- **Kieirra/murmure**: same shape — clippy + lint + compile checks, no `cargo test` for 376 tests.
- **zachlatta/freeflow**: two workflows, **neither runs `make test`**; `package.json` `"test"` is `echo "No tests configured"`.
- **moinulmoin/voicetypr**: macOS CI runs `cargo test`; **Windows runs `cargo test --no-run` (compile-only)** — documented as gotcha #9: *"Windows runtime behavior (hotkeys, Vulkan sidecar) needs manual smoke on a real machine."*
- **moona3k/macparakeet**: full CI including `swift test --parallel` — but `benchmarks/asr/run_all.sh verify`, the offline re-score gate, **is not wired into CI**. Even the best harness in the field is manual.
- **VoiceInk, ghost-pepper, ququ, yap**: no `.github/workflows` at all.

**Parla has no `.github/` directory.** 167 test functions across 16 files in `Tests/ParlaCoreTests/` are enforced by nothing.

macparakeet's compensating discipline is worth naming: `plans/SMOKE.md` indexes ~30 human-executed runbooks and `plans/README.md` carries a `NEEDS-SMOKE` status meaning *"code-frozen and unverified — not permission to re-implement it"*, under the rule **"CI is not runtime proof."**

---

## 5. The eval suite Parla should have

### 5a. Metric definitions

Five numbers, computed per run, all from committed artifacts.

**1. Zero-edit rate** (already implemented, `parla-eval/main.swift:110`). Fraction where `Eval.normalize(actual) == Eval.normalize(golden)`. Keep it — it is the metric that matches the product promise ("zero edits"). Its weakness is that it is binary; add (2) so a near-miss is visible.

**2. WER, per case and corpus-level.** Token-level Levenshtein over a normalized token stream. Report:
- corpus WER = `Σ edits / Σ reference words` (not the mean of per-case WERs — macparakeet reports both and calls the mean "macro-average")
- **p90 per-utterance WER**
- **failure rate = fraction of cases with WER > 20%**

The last two are what macparakeet added specifically because *corpus WER hides the dictations that actually annoy people*.

Normalization must be one function applied identically to reference and hypothesis. Parla's `Eval.normalize` (whitespace-collapse only, `Sources/ParlaCore/Eval.swift:5-7`) is correct for zero-edit but too strict for WER. Add a second `Eval.normalizeForWER` doing: lowercase, fold curly→straight apostrophes **first** (macparakeet's `test_scorers.py` proves this alone moves WER), strip terminal punctuation, collapse whitespace.

**3. Dictionary-term recall.** For every case whose golden contains a term from `settings.dictionary`, did the term survive verbatim (exact case)? Report `hits / occurrences`. This is macparakeet's `benchmarks/asr/custom-vocab-phase0/` design, and it must be paired with a **general-WER regression check** — their explicit reason: prove that boosting a term doesn't damage overall accuracy.

**4. Latency p50/p95 by span.** Parla measures `asr` and `llm`. Add the two user-facing spans:
- `finalize_ms` — fn-up → raw text at cursor (the number the README makes a claim about)
- `swap_ms` — raw landed → cleaned swap complete

For eval-harness purposes only `asr`/`llm`/`total` are reproducible; the other two need in-app instrumentation (§6, item 9).

**5. Guard-trip counts.** Per run: how many cases tripped the silence gate, the marker filter, the repetition detector, the dictionary-echo guard, the cleanup length ceiling. A guard that never fires on the corpus is either unnecessary or the corpus is missing the case it defends against.

**A/B comparison rule**: when comparing two configurations (temperature fallback on/off, `audio_ctx` full vs clipped, base.en vs turbo), use a **paired bootstrap on the per-case WER delta**, not overlapping confidence intervals. macparakeet documents a real case where CI overlap mislabelled a significant win as a tie.

### 5b. Case taxonomy

Parla's `eval/README.md:44-50` already names five categories. The corpus says three more are load-bearing and one is Parla-specific.

| # | Category | Why | Corpus evidence |
|---|---|---|---|
| 1 | **Fillers** — um/uh/like/you know | in `eval/README.md`; Parla's prompt rule at `Cleanup.swift:48` | — |
| 2 | **Self-corrections** — "Tuesday — no, Wednesday" | in README; prompt rule `Cleanup.swift:49` | Every polish prompt in the corpus has an explicit self-correction rule; openless enumerates the trigger phrases |
| 3 | **Jargon / dictionary terms** | in README; drives metric (3) | macparakeet `custom-vocab-phase0`; murmure's whole boost-tree design |
| 4 | **Numbers / times / versions** | in README | openless prompt: "GPT-5.6, not GPT-5" — version truncation is a named failure |
| 5 | **Code terms / identifiers** | in README | voxtype's Terminal + Code prompt profiles exist entirely for this |
| 6 | **Silence & near-silence** → must yield `""` | The single highest-value missing category. Nothing in Parla's corpus exercises the guards in §2. | openwhispr, freeflow, ghost-pepper #166 ("Thank You." randomly appended, still open) |
| 7 | **Instruction-shaped dictation** → must be transcribed, not answered | "what's the capital of France" must come back as text | freeflow `isFaithful` test set; openless's 17-case eval is entirely this; VoiceInk #349 shipped the bug |
| 8 | **Long-form > 15 s** → exercises `StreamWindow` cut + `join` seam | `Streaming.swift:20-22` threshold/cutTarget is completely untested end-to-end | macparakeet #551 (150 s dictation: opening text absent, tail repeated, 3.56 GB RSS) |
| 9 | **Terminal / chat flattening** | `TextRules.flattenForTerminal` is unit-tested but never exercised through real audio | 14 hard-coded bundle IDs, `TextRules.swift:9-19` |
| 10 | **Prompt injection in the transform selection** | `Cleanup.swift:22-24` has the defense and a unit test; no audio-level case | VoiceInk #1261 → PR #1310 shipped exactly this fix |

Minimum viable corpus: **3 cases per category × 10 = 30**, growing to the README's 50. Categories 6–10 are new and are where the bugs are.

Each case gets a category tag so the report can break down per-category — an ASR regression and a cleanup regression are otherwise indistinguishable in the output (voxtype's stated flaw).

### 5c. CI wiring — two tiers

**Tier 1 — every PR, hermetic.** No model download, no API key, no network, no microphone. Runs in seconds.

```
swift test                      # 167 existing tests, currently enforced by nothing
swift run parla-eval --replay   # re-score committed transcripts, no model, no API
```

`--replay` is macparakeet's `run_all.sh verify`. Mechanism: on a full run, `parla-eval` writes `eval/results/<case>.json` containing `{raw, cleaned, asr_ms, llm_ms, model, provider}`. `--replay` reads those files, applies the **current** normalizer + scorers, and reports the same five metrics. A change to `Eval.normalize`, to the WER scorer, to `stripNonSpeech`, or to `TextRules.flattenForTerminal` is caught in CI without a GPU or a key.

**Tier 2 — nightly / manual, full run.** Requires `ggml-base.en.bin` + a cleanup key. Writes fresh `eval/results/*.json` and diffs the five metrics against a committed `eval/baseline.json`. Fails on: any zero-edit regression, corpus-WER regression beyond the paired-bootstrap CI, or a failure-rate increase.

Distinguish **error** from **regression**. Today `parla-eval` sets `anyFailed = true` for a WAV-read failure, a cleanup HTTP 500, *and* a quality mismatch (`main.swift:84-104`) — so flaky network reads as a regression. Split the exit codes: quality mismatch → 1, infrastructure error → 3.

---

## 6. What Parla should do

Ordered by value ÷ effort. Every item names the file.

**1. Add `.github/workflows/ci.yml` running `swift test`. (S)**
There is no `.github/` directory. 167 tests in `Tests/ParlaCoreTests/` are enforced by nothing — the same failure mode as vibe, openless, murmure, and freeflow. One workflow, `macos-latest`, `swift test`. This is the cheapest correctness win available and it gates everything below.

**2. Raise `minRMS` and apply the gate inside `stream()`. (S)**
`Sources/ParlaCore/TextRules.swift:45-48` uses `minRMS = 1e-4` — 20× below OpenWhispr's `SILENCE_RMS = 0.002`, 50× below hyprwhspr's `0.005`. Room tone passes. Raise to ~2e-3 and add an eval case (category 6) that proves quiet-but-real speech still passes. Separately: `audioWorthTranscribing` is called at `main.swift:358/368/588` but **not** inside the `stream()` loop (`main.swift:696-760`), so a silent lead-in can seed `confirmed` with a hallucination that is then frozen at the cut and fed forward as `initial_prompt`. Add the call before the tail pass.

**3. Make `stripNonSpeech` per-token, not all-or-nothing. (S)**
`Sources/ParlaCore/Transcriber.swift:84-91` returns the input unchanged if any word is real, so `"Hello there. [BLANK_AUDIO]"` reaches the user's document. Replace `allSatisfy` with a filter that drops marker tokens and returns `""` if nothing survives. Also split on `CharacterSet.whitespacesAndNewlines`, not `" "`. Keep the existing test `"Array [0] is empty"` surviving — that's the false-positive guard, and vocalinux's `^\[.*\]$` is the cautionary counter-example (it eats any bracketed line).

**4. Add a dictionary-echo guard. (S)**
Parla feeds `settings.dictionary` as `initial_prompt` at `Pipeline.swift:23`, `Streaming.swift:48-54`, `main.swift:593`, `parla-eval/main.swift:69` — four sites, zero guards. Port openwhispr's `dictionaryEchoFilter`: flag when `|transcript ∩ prompt| / |transcript| ≥ 0.9` **and** `/ |prompt| ≥ 0.7`; on a hit re-decode once with `initialPrompt: nil`; a second echo → return `""`. ~30 lines in `TextRules.swift`, pure, unit-testable. openwhispr measured this failing "3 to 5 out of every 10 uses" once VAD was involved.

**5. Add a repetition-loop detector. (S)**
Port Handy's `collapse_stutters` (`audio_toolkit/text.rs`): 3+ consecutive identical words → one, no word-length cap. Add FluidVoice's `hasRepeatedAdjacentPhrase` (2–5-word phrase repeated back-to-back) as a rejection signal that returns `""` rather than collapsing. Parla currently relies entirely on whisper's temperature fallback (`Transcriber.swift:36-39`) — and vocalinux believes that fallback *causes* loops. Ship the detector so the belief is testable.

**6. Add `--replay` to `parla-eval` + commit `eval/results/`. (S/M)**
`Sources/parla-eval/main.swift`: on a full run, write `{raw, cleaned, asr_ms, llm_ms, model, provider}` per case; add a `--replay` flag that re-scores those committed files with no model and no API key. Wire it into the Tier-1 workflow from item 1. This is macparakeet's `run_all.sh verify` — the mechanism that makes normalizer/scorer/filter changes CI-gated in seconds. Also split exit codes: quality mismatch → 1, infra error → 3 (today both are 1, `parla-eval/main.swift:84-104`).

**7. Add WER, p90, failure rate, and per-category tags. (M)**
`Sources/ParlaCore/Eval.swift` gains `normalizeForWER` (lowercase, fold curly apostrophes first, strip terminal punctuation, collapse whitespace) and a token-level Levenshtein scorer. `parla-eval` reports corpus WER, p90 per-case WER, and failure rate (WER > 20%) alongside the existing zero-edit rate. Add a `category` field to golden files (a leading `# category: silence` comment line) so the report breaks down per-category — otherwise an ASR regression and a cleanup regression look identical.

**8. Grow the corpus to the 10-category taxonomy. (M)**
Currently 2 cases (`eval/cases/hello.wav`, `fillers.wav`) against the README's own target of ~50. Categories 6–10 (silence, instruction-shaped, long-form >15 s, terminal flattening, transform injection) are entirely uncovered and are where the guards above live. `eval/README.md:24-29` already documents recording with `sox -d -r 16000 -c 1`; the rule "`say` and other TTS **will not do**" is correct and should stay.

**9. Plumb `no_speech_prob` out of whisper. (M)**
`Sources/ParlaCore/Transcriber.swift:72-77` concatenates `whisper_full_get_segment_text` and drops everything else. Call `whisper_full_get_segment_no_speech_prob` per segment and use openwhispr's two-tier rule: drop at `> 0.8` unconditionally, drop at `> 0.4` when the text matches the marker/phrase set. **Verify first** whether v1.9.1 computes it at the SOT index — openwhispr ships `fix-no-speech-prob-sot-position.patch` and states plainly that without it "any no-speech-based hallucination filter is built on garbage." If v1.9.1 is unpatched, this item becomes L and should be deferred behind items 2–5, which are cheaper and cover most of the same ground.

**10. Add stage timing to the app, env-gated. (S)**
Copy epicenter's `src-tauri/src/timing.rs` shape: a `OnceLock<Bool>` read from `PARLA_TIMING`, and a `mark(_:)` that is a branch-and-return when disabled. Emit at the spans `parla-eval` cannot see — `fn_down`, `first_buffer`, `fn_up`, `stream_pass_done`, `finalize_start`, `raw_inserted`, `cleanup_done`, `swap_done` — with one line per dictation. Two payoffs: it turns every user bug report into a perf datapoint (FluidVoice's `DebugLogger.benchmark`), and it produces the number needed to check the README's claim at `README.md:95` that release latency is independent of dictation length. Parla's own audit flags that claim as false; nothing currently measures it.

**11. Add an instruction-execution guard to the cleanup leg. (M)**
`Sources/ParlaCore/Pipeline.swift:44-62` has a *length* ceiling but no semantic check, so a cleanup response that answers the dictated question at similar length is typed verbatim. Port freeflow's `appearsToHaveExecutedInstruction`: assistant-preamble regex `^\s*(sure|certainly|absolutely|here(?:'s| is)|i(?:'d| would) be happy to|i can)\b` present in output but absent from input, **or** significant-token overlap `< 0.35` when the raw transcript contains an instruction marker. On trip, keep the raw transcript (`Pipeline.clean` already never throws — it returns `(raw, message)`). Pairs with eval category 7.

**12. Settle the temperature-fallback question with data. (S, after 6–8)**
Parla keeps fallback on; vocalinux (PR #415) disables it for the opposite stated reason. Once the harness has category-6 and category-8 cases and paired-bootstrap A/B, run both configurations and record the result as a comment in `Transcriber.swift:36-39` replacing the current anecdote ("observed in the wild").

---

*Deliberately not recommended:* adding Silero VAD. The vendored `whisper.xcframework` exposes `whisper_vad_*` and `whisper_full_params.vad`, but the corpus is clear that VAD is the single most common source of *silent data loss* in this category — VoiceInk #853 measured **18×** transcript loss (103 chars vs 1,902 on identical audio) with VAD on, openwhispr disabled it for dictation by default after it stripped speech from pause-heavy dictations, and ghost-pepper #184 traced "first word missing" to VAD clipping, fixing it by gating VAD to clips ≥ 30 s. Items 2–5 buy most of the same protection with none of that risk.
