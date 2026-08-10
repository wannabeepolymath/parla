# ASR Engines & Models

Parla runs one engine (whisper.cpp v1.9.1) with one model (`ggml-base.en.bin`, 148 MB, English-only, hardcoded in `Sources/ParlaCore/Transcriber.swift:14`). This doc compares every engine seen across ~40 audited dictation apps so we can decide what — if anything — to add, and documents the model-download failure modes those apps hit so we don't rediscover them. Companion doc: [`04a-parakeet-audit.md`](04a-parakeet-audit.md) covers *who ships Parakeet and which variant*; this doc covers *should we*.

---

## 1. The engine matrix

Sizes are disk footprint of the shipped default variant. RTFx = realtime factor (higher is faster). WER sources are cited per-row; **none of these were measured by us**.

| Engine | Runtime | Platforms | Model size | WER (LibriSpeech clean/other) | RTFx | Peak RSS | Streaming | Multilingual | License | Swift integration |
|---|---|---|---|---|---|---|---|---|---|---|
| **whisper.cpp** (ours) | ggml + Metal | mac/Win/Linux/Android, CPU+Metal+Vulkan+CUDA | tiny 75 / base 148 / small 466 / medium 1463 / large-v3 2952 / **large-v3-turbo 1620** / **turbo-q5_0 574** MB (`goodroot/hyprwhspr` `utils/whispercpp_model_info.py:30-60`) | base.en ~5.4/12.5, small.en ~3.7/8.0 (`FrigadeHQ/yap` README, third-party) | ~14× turbo, measured M4 Pro (`moona3k/macparakeet` `benchmarks/asr/README.md`) | 274 MB turbo (same source) | via `whisper_vad_*` API + manual windowing | 99 langs (multilingual weights) | MIT | **shipped** — xcframework, 99-line wrapper |
| **Parakeet TDT 0.6B v3** | CoreML/ANE (FluidAudio), ONNX (`ort`/sherpa), GGUF (transcribe-cpp), MLX | mac 14+ (CoreML); Win/Linux via ONNX | **~465 MB int8 CoreML** (`altic-dev/FluidVoice` `expectedDownloadBytes: 483_288_717`); 2.6 GB fp32 ONNX (`watzon/pindrop`) | 2.3% clean / 13.7% Earnings-22 (`moona3k/macparakeet` #330, 40 clips) | **81–93×** measured M4 Pro (same bench) | **115–131 MB** | native cache-aware streaming (FluidAudio `StreamingUnifiedAsrManager`) | 25 European langs, auto-detect | CC-BY-4.0 model / Apache runtime | **M** — SPM, but macOS 14 floor |
| **Parakeet TDT 0.6B v2** | same | same | ~443–474 MB (`FluidVoice` 464,421,712 B; `Beingpax/VoiceInk` 474 MB) | **1.9% clean / 13.3% Earnings-22** (`macparakeet` #330) | ~same as v3 (cold start 0.55 s vs 0.38 s) | ~same | same | **English only** — cannot drift | same | **M** |
| **Apple SpeechAnalyzer** | on-device Speech.framework | **macOS 26+ only** (`FrigadeHQ/yap` `project.yml` `deploymentTarget macOS: "26.0"`; also `watzon/pindrop`, `moona3k/macparakeet`, `Muesli-HQ/muesli`, `altic-dev/FluidVoice`) | **0 bytes shipped** — OS-managed via `AssetInventory` | **2.12% / 4.56%** (`yap` README + `matthartman/ghost-pepper`, both citing get-inscribe.com, 5,559 clips) | ~3× Whisper Small on M2 Pro (same) | OS process | **native** — `.volatileResults` gives free partials | OS locale set | free w/ OS | **S** — but see §4 |
| **WhisperKit** | CoreML, ANE+CPU | macOS 13+/iOS | large-v3-turbo 632 MB; base 145 MB | — | 2.29 s cold start vs 0.38 s Parakeet (`macparakeet` bench) | — | yes | yes | MIT | **S** — pure SPM |
| **Moonshine** | ONNX | via `transcribe-rs`/GGUF | **tiny 35 MB / base 77 MB** (`cjpais/Handy` `catalog.json`) — smallest usable | — | — | — | `moonshine_streaming` variant | English | MIT | **L** — no Swift binding |
| **SenseVoice / FunASR** | ONNX int8 | Handy, voxtype, OpenSuperWhisper (planned) | 230–938 MB (`peteonrails/voxtype`); 253 MB SenseVoiceSmall (`Handy`) | — | claimed "5–15× faster, 50+ langs" (`thewh1teagle/vibe` #1132–1140, user claims) | — | no | 50+ langs, CJK-strong | MIT | **L** — hand-rolled fbank + CTC in `voxtype/src/transcribe/` |
| **Vosk** | Kaldi | `VocaHQ/vocalinux` only | ~40 MB small | worst of the set | — | "works on 4 GB RAM" | yes (true streaming API) | per-model | Apache-2.0 | **L**, and not worth it |
| **Cohere Transcribe** | CoreML / GGUF | Muesli, FluidVoice, voxtype | 1.5 GB q4f16 → 2.3–3.8 GB | — | **11×**, 73 s cold start | **~11.6 GB** (`macparakeet` bench) | no | 14 langs | — | gated behind 16 GB RAM floor in `moona3k/macparakeet` |

Two things fall straight out of that table:

1. **Parakeet is ~6× faster than whisper-turbo at ~⅓ the RAM and better clean-speech WER.** That is why 16 of 39 audited apps default to it ([`04a`](04a-parakeet-audit.md) §2).
2. **Apple SpeechAnalyzer beats Whisper Small on accuracy at zero download.** That is why every macOS-26-only app in the corpus uses it as the *sole* engine (`FrigadeHQ/yap` ships 4,580 lines total and no model bytes).

---

## 2. The findings that actually change decisions

### 2a. Long audio breaks Parakeet — and it is *not* the quantization

`thewh1teagle/vibe` issue [#289](https://github.com/thewh1teagle/vibe/issues/289) is the single most operationally important number in the corpus. One uninterrupted 390 s pass:

| quant | WER | infer | peak RAM |
|---|---|---|---|
| int8 | **40.40%** | 85.4 s | 5,231 MB |
| fp16 | 10.17% | 91.4 s | 9,781 MB |
| fp32 | 10.17% | 181.6 s | 8,041 MB |

Per-section int8: 0–60 s **41.4%**, 240–300 s **69.5%** — while fp32 on the same sections is 2.6% / 45.1%. The reporter's conclusion, verbatim: *"the longer the audio is, the more it defaults back to english… AFAIU it's not actually caused by the int8 quantization (fp32 has the same issue)."* There is a hard encoder wall at **~390 s / 5000 frames**. The downstream fix was chunking at **20 s, clamped [10, 25]**.

Murmure's response (`Kieirra/murmure` `src-tauri/src/audio/chunking.rs:63-70`):
```rust
const CHUNK_SILENCE_ARM_SECS: u32 = 15;      // arm the silence cut at 15s
const CHUNK_SILENCE_CUT_MS: u64 = 500;       // 500ms of silence cuts the chunk
const CHUNK_FORCE_CUT_SECS: u32 = 60;        // hard cut if no silence found
const CHUNK_FORCED_OVERLAP_SECS: f32 = 1.0;  // tail replayed as next chunk head, deduped
```

**Parla's `StreamWindow.threshold = 15 s` (`Sources/ParlaCore/Streaming.swift:20`) is already in the right band.** Our freeze-prefix architecture is, by accident, exactly the mitigation Parakeet needs. Good.

### 2b. Parakeet has no `initial_prompt` — and Parla depends on it twice

Parla feeds the user dictionary to whisper as `initial_prompt` (`Sources/ParlaCore/Pipeline.swift:23`) *and* feeds the last 200 chars of confirmed transcript back as cross-cut context (`Sources/ParlaCore/Streaming.swift:48-54`). Neither survives a Parakeet swap. The ecosystem replacements:

- **CTC rescoring** — `altic-dev/FluidVoice` `FluidAudioProvider.prepare` builds *two* `AsrManager`s from one `AsrModels` object: a streaming one without boosting and a final one with `configureVocabularyBoosting(vocabulary:ctcModels:)`. Comment: *"Shares the same underlying MLModel objects (reference types) so memory overhead is only the decoder state (~100KB)."* Costs a second CTC model download.
- **Weighted Aho–Corasick logit boost** — `Kieirra/murmure` `src-tauri/src/engine/boost_tree.rs`, fused into greedy decode: `BOOST_TOP_K = 5` at phrase start, relaxed to 20 after 3 tokens deep, alpha decays `clamp(3.5 - log10(n/5), 1.0, 3.5)`. Plus a **divergence guard** (`engine.rs:554-574`): if the boosted decode emitted ≥24 tokens, replay the unboosted greedy decode (encoder output is already computed — decoder-only) and reject the boosted result if normalized token-level Levenshtein > 0.35, *because boosting can flip the whole utterance into another language*.
- **Post-hoc fuzzy correction** — `Kieirra/murmure` `dictionary/dictionary.rs`, gated on per-word confidence = **min token probability** with `POSTCORR_CONF_THRESHOLD = 0.45`, `POSTCORR_MIN_LEN = 5`, edit budget 1 below 8 chars / 2 above, disabled entirely above 100 dictionary words.

None of these is free. Budget them into the Parakeet estimate, not out of it.

### 2c. v3 auto-detect translates to English against the user's will

Repeatedly reported across independent repos: `cjpais/Handy` #1206 (5 reactions), #1076, #1528, #1572, #679 — *"Canary 1B v2 and Parakeet v3 translate to English whenever language is 'auto', even with the translate toggle OFF."* Same class in `Muesli-HQ/muesli` #786 (*"I speak Spanish and sometimes mid-sentence the system switches"*) and `Beingpax/VoiceInk` #150 (English transcribed as **Welsh**, repeatedly, and retry produced more Welsh).

v2 cannot do this — it is English-only by construction. That is the entire remaining argument for v2 ([`04a`](04a-parakeet-audit.md) §1: *"kept because it is still marginally better on English (6.05 vs 6.32 avg WER) and never auto-detects the wrong language"*).

### 2d. Language auto-detect on short clips is a trap for *any* engine

`digimata/parrot` PR [#15](https://github.com/digimata/parrot/pull/15) is a fix that its own author opened, shipped, then **closed and reverted after measuring**. He validated `detectLanguage: true` on a 5.7 s Portuguese sample where `en`, `pt` and auto produced byte-identical text. Then real usage — dictation utterances are 0.6–2 s:

```
→ 0.58s · Testing and speaking in English.
→ 0.58s · Testar e falar em inglês          <- misdetected as pt
→ 0.58s · Testing and speaking in English.
```

Closing note: *"My original measurement used a 5.7 s clip and therefore never exercised the case the app actually runs on."* Independently confirmed in `Starmel/OpenSuperWhisper` #34 (9 comments, reproduced for Chinese/Russian/pt-BR) — the fix there was pinning `task: .transcribe` and never letting the flag float.

**Parla is accidentally safe here** — `language` is never set so whisper's compiled default `"en"` applies with `detect_language=0`. That is a latent bug if we ever ship a multilingual model, and a *feature* today.

### 2e. GPU/backend selection silently picks the wrong device

`Kieirra/murmure` #589: Vulkan enumerates iGPU as device 0, so whisper.cpp always chose an Intel UHD 630 over an RTX 2060. The follow-up (#636) is the real sting: pip wheels are often CUDA-built where device 1 is the **CPU fallback**, so passing a Vulkan index into a CUDA build ran on CPU at ~30 s/dictation with zero `nvidia-smi` activity. Their fix probes the *shipped shared objects* rather than trusting config (`_detect_pywhispercpp_gpu_backend`, globs `libggml-vulkan*.so*` / `libggml-cuda*.so*`).

macOS analogue: our `params.flash_attn = true` (`Sources/ParlaCore/Transcriber.swift:21`) is a **no-op** — whisper.cpp flipped `flash_attn` on by default before v1.9.1, so `whisper_context_default_params()` already returns it set. Harmless, but the trailing comment ("off by default") is stale documentation of a decision that no longer exists. Confirm against the vendored header before deleting.

---

## 3. Model download, verification, caching

Ranked by how badly the corpus got burned.

**Exact-byte-size equality bricks installs.** `watzon/pindrop` #785: catalog said `886_381_824` for Whisper Large Turbo; HuggingFace served `886_381_760` after a 2026-07-21 re-upload. **64 bytes off.** `isModelFileValid` compares `==`, so `prepare()` deleted the good file and re-downloaded it in an infinite loop; manual placement was rejected by the same check. Recurred in `moinulmoin/voicetypr` #87 → #122 across three releases. Validate a header or a hash, never a byte count baked into a binary.

**Never delete the old model before the new one lands.** `thewh1teagle/vibe` PR [#1245](https://github.com/thewh1teagle/vibe/pull/1245) is the reference implementation: download to `<dest>.part` → assert `downloaded == content_length` with both numbers in the error → rename existing to `.backup` → rename `.part` into place → delete backup → **restore backup if the rename fails**. Progress emitted every 2 MiB.

**Parla currently does the exact opposite.** `Sources/Parla/main.swift:952`:
```swift
if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
try FileManager.default.moveItem(at: tmp, to: dest)
```
A failed move leaves the user with **no model at all**. And there is no checksum anywhere.

**Corporate proxies return HTML with HTTP 200.** `thewh1teagle/vibe` #353/#355 needed four layers: `Content-Type` check for `text/html|xml`, sniff the first 512 bytes (markup arrives without a markup content-type), re-validate files *already on disk* (the corrupt payload predates the validator), and walk `.mlpackage` directories because a provider preflight that returns on file-existence never reaches the downloader. `voicetypr` #579 is the same shape with `unable to get local issuer certificate` swallowed silently — no progress bar, no error, nothing in the UI.

**Concurrency and stalls.** `cjpais/Handy` `src-tauri/src/managers/model.rs:1900`, from issue #1579 (47 comments, the most-discussed in that repo):
```rust
const ATTEMPT_STREAMS: [usize; 4] = [4, 1, 1, 1];
// "Eight simultaneous connections were all reset on an affected network in #1579,
//  while one stream succeeded; four is a less aggressive fast path."
```
Plus a **fresh HTTP client per attempt** (*"so a wedged connection from the previous try can't poison the retry"*), `.with_token(None)` (a stale cached HF token breaks public downloads), and a 60 s stall watchdog because hf-hub has no internal timeouts.

**Caching identity is `(len, mtime)`, not path.** `moona3k/macparakeet` `transcription/model_cache.rs` — reuse requires `cached.path == model_path && current_identity == cached.disk_identity` where `DiskIdentity { len, mtime }` follows symlinks. Delete + re-download the same coordinate → mtime changes → the stale resident model is dropped. Without this, a re-download silently serves the old weights and the only working fix is picking a different model and switching back (their `apps/whispering/specs/local-model-disk-identity.md`).

**The two clean strategies:**
- *Delegate.* `EpicenterHQ/epicenter` uses the **shared HuggingFace cache** via `hf-hub` — staging, resume and integrity are hf-hub's job, and a model another HF tool already fetched is reused for free. Model id is a coordinate `{repo_id}@{revision}/{filename}`; an id outside the compiled catalog is *refused, not parsed*.
- *Own it.* `peteonrails/voxtype` mirrors everything to Cloudflare R2 with per-file sha256 in a `manifest.json`, and deliberately has **no HuggingFace fallback**: *"Voxtype controls R2 directly so we can serve integrity guarantees that community HF accounts can't promise"* (`src/setup/model.rs:1005-1012`). `Kieirra/murmure` goes further and bundles the 601 MB model in the installer — zero runtime download, zero download bugs, 1 GB installer.

**Pinned revisions matter.** `cjpais/Handy`'s `catalog.json` is compiled into the binary (67 models, `catalog_version: 2`) with `revision` commit shas and per-quant `size_bytes` + `sha256`, so the picker works offline and the mirror is a plain static host: `{mirror}/{repo_id}/{revision}/{filename}` — bytes from either source verify against the same hash. `matthartman/ghost-pepper` pins immutable HF revision URLs + `expectedSHA256` + `expectedByteCount`, streaming-hashes in 4 MiB chunks before load, and deletes on mismatch.

**Do the hash once.** `matthartman/ghost-pepper` #163: `isVerifiedModelFile` streams SHA-256 over a multi-GB GGUF **synchronously on the main thread**, and the Models panel calls it 2–3× per model per render. Severe hangs. Cache the verdict keyed on `(size, mtime)`.

---

## 4. Apple SpeechAnalyzer: the honest read

The accuracy and zero-download story is real (§1). Three things are also real:

1. **macOS 26 only.** Every corpus app using it either targets 26 exclusively (`FrigadeHQ/yap` `deploymentTarget macOS: "26.0"`; `Gremble-io/Detto`; `sebsto/wispr`) or gates it `@available` behind a fallback (`watzon/pindrop`, `moona3k/macparakeet`, `Muesli-HQ/muesli`). Parla targets **13.3** (`Package.swift:6`).
2. **The Intel fallback was a privacy incident.** `FrigadeHQ/yap` issue [#16](https://github.com/FrigadeHQ/yap/issues/16), "Yap sends all audio data to Apple servers (on Intel Macs)": `LegacyTranscriptionService` set `requiresOnDeviceRecognition` *only when the OS reported on-device support and left it off otherwise*, which streamed audio to Apple with no warning while the README promised the opposite. Reported by an outside auditor; maintainer conceded in **7 minutes**, deleted the whole fallback path, and dropped Intel support. Their replacement policy is the right one:
   ```swift
   // No on-device model covers this locale. Refuse rather than hand the
   // audio to a service that would send it off the device.
   throw TranscriptionError.unsupportedLocale
   ```
3. **The locale string is a booby trap.** `yap` issue [#5](https://github.com/FrigadeHQ/yap/issues/5) → PR #6: Language = English (US) + Region = Spain makes `Locale.current.identifier(.bcp47)` return `en-US-u-rg-eszzzz`. `supportedLocales` never contains the extended form, so exact string comparison says "unsupported" *with the model installed*. It then fell to `SFSpeechRecognizer`, which returns non-nil and `isAvailable == true` for locales it does not support, so the guard never fired — the failure surfaced as an infinite silent segment-restart loop and an empty transcript. Fix is three-step widening (exact BCP-47 → language + `locale.language.region` → language, any region), and note the trap inside the trap: **`locale.region` is the wrong field** (returns `ES`, the regional override) — `locale.language.region` returns `US`.

Verdict: worth building as an optional engine behind `@available(macOS 26, *)`, valuable specifically as the **thing a fresh user dictates with while the 148 MB whisper download runs**. Not worth making it the default or bumping our floor for.

---

## 5. Swift integration effort, concretely

| Path | What it costs | Verdict |
|---|---|---|
| **FluidAudio** (Parakeet, CoreML/ANE) | SPM package, `platforms: [.macOS(.v14)]`, `swift-tools-version: 6.0`, `dependencies: []` but 1 binaryTarget (`NemoTextProcessing` xcframework) — verified against `FluidInference/FluidAudio` `Package.swift`, latest `v0.15.5`. Chosen by ~20 of the audited macOS apps. | **The only sane Parakeet path for Swift.** Cost is the macOS 14 floor. |
| **WhisperKit** | pure SPM, macOS 13+. But `TypeWhisper/typewhisper-mac` pins it behind `#if MACPARAKEET_HAS_WHISPERKIT`-style flags because it isn't Swift-6-clean; `moona3k/macparakeet` gates it behind `MACPARAKEET_SKIP_WHISPERKIT=1` for the same reason. | Redundant with whisper.cpp. Skip. |
| **sherpa-onnx** | C API; `OpenWhispr/openwhispr` ships **prebuilt WS server binaries** and talks to them over a socket rather than linking. | Sidecar, not a library. **L**. |
| **transcribe-rs / transcribe-cpp** | Rust. Used by Handy, SpeakoFlow, epicenter, vibe (via a sidecar process). | Not a Swift path. **L**. |
| **parakeet-mlx** | Python. `heardlabs/heard` runs it inside a **closed-source subprocess**; `daniel-carreon/sflow` is frozen. | No. |
| **Apple SpeechAnalyzer** | zero deps, `import Speech`, ~137 lines total in `FrigadeHQ/yap` `Sources/Services/TranscriptionService.swift`. | **S**, gated on macOS 26. |

---

## 6. What we'd be walking into

`moona3k/macparakeet`'s benchmark harness (`benchmarks/asr/README.md`) is the only rigorous eval in the corpus and its methodology is worth copying wholesale before we change any engine:

- **One canonical normalizer for every engine** — Whisper `EnglishTextNormalizer` for English, `BasicTextNormalizer` for ko/ja/zh, applied identically to reference and hypothesis. Curly apostrophes folded to straight **first** (without it the normalizer mis-splits contractions and inflates WER — there is a regression test for exactly this).
- **WER for space-delimited languages, CER for ko/ja/zh.**
- **Paired bootstrap for significance, not CI overlap**: *"a difference is significant only if its paired CI excludes 0… overlap is over-conservative and under-detects real gaps."* 2000 resamples, seed 1234.
- Report **p90 and failure rate (WER > 20%)**, not just corpus WER — corpus WER hides the dictations that actually annoy people.
- `run_all.sh verify` re-scores committed JSONL fixtures **without downloading models** — a repo-only regression gate.

Parla's harness today (`Sources/parla-eval/main.swift:110`) is exact-string-match after whitespace collapse over **2 committed cases**. A single punctuation difference is a full FAIL and an ASR regression is indistinguishable from a cleanup regression.

---

## What Parla should do

Ordered by value ÷ effort. The first two beat every engine swap in this doc.

**1. Fix the resampler. (S)** `Sources/ParlaCore/AudioRecorder.swift:115` constructs a **new `AVAudioConverter` per tap buffer** and drains it with `.endOfStream`. Resampler state is therefore not carried across buffers — 48 kHz→16 kHz restarts its filter at every ~85 ms boundary, injecting a discontinuity at every buffer edge for the entire recording. This is the most likely source of avoidable WER in the app and it costs zero new dependencies. Hoist the converter to an instance property keyed on `(inputFormat, outputFormat)`, feed with `.noDataNow`, flush once on `stop()`. Also: both failure paths `return []` silently — log or count them.

**2. Ship `large-v3-turbo-q5_0` as the default model. (S)** 574 MB vs 148 MB, `scripts/download-model.sh` already accepts `large-v3-turbo`, and `Transcriber.swift` needs no changes. base.en is the weakest model in the whole corpus. Two blockers to clear first: (a) `defaultModelPath()` hardcodes `ggml-base.en.bin` (`Transcriber.swift:14`) and `downloadModel()` hardcodes the base.en URL (`main.swift:923`) — make both take a model id; (b) turbo is **multilingual**, so we must now set `params.language = "en"` explicitly in `Transcriber.swift` rather than relying on whisper's compiled default, or we inherit §2c/§2d wholesale.

**3. Harden the model download. (S)** `Sources/Parla/main.swift:952` deletes the existing model *before* the move — a failed move leaves the user with nothing. Adopt `vibe` PR #1245's shape: download to `.part`, verify length **and** a pinned SHA-256, rename old → `.backup`, move, delete backup, restore on failure. Add a `Content-Type`/first-512-bytes markup check (`vibe` #353). Cache the hash verdict keyed on `(size, mtime)` so we don't re-hash 574 MB on every launch (`ghost-pepper` #163).

**4. Delete the stale `flash_attn` line. (S)** `Sources/ParlaCore/Transcriber.swift:21` — v1.9.1's `whisper_context_default_params()` already returns `flash_attn=1`. The assignment is a no-op and its comment ("off by default") is wrong.

**5. Upgrade the eval harness before any engine work. (M)** `Sources/parla-eval/main.swift` + `Sources/ParlaCore/Eval.swift`: add WER (not exact-match), report **p90 + failure rate (WER > 20%)**, add an ASR-only mode so an ASR regression is distinguishable from a cleanup regression, and add a `verify` target that re-scores committed hypothesis fixtures with no network and no model. Then fill `eval/cases` toward the 50 utterances `eval/README.md` already asks for. Without this we cannot honestly evaluate items 1, 2 or 6.

**6. Parakeet: yes, but v3 behind an engine setting — and not first. (M–L)** Recommendation on the brief's specific question: **do not add v2 as a primary path.** [`04a`](04a-parakeet-audit.md) is unambiguous that zero of 16 defaulting apps chose v2, and v2's only durable advantage (English determinism) is something Parla gets for free right now by pinning `language = "en"` (item 2). Add **v3** via FluidAudio as a selectable engine when we do this, and expose v2 as the English-only option alongside it, matching what 12+ audited apps ship. The real costs are not the model:
   - **macOS floor 13.3 → 14.0** (verified against `FluidInference/FluidAudio` `Package.swift`). Non-negotiable and non-reversible.
   - **Loss of `initial_prompt`.** `Sources/ParlaCore/Pipeline.swift:23` (dictionary) and `Sources/ParlaCore/Streaming.swift:48-54` (cross-cut context carry) both stop working. Budget the CTC-rescoring or fuzzy-correction replacement from §2b, plus murmure's divergence guard.
   - **`Sources/ParlaCore/Transcriber.swift` stops being the only whisper file** — it needs an engine protocol, and `Sources/Parla/main.swift`'s `loadModel()`/warm-up/download all become engine-dispatched.
   Our `StreamWindow.threshold = 15 s` (`Sources/ParlaCore/Streaming.swift:20`) already sits in the safe chunk band from §2a, so the hardest part of Parakeet integration is already built.

**7. Apple SpeechAnalyzer as an onboarding fast path only. (M)** Add behind `@available(macOS 26, *)` as a *selectable* engine whose sole default use is "dictate now while the model downloads". Do not make it the default, do not bump the floor. Two non-negotiables from §4: (a) never enable any server-backed fallback — refuse with an error the way `yap` does, or our on-device claim becomes a lie the way theirs did; (b) implement `yap`'s three-step locale widening and use `locale.language.region`, not `locale.region`.

**8. Skip entirely:** Moonshine / SenseVoice / FunASR / Vosk / Cohere. No Swift binding (L effort each), and the only measured Cohere numbers in the corpus are 11× RTFx, 73 s cold start and **~11.6 GB peak RSS** (`moona3k/macparakeet` bench) — gated behind a 16 GB RAM floor in the one app that ships it.
