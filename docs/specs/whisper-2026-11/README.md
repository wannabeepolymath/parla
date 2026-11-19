# Whisper findings — implementation specs (2026-11)

Source: the research report comparing Parla to `openai/whisper` (thread "Whisper Repository
Improvement Research"), plus the review revisions and revised order. Baseline: `main` at `5b5db4a`.
Every claim below was re-read against the current source; corrections are in
[Corrections and drops](#corrections-and-drops).

`docs/HANDOFF-2026-11.md` is the user's untracked file. No lane touches it.

## Ground rules for every lane

- Locate code by **symbol**, never by line number. Line numbers here are hints from `5b5db4a`.
- Smallest diff. No new abstraction with one implementation, no new dependency, no new schema
  framework. Reuse the helpers each spec names.
- No build commands. Use the test / typecheck / lint commands each spec lists.
- TypeScript rule equivalent for Swift/Kotlin/Rust: no `Any`/`unsafe` escape hatches beyond what the
  spec names.
- Never fabricate data: no invented digests, clips, recordings, device results or WER numbers. Where
  a lane needs a human, data or hardware, it ships the code plus the TODO checklist it specifies.
- A lane edits only the files it owns. If it must touch another file, stop and report.
- Commit per lane on its own worktree branch; do not merge, push or open PRs unless asked.

## Native versions (checked)

| Platform | Runtime | Evidence |
|---|---|---|
| macOS | whisper.cpp 1.9.1 xcframework | `Package.swift`; `Frameworks/whisper.xcframework/.../Headers/whisper.h` |
| iOS | whisper.cpp 1.9.1, the Android vendor copy | `ios/Scripts/parlacore.py` (`VENDOR`), `ios/Sources/Core/whisper/module.modulemap` |
| Android | whisper.cpp 1.9.1 `f049fff` | `android/native/source-manifest.json` |
| Linux | whisper-rs 0.16.0 / whisper-rs-sys 0.15.0 bundling whisper.cpp **1.8.3** | `linux/Cargo.lock`; crate source `whisper.cpp/CMakeLists.txt` `project("whisper.cpp" VERSION 1.8.3)` |

Facts that hold on **both** 1.9.1 and 1.8.3 (read in both sources):

- Prompt budget: `max_prompt_ctx = min(n_max_text_ctx, whisper_n_text_ctx(ctx)/2)`; the decoder
  takes `[prev] + last (max_prompt_ctx - 1)` prompt tokens. With `n_text_ctx = 448` that is **223**
  content tokens, and the **suffix** is kept. Shared capacity formula for all lanes:
  `capacity = whisper_n_text_ctx(ctx) / 2 - 1`.
- `initial_prompt` is tokenized with `whisper_tokenize`; default `language = "en"`,
  `detect_language = false`, `suppress_nst = false`, `carry_initial_prompt = false`.
- `whisper_token_lang(ctx, id) = token_sot + 1 + id` with no range guard.
  Language count of a loaded multilingual model: `whisper_token_translate - whisper_token_sot - 1`
  (99 for a 51865 vocabulary, 100 for 51866).
- `detect_language = true` detects and returns; it is not "detect then transcribe". Use
  `language = "auto"` for that.

Tokenizer traps every prompt lane must respect:

- Do **not** call `whisper_token_count`: it logs an error on every call and is not declared
  `WHISPER_API`. Call `whisper_tokenize` with a buffer of at least `utf8ByteCount(text)` tokens
  (a token consumes at least one byte, so that buffer always fits).
- whisper-rs 0.16 `WhisperContext::tokenize(text, max_tokens)` calls `set_len(ret as usize)` on any
  return other than `-1`. A too-small buffer returns `-N` and that is undefined behaviour. Always
  pass `max_tokens = text.len().max(1)`.
- whisper-rs `set_initial_prompt` / `set_language` / `get_lang_id` panic on an interior NUL. Drop
  such terms and codes before they reach the binding.

## Shared prompt-selection contract (lanes 01, 02, 03)

```
select(words, capacity, count):
  candidates = existing byte admission, unchanged:
      normalize whitespace, drop empty, drop > 256 UTF-8 bytes,
      drop case-insensitive duplicates, keep whole terms while the ", "-joined
      text stays <= 2048 UTF-8 bytes (a term that does not fit is skipped, later
      shorter terms may still be admitted)
  used = 0; selected = []
  for term in candidates:                       # saved order is priority
      cost = count(selected.isEmpty ? term : ", " + term)
      if used + cost <= capacity: selected.append(term); used += cost
  while count(selected.joined(", ")) > capacity: selected.removeLast()   # boundary effects
  return selected
```

`count` is the loaded model's tokenizer. Tests inject `count = UTF-8 byte length`, which makes the
arithmetic exact and identical in Swift, Rust and C++.

## Wave 0 — shared fixture (orchestrator, one commit before Wave 1)

Add this key to `fixtures/desktop-android-v1.json` (existing readers look up keys by name, so an
extra key is safe; `version` stays `1`). Expected values use `count = UTF-8 byte length`.

```json
"promptBudget": [
  {"words":["alpha","beta","gamma"], "capacity":11, "expected":["alpha","beta"]},
  {"words":["alpha","a-very-long-term","b"], "capacity":8, "expected":["alpha","b"]},
  {"words":["Café","次","नमस्ते"], "capacity":10, "expected":["Café","次"]},
  {"words":["  Name0 ","name0","Name1"], "capacity":100, "expected":["Name0","Name1"]},
  {"words":["alpha"], "capacity":0, "expected":[]}
]
```

Check: `swift test --filter AndroidSharedPolicyTests` and
`cd android && ./gradlew :app:testDebugUnitTest --tests 'dev.parla.android.ProductCoreTest'` still
pass (neither reads the new key yet).

## Lanes and waves

Lanes inside a wave own disjoint files and run concurrently. A later wave starts from the merged
result of the earlier ones.

| Wave | Lane | Title | Risk | Depends on |
|---|---|---|---|---|
| 1 | [01](01-swift-token-prompts.md) | Token-aware prompts on Swift (macOS + iOS) and the vocabulary UI count | Medium | Wave 0 |
| 1 | [02](02-android-token-prompts.md) | Token-aware prompt selection in the Android JNI bridge | Medium | Wave 0 |
| 1 | [03](03-linux-token-prompts.md) | Bounded, token-aware prompt in the Linux daemon | Low | Wave 0 |
| 1 | [04](04-corpus-run-producer.md) | Human-corpus saved-run producer (`parla-eval corpus-run`) | Medium | — |
| 1 | [05](05-download-model-script.md) | `download-model.sh` staging, digest check, promotion | Low | — |
| 1 | [06](06-linux-qualification-checklist.md) | Linux hardware qualification checklist (human) | Low (doc) | — |
| 2 | [07](07-swift-language-and-ios-results.md) | Model-scoped language hint, model-derived language range, iOS typed results | Medium | 01 |
| 2 | [08](08-android-language-range.md) | Model-derived language range in the Android JNI bridge | Low | 02 |
| 2 | [09](09-linux-ownership-and-language.md) | Linux processing/delivery ownership and explicit language | High | 03, 06 |
| 2 | [10](10-acoustic-smoke-tier.md) | Acoustic smoke tier: one pinned model, a few licensed clips | Medium | 04, 05 |
| 3 | [11](11-linux-resampling.md) | Linux capture: keep device-rate audio, resample once after Stop | High | 09 |
| 3 | [12](12-experiments-harness.md) | Internal experiment switches and native evidence in `parla-eval` | Medium | 04, 07 |
| 4 | [13](13-compressed-media-import.md) | Compressed media import (M4A / MP3) | High | — |
| 4 | [14](14-word-timing-and-captions.md) | Experimental word timing and readable captions (core only) | High | 12 |
| 4 | [15](15-recognition-export.md) | Structured recognition export (core only) | Low | — |
| 5 | [16](16-import-review-exports.md) | Import review UI: JSON export | Medium | 13, 14, 15 |

Mapping to the revised order: (1) → 01–03; (2) → 07; (3) → 04; (4) → 10; (5) → 06 then 09, 11;
(6) → 07, 08; (7) → 12; (8) → 13–16. Smaller items: `download-model.sh` → 05, iOS typed results →
07, stale meeting-capture comment → 01 (it owns `Sources/Parla/main.swift` in Wave 1).

### Hot files (why the waves look like this)

- `Sources/ParlaCore/Transcriber.swift`: 01 → 07 → 12 → 14.
- `Sources/ParlaCore/RecognitionFactory.swift`: 04 (`EvalRecognition` only) → 07 → 12.
- `Sources/parla-eval/main.swift`: 04 → 12.
- `android/native/bridge.cpp`: 02 → 08.
- `linux/parlad/src/main.rs`: 03 → 09 → 11. `whisper.rs`: 03 → 09.
- `Sources/Parla/Hub/HubAudioImport.swift`, `Sources/Parla/AudioImportOwner.swift`: 13 → 16.
- `eval/README.md`: 04 → 10 → 12. `linux/VERIFY.md`: 06 → 09 → 11.

## Review

Each lane is reviewed by gpt-6.1-sol against its spec file. The reviewer gets the diff and the
spec, not the implementer's summary. For lanes 09, 11 and 13 (High risk) add a blind audit of the
touched files with no claim list.

## Items I recommend not building as specced (your call)

1. **Word timing (lane 14) — decided, see [Decisions](#decisions).** It is specced on whisper's
   heuristic `token_timestamps`, not DTW, because DTW needs a second context configuration and a
   per-model alignment-heads preset, which would invalidate the qualified `whisper191PCM10ms`
   segment clock. Even the heuristic path has no accuracy evidence until lane 10 has clips.
2. **MP4 video import (lane 13) — decided, see [Decisions](#decisions).** The importer refuses
   files over 20 MB and 10 minutes. Most MP4 videos exceed 20 MB, so MP4 support would mostly
   produce refusals.
3. **Upstream-normalizer benchmark WER.** Kept out of the native code as instructed. Lane 04 only
   documents how to run it externally. I would not write even the helper script until someone needs
   a number comparable to published Whisper WER.
4. **Mobile model residency and a smaller multilingual catalog model** (report §14). Not specced:
   both need phones and held-out speech. Lane 12 lets you compare any local model file on desktop;
   it adds no catalog entry.
5. **Native VAD.** Lane 12 exposes it only as an eval-process switch, never on a timed decode,
   never in the app.

Not in the revised order and therefore not specced: native speech translation, meeting
diarization/timeline work, streaming-boundary policy experiments, automatic-language policy
experiments (report §12, §18). Lane 12's harness can run the last two later without new code
paths beyond a flag.

## Corrections and drops

| Report / review claim | Verdict | Evidence |
|---|---|---|
| Byte-admitted prompt can lose its highest-priority terms; native keeps a 223-token suffix | Confirmed | `whisper.cpp` 1.9.1 `max_prompt_ctx` and the `n_take1` suffix insert; identical in 1.8.3 |
| "Calculate capacity using the loaded model's tokenizer" via `whisper_token_count` | Corrected | `whisper_token_count` logs `too many resulting tokens` on every call and lacks `WHISPER_API`; use `whisper_tokenize` with a byte-length buffer |
| Linux joins the whole dictionary unbounded | Confirmed | `linux/parlad/src/whisper.rs` `initial_prompt` |
| (new) whisper-rs `tokenize` is unsafe with a small buffer | Added | whisper-rs 0.16 `whisper_ctx.rs` `tokenize`: `set_len(ret as usize)` for any `ret != -1` |
| (new) The dictionary conditions only the first 30 s window and only below temperature 0.5 | Added | `prompt_past1` is replaced by decoded tokens after each window; `t_cur < WHISPER_HISTORY_CONDITIONING_TEMP_CUTOFF`. Budgeting does not fix this. `carry_initial_prompt` is an experiment in lane 12 |
| (new) `parla-eval` does not measure the shipped prompt | Added | `EvalRecognition.transcribe` passes an explicit `initialPrompt`, bypassing the handle's own selection, and acquires with `RecognitionRequest(settings: Settings())` (empty dictionary). Fixed in lane 04 |
| Vocabulary UI count is byte-based | Confirmed | `HubPages.swift` `usedWords` (`VocabularyHints.select(..., byteLimit: asrBytes)`) |
| Every new Transcriber starts at English | Confirmed, wider than iOS | `WhisperTranscriber.init` seeds `last: "en"`; iOS `DictationEngine.localRecognizer` acquires with no resident. macOS has the same reset after the 300 s idle unload. Android already keeps `lastLanguage` per model in `bridge.cpp`, so it needs nothing |
| Language id 99 maps to the translate token on a 51865 vocabulary | Confirmed | `whisper_vocab::num_languages`, `whisper_token_lang`; Swift `detectedLanguage` and the JNI probe scan `0...whisper_lang_max_id()` |
| "Derive supported languages from model metadata" | Refined | No vocabulary-size constants needed: `whisper_token_translate - whisper_token_sot - 1` (both public) |
| Linux callback-local linear resampling | Confirmed | `linux/parlad/src/audio.rs` `resample_linear_into` called from `Ring::push`, floor output length, no carried phase |
| "Use a stateful streaming resampler" | Replaced | Per the review: keep device-rate audio, resample the whole recording once after Stop. No streaming state exists to get wrong. Memory cost assessed in lane 11 |
| Linux Cancel after Stop cannot revoke delivery; A/B completion order decides the clipboard | Confirmed | `session.rs` `(Stop\|Cancel, Idle) => Ignored`; `main.rs` `tokio::spawn(app.finish(...))` per Stop; no check before `deliver::to_clipboard` |
| Linux has no language setting and decodes as English | Confirmed | `parla-core/src/config.rs` `Config`; `whisper.rs` never calls `set_language`; 1.8.3 default `"en"` |
| `download-model.sh` accepts any existing file and writes to the final name | Confirmed | `scripts/download-model.sh`. Also: its usage line offers `large-v3-turbo` and `tiny.en`, which have no pinned digest anywhere in the repo |
| iOS projects recognition to `.text` | Confirmed | `DictationEngine.localRecognizer` returns `handle.recognize(...).text`; `recognize` maps every nil to one message |
| Stale comment above the meeting capture binder | Confirmed | `Sources/Parla/main.swift` above `configureMeetingHub`: "Production capture stays OFF…" while `captureCapability:true`, `enabled:true` |
| "No producer is added" (`eval/human-corpus-protocol.md`, ROOTPOLICY8A.1) | Superseded on request | Lane 04 adds the producer as a new subcommand; `corpus-check` stays read-only and the protocol text is updated to say so |
| Port upstream's English normalizer into the scorer | Dropped | Per the review: run it externally if needed, no native port |
| New cross-platform contract/fixture schema (report §19) | Dropped | Per the review: extend `fixtures/desktop-android-v1.json` only (Wave 0) |
| Model-aware language choices in the picker UI | Dropped | The shipped catalog has one multilingual model (51866). Only custom models are affected; validation and the probe are fixed, the picker list is unchanged |

Not verified (stated as such in the lanes that rely on them): token density of Hindi/CJK context
text (the 64-token reserve in lane 01 is a starting value), cpal behaviour on real PipeWire/ALSA
devices, `cargo test` for `parlad` on this Mac (`linux/VERIFY.md` says it was developed that way),
and whether whisper-rs frees the boxed abort closure.

## Decisions

Decided by the design owner; each lane spec states the same single design.

1. **Lane 09, Linux job policy: queue.** Jobs deliver in recording order and Cancel while idle
   revokes every pending job. Superseding would silently drop a finished dictation.
2. **Lane 09, Linux default language: `"en"`.** An omitted `language` keeps today's forced English
   on every model; `language = "auto"` is the opt-in. No existing config changes behaviour or speed.
3. **Lane 13, compressed import: M4A and MP3 only.** No MP4, caps unchanged. The 20 MB cap bounds a
   whole-file in-memory read and would refuse most MP4 video.
4. **Lanes 14 and 16, word timing: internal-only core plus the JSON export.** No app path requests
   word timing, and the readable-caption buttons are held until lane 14's human word-time check is
   recorded. Heuristic word times have no accuracy evidence yet.

## Open questions

Still open: the ones at the bottom of lanes 04 and 11.
