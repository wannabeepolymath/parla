# Speech, audio, platform and workflow evidence

Research date: 2026-10-28. Static source inspection; no competitor built or run. Parla baseline: `6a8d771c72a335fe8fdecee2889906785eb6d050` plus the existing README/Android working tree. Effort is a rough engineering size, not a commitment: S = 1–2 days; M = 3–5 days; L = 1–3 weeks; XL = a separate multi-week initiative. Runtime qualification is additional.

## E01 — Add a second speech engine behind a small capability interface

**Evidence.** [FluidVoice's provider protocol](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/TranscriptionProvider.swift#L139-L225) separates preparation, batch/final/preview transcription, word timing and file capabilities. [Vibe's engine enum](https://github.com/thewh1teagle/vibe/blob/2ea5ecef989933282fca517d82d4e3128ae5fb0b/server/crates/vibe-server/src/engine.rs#L5-L120) implements Whisper, Parakeet and Nemotron and explicitly rejects unsupported translation/prompts. [MacParakeet's capability model](https://github.com/moona3k/macparakeet/blob/590b6c253bd27bc55723f0e8c8394b64467c09de/Sources/MacParakeetCore/STT/SpeechEngineCapabilities.swift#L1-L149) represents language policy, live preview, timestamps, vocabulary and memory requirements.

**Parla today.** `WhisperTranscriber` in `Sources/ParlaCore/Transcriber.swift:9`; the catalog already has three Whisper choices (`ModelCatalog.swift:41`). `Pipeline.transcribe` is already injectable (`Pipeline.swift:5`), so a wholesale pipeline rewrite is unnecessary. App streaming still accepts concrete `WhisperTranscriber` (`Sources/Parla/Dictation.swift:462`).

**Proposal.** Start with one optional Parakeet/FluidAudio adapter for supported Apple silicon hardware, retaining whisper.cpp for Intel, older macOS and broader language coverage. Keep batch and streaming capabilities explicit; avoid forcing a fake streaming implementation. Compare on the same human recordings before changing a default. **M for the seam, L for a qualified adapter.**

**Against.** A three-model app is easier to support. Adding a model family increases binary/dependency, download, language and cancellation cases. Competitor adoption proves feasibility, not better accuracy, memory use or latency on our users' hardware.

**Acceptance.** Same recordings through both engines; word and formatting quality, no-speech behavior, cold/warm release-to-delivery latency, peak memory, language coverage, cancellation and 10-minute dictation. Unsupported capabilities are visibly unavailable. Existing installations keep their selected model.

## E02 — Offer Apple SpeechAnalyzer as a separately gated local engine

[FluidVoice's implementation](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/AppleSpeechAnalyzerProvider.swift#L9-L105) checks the selected locale, installed assets and cancellation during preparation. [Muesli's implementation](https://github.com/Muesli-HQ/muesli/blob/6c223cd4b3ac7ea1332ddc9e49463f01fd97140c/native/MuesliNative/Sources/MuesliNativeApp/AppleSpeechAnalyzerBackend.swift#L242-L430) also handles locale equivalence and asset reservation lifetimes.

Parla's speech implementation is whisper.cpp (`Transcriber.swift:9`) and supports macOS versions below these competitors' `macOS 26` API guards. This is an **optional adapter, L**, not a deployment-target increase. It could reduce manual model management for eligible users. Against: OS/locale restrictions, asset readiness and output quality still need device testing; a system framework is not proof of universal offline readiness. Acceptance: unsupported OS, missing locale/asset, download cancellation, language switching and airplane-mode use after assets are installed.

## E03 — Add speech detection with padded boundaries

[Murmure's adaptive gate](https://github.com/Kieirra/murmure/blob/2218c1bab463d17ace34258a3842b9f230d60ca3/src-tauri/src/audio/vad.rs#L1-L76) tracks a noise floor with separate speech/silence thresholds; its tests include quiet microphones and persistent noise. [TypeAloud's neural gate](https://github.com/hellotaotao/typealoud/blob/9401425053f58a215fbe885dfc172e30d41d69a4/src/views/vad-gate.js#L1-L31) uses Silero, with [pure decision rules](https://github.com/hellotaotao/typealoud/blob/9401425053f58a215fbe885dfc172e30d41d69a4/src/views/vad-decision.mjs#L1-L42) for minimum speech, padded trimming and minimum useful savings.

Parla already rejects short/near-silent buffers (`TextRules.audioWorthTranscribing`, `TextRules.swift:115`) and strips non-speech markers (`Transcriber.swift:172`); it does not have a speech classifier on this path. Pilot a no-speech decision first, then optional leading/trailing silence trimming. **M for adaptive experiments; L for a bundled neural path.** Do not simply raise the fixed RMS floor. Against: quiet speech, whispered words and accented onsets are easy false negatives; RMS adaptation also cannot distinguish a loud fan from speech. Acceptance: room noise, keyboard noise, TV/music, quiet single words, trailing syllables and code-switching; count false rejections as well as hallucinations.

## E04 — Add recognition-time vocabulary and optional pronunciation enrollment

[MacParakeet's rescoring implementation](https://github.com/moona3k/macparakeet/blob/590b6c253bd27bc55723f0e8c8394b64467c09de/Sources/MacParakeetCore/STT/CustomVocabularyBoosting.swift#L5-L18) explicitly bounds sidecar audio and cached vocabularies. [FluidVoice's acoustic evidence](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/DictionaryLearningEvidence.swift#L1-L110) links a correction to a specific original word/audio occurrence and gives the recording a short lifetime. Its [pronunciation decision policy](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/DictionaryPronunciationDecision.swift#L1-L53) varies acceptance for known text variants and preserves possessives.

Parla already supplies dictionary text to Whisper and cleanup (`Pipeline.swift:37,72`) and suggests manually observed corrections (`DictionaryLearner.swift`). The additional feature is acoustic enrollment/recognizer rescoring, not 'add a dictionary.' **L–XL**, after E01. Begin with explicit training of a few troublesome names. Against: false substitutions of common words, model-specific embeddings and additional audio retention. Do not retain ordinary successful recordings by default just to train this. Acceptance: trained names plus unrelated near-sounding words, repeated occurrences, possessives, undo, model upgrade and profile deletion.

## E05 — Study confidence-gated dictionary repair; keep it optional

[Murmure's production dictionary correction](https://github.com/Kieirra/murmure/blob/2218c1bab463d17ace34258a3842b9f230d60ca3/src-tauri/src/dictionary/dictionary.rs#L11-L147) protects short words, skips confident recognizer words, disables fuzzy matching for large dictionaries, leaves ties alone and can repair split words. Parla currently has prompt bias plus correction suggestions, rather than per-word confidence output (`WhisperTranscriber.transcribe` returns only a string).

Useful future seam: retain word confidences/timings and offer exact spelling restoration before fuzzy matching. **M for exact restoration; L for calibrated confidence repair.** Against: scores are not necessarily comparable across engines; a threshold copied from another model can silently change correct words. Acceptance: negative examples dominate the test corpus; record false substitutions separately from recovered names. This is an experiment, not a default recommendation to rewrite near matches.

## E06 — Resume interrupted model downloads without weakening integrity

[FluidVoice's compact model transport](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Networking/CompactSpeechModelArchiveTransport.swift#L60-L175) persists partial archives, ties them to a release hash, requests byte ranges and checks response ranges before append. Parla's `download(_:)` (`Sources/Parla/ModelInstaller.swift:15–55`) uses a new URLSession download and already verifies exact bytes/hash and installs atomically (`ModelCatalog.install`). No app-level persisted resume path appears in this function.

**M.** Add pause/retry resume for weak connections, retaining full final SHA-256 verification. Against: three models and infrequent downloads may not justify a custom chunking stack; URLSession resume data is a simpler first implementation to investigate. Acceptance: app restart, server ignoring Range, changed release, truncated chunk, canceled install and preservation of the previously usable model.

## E07 — Separate model preparation phases and enforce capability-aware availability

[FluidVoice's progress phases](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/TranscriptionProvider.swift#L3-L25) distinguish download, optimize and load. Its [installation snapshot](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/SpeechModelInstallationSnapshot.swift#L7-L126) uses event-triggered checks, one active worker and one latest pending request. MacParakeet's `SpeechEngineCapabilities` includes minimum memory and removable-model metadata.

Parla already verifies installed model identity with a cached size/mtime verdict (`ModelCatalog.swift:173`) and frees the model after idle (`Transcriber.swift:216`). Preserve both. Add explicit preparing/compiling/loading states if a CoreML backend lands. **S–M, dependent on E01.** Against: current single-file Whisper models do not need the whole machinery. Acceptance: a stale preparation cannot select an old model; delete/switch while loading remains safe; no model scanning on every progress tick.

## E08 — Provide in-process Apple Intelligence cleanup where eligible

[MacParakeet's local client](https://github.com/moona3k/macparakeet/blob/590b6c253bd27bc55723f0e8c8394b64467c09de/Sources/MacParakeetCore/Services/LLM/AppleIntelligenceLLMClient.swift#L6-L126) injects a generator, checks availability per request and discards a result returned after cancellation. Its [availability model](https://github.com/moona3k/macparakeet/blob/590b6c253bd27bc55723f0e8c8394b64467c09de/Sources/MacParakeetCore/Services/LLM/AppleIntelligenceAvailability.swift#L1-L86) distinguishes unsupported hardware/OS, disabled service, preparing assets and language limitations.

Parla already supports local Ollama/LM Studio through the OpenAI-compatible adapter (`OpenAICompatClient.swift:4`, `CleanupFactory.swift:63`). The gap is a keyless in-process system option, not 'local cleanup.' **M–L.** Against: eligibility/language restrictions and rewrite quality; system models may refuse some content or have a smaller usable context. Keep the current raw fallback and sanitizer. Acceptance: disabled/missing system model, long prompts, refusal, non-English dictation, cancel and no external request from this adapter.

## W01 — Make saved vocabulary portable without exporting credentials

[MacParakeet's versioned bundle](https://github.com/moona3k/macparakeet/blob/590b6c253bd27bc55723f0e8c8394b64467c09de/Sources/MacParakeetCore/Models/VocabularyBundle.swift#L1-L67) exports words, replacements and snippets; its [import service](https://github.com/moona3k/macparakeet/blob/590b6c253bd27bc55723f0e8c8394b64467c09de/Sources/MacParakeetCore/Services/VocabularyImportExportService.swift#L61-L91) previews conflicts and removals. [FluidVoice's transfer decoder](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/DictionaryTransferService.swift#L3-L78) accepts aliases and multiple spoken variants.

Parla exposes dictionary and snippets in the Hub and persists them in `Settings`, but its settings file also contains API keys (`Settings.swift:25–37`); copying the complete file is a poor migration surface. **M.** Export only a versioned vocabulary document; preview merge/replace before import. Against: a one-way JSON export and merge may be enough initially; no need for account sync. Acceptance: case-folded duplicates, Unicode, invalid version, empty destructive import, unchanged keys and a backup before replace.

## W02 — Let history retry cleanup and recover failed audio

Parla's `HistoryEntry` already keeps raw and cleaned text (`History.swift:28–40`), while `HistoryPage` has search/copy/clear (`HubPages.swift:539–641`). `RecordingStore` stashes audio before ASR and normally deletes it once a transcript exists (`RecordingStore.swift:75–96`); failed recordings can be revealed in Finder. Android already has retry-cleanup and use-original actions, so this is principally desktop product parity.

[Whispering's run model](https://github.com/EpicenterHQ/epicenter/blob/7cc869b4a1295e2566b61e1a4d5967a89f413b9b/apps/whispering/src/lib/runs.svelte.ts#L1-L141) distinguishes received-but-unsaved answers and retries storage without sending another provider request. [MacParakeet's recovery service](https://github.com/moona3k/macparakeet/blob/590b6c253bd27bc55723f0e8c8394b64467c09de/Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift#L130-L222) offers only viable recovery candidates and excludes active writers.

**M.** Add 'Copy original', 'Retry cleanup' and a failed-recording list with replay/transcribe/delete. Retry uses an immutable snapshot of the chosen text/settings and never auto-pastes into a later target. Against: storage and retention should stay small; successful-audio re-transcription requires new opt-in retention and should not be conflated with crash recovery. Acceptance: history off, failed write, expired audio, provider failure, changed selection and duplicate retry. An unavailable audio file gets a clear reason.

## W03 — Import audio/video with a durable, cancelable queue

[Vibe's queue](https://github.com/thewh1teagle/vibe/blob/2ea5ecef989933282fca517d82d4e3128ae5fb0b/desktop/src/pages/main/hooks/use-transcribe-queue.ts#L34-L136) represents queued/running/done/error/canceled jobs, persisted transcripts, per-file progress and batch summaries. [FluidVoice's file pipeline](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/FileTranscriptionService.swift#L7-L98) has speaker-attributed segments and explicit coverage gaps.

Parla's product flow records live microphone audio and `parla-eval` reads fixtures; neither is a user file-import workflow. **L**, after a bounded audio decoder and chunk policy. Start with one dropped audio file, then batch. Against: media decoding, long jobs and persistence grow a small dictation utility into a transcription workspace. Acceptance: unsupported codec, missing file, disk full, cancellation, restart, mixed successes and no automatic insertion of a file transcript into the frontmost app.

## W04 — Add export formats only after preserving structured segments

[Vibe's serializer](https://github.com/thewh1teagle/vibe/blob/2ea5ecef989933282fca517d82d4e3128ae5fb0b/desktop/src/lib/transcript-export.ts#L1-L169) exports text/Markdown, SRT/VTT, HTML and JSON, with speaker names, timestamp options and RTL handling. Its server [gates diarization](https://github.com/thewh1teagle/vibe/blob/2ea5ecef989933282fca517d82d4e3128ae5fb0b/server/crates/vibe-server/src/server/diarization.rs#L1-L26) behind a compiled feature and returns no speaker labels if unavailable.

Parla's `WhisperTranscriber` concatenates segment text into one string (`Transcriber.swift:160–169`), and history stores strings. Text/Markdown export is **S**; timestamped subtitles/diarized export is **L** with W03. Against: inventing timestamps from a cleaned paragraph is inaccurate; do not pretend a plain dictation string is subtitle-ready. Acceptance: overlapping speakers, missing timestamp data, `-->` inside text, Unicode/RTL, empty summary and correct time units.

## W05 — Treat meetings as a separate product bet

[FluidVoice's capture engine](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift#L78-L176) owns distinct capture paths, microphone tracks and echo-protection metadata. Its [chunk ledger](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/Meeting/MeetingAudioChunkLedger.swift#L65-L113) checkpoints durable writer facts. MacParakeet's recovery pipeline can salvage available source tracks rather than requiring one perfect mixed file.

Parla has bounded single-mic dictation (`AudioRecorder.maxSamples`, 10 minutes) and crash stashing; no meeting system-audio pipeline was found in `Sources`. **XL**: explicit meeting start, mic/system separation, durable chunks, source/timing metadata, playback and optional summaries. Against: capture permissions, echo, storage, diarization, interruptions and platform support outweigh 'add a meeting button.' Start with file import unless demand is strong. Acceptance: app crash mid-call, silent source, missing system permission, headphones/speakers, call-app changes, source drift and honest partial transcripts. Do not copy experimental AEC paths as production defaults.

## W06 — Add Apple Shortcuts before a network API

[Muesli's App Shortcuts](https://github.com/Muesli-HQ/muesli/blob/6c223cd4b3ac7ea1332ddc9e49463f01fd97140c/native/MuesliNative/Sources/MuesliNativeAppShell/AppIntents/MuesliAppShortcuts.swift#L1-L43) expose start/stop dictation and get-last-result. [Its start intent](https://github.com/Muesli-HQ/muesli/blob/6c223cd4b3ac7ea1332ddc9e49463f01fd97140c/native/MuesliNative/Sources/MuesliNativeAppShell/AppIntents/StartDictationIntent.swift#L1-L17) waits for an in-process controller after app launch. [FluidVoice's local API config](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/LocalAPI/LocalAPIModels.swift#L3-L23) is disabled by default.

Parla has global hotkeys and internal eval/insertion executables; Linux has `parlactl`, but no macOS AppIntent surface was found. **M** for start/stop/cancel/copy-last with existing session guards. Against: launching the app may change focus; intents must preserve the target or only return text. A localhost server adds lifecycle and access-control complexity and is **deferred** until an integration requires it. Acceptance: cold launch, already recording, no permission/model, duplicate start, secure target and a canceled session returning late.

## P01 — Store macOS provider credentials in Keychain

[VoiceInk's credential service](https://github.com/Beingpax/VoiceInk/blob/1027ea3c25e329cd42e7bbe18c746224ad664f7b/VoiceInk/Infrastructure/Credentials/KeychainService.swift#L5-L96) uses distinct namespaces for distributed and local builds and handles update/add races. Parla's `Settings` includes raw key fields (`Settings.swift:3–12,31`) and `SettingsStore.save` serializes the whole settings object (`Settings.swift:164–169`). Android already uses endpoint-scoped Android Keystore (`android/.../core/SettingsStore.kt:125`).

**M.** Move desktop keys into endpoint/provider-scoped Keychain records with a one-time migration; keep ordinary settings export key-free. Against: source build signing and user-denied Keychain access need careful behavior; a key read failure must not overwrite a valid existing key with blank. Acceptance: migrate/relaunch, blank key preserves current, explicit remove, endpoint switch and unreadable Keychain. This source finding does not establish a credential leak in any deployed installation.

## P02 — Expose Android speech recognition through the platform service contract

[Sayboard's RecognitionService](https://github.com/ElishaAz/Sayboard/blob/0f1ee1845a9f26f3bad82493e8cfdf849b4039f3/app/src/main/java/com/elishaazaria/sayboard/services/SayboardRecognitionService.kt#L18-L107) reads requested language, forwards attribution and maps engine state/errors to Android callbacks. Parla already has a voice IME and Android 13+ accessibility input connection; `android/app/src/main/AndroidManifest.xml` and `input/` contain no equivalent speech-recognition service.

**L qualification spike.** A selectable recognition service can integrate with clients that use the standard speech API, while keeping IME/floating delivery. Against: clients/keyboards may hardcode another recognizer, so it cannot promise support for every microphone button. Sayboard uses Vosk; its service contract is the lesson, not proof Vosk should replace Whisper. Acceptance: API client specifying language/service, permission attribution, cancel/stop semantics, no duplicate final result and manufacturer settings availability.

## P03 — Give Android multilingual model choices and an optional alternative engine

[Dictus Android's SttProvider](https://github.com/getdictus/dictus-android/blob/6c2eafa0a14d1a97a8d43d10d81d7055f5096bd2/core/src/main/java/dev/pivisolutions/dictus/core/stt/SttProvider.kt) is implemented by [its Parakeet adapter](https://github.com/getdictus/dictus-android/blob/6c2eafa0a14d1a97a8d43d10d81d7055f5096bd2/asr/src/main/java/dev/pivisolutions/dictus/asr/ParakeetProvider.kt#L26-L151), with per-model language constraints, serialized native calls and protection against loading another model while an abandoned native call still owns memory.

Parla's Android `WhisperEngine.transcribe` explicitly requires English (`WhisperEngine.kt:17–20`); its pinned model is tiny.en (`ModelStore.kt:138`). **M–L** for verified multilingual Whisper choices; **L–XL** for an ONNX adapter after physical-device qualification. Against: larger models can be unsuitable on low-memory phones, and cancellation of an await does not terminate arbitrary JNI work. Acceptance: English/Hindi/code-switching recordings, low memory, phone interruptions, native abort, no second model allocation under an unfinished decode and no implied language/layout coupling.

## P04 — Scope iOS as host-app transcription plus a lightweight keyboard

[Dictus's audio engine](https://github.com/getdictus/dictus-ios/blob/0fd7badf47e1f98f3e3757dc84a2b1d4720d9ed8/DictusApp/Audio/UnifiedAudioEngine.swift#L104-L117) runs in the host app; its keyboard [uses the current text proxy](https://github.com/getdictus/dictus-ios/blob/0fd7badf47e1f98f3e3757dc84a2b1d4720d9ed8/DictusKeyboard/DictusKeyboardBridge.swift#L17-L44). [The generation policy](https://github.com/getdictus/dictus-ios/blob/0fd7badf47e1f98f3e3757dc84a2b1d4720d9ed8/DictusCore/Sources/DictusCore/DictationSessionGeneration.swift#L6-L84) invalidates work on both supersession and abandonment.

No iOS target exists in the current project; Android code is not an iOS keyboard implementation. **XL separate feasibility/product initiative.** The useful pattern is cross-process ownership and small extension memory, not assuming microphone access works inside an extension. Against: cold-start handoff, host background liveness, keyboard termination and returning to the original app are major UX constraints. Competitor source comments and issue reports are not proof every lifecycle case is solved. Acceptance on physical devices: host killed/suspended, keyboard replaced, new field, locked device, background interruption and no stale/duplicate insertion. Full keyboard typing/autocorrect is an additional product scope, not a prerequisite for a voice panel.

## Q01 — Measure formatting independently from normalized words

`Eval.normalize` collapses all whitespace (`Sources/ParlaCore/Eval.swift:5–7`), and `summarize` uses it for zero-edit equality (`Sources/parla-eval/main.swift:178`). `werTokens` additionally removes most punctuation. Therefore those metrics cannot distinguish equal-word email text with different paragraph breaks. They remain useful word metrics; this is not a claim they should be deleted. Independent review confirmed the paragraph-only blind spot and found counterevidence against a broader claim: zero-edit/compare preserve punctuation and case, and unit tests protect layout policy/delivery. See [baseline audit](01-current-baseline.md#follow-up-refutation-precise-metric-distinctions).

**S–M.** Add structure-sensitive exact output, newline/paragraph and protected-identifier checks alongside existing WER. Include email greetings/signoffs, lists, terminal single-line output, numbers/currencies, URLs and Unicode. Against: multiple valid formats can make exact-match goldens brittle; use semantic/structure constraints plus reviewed acceptable variants. Acceptance: removing email blank lines fails the formatting metric while WER remains unchanged; changing code punctuation fails a protected-token check.

## Q02 — Expand the real human corpus before choosing defaults

The current tree has **9 WAVs, 7 paired `.raw.txt` audio references, 32 goldens and 39 committed result rows**. The seven `syn-*` cases are generated by `scripts/make-asr-corpus.sh:1–16`; that script explicitly says they are regression fixtures, not real-world accuracy evidence. The two remaining audio cases have no paired raw reference. `RecordingStore` already has opt-in corpus collection and correctly writes hypotheses as `.hyp.txt`, not human `.raw.txt` (`RecordingStore.swift:19–23,92-L96`).

**M collection/tooling, ongoing curation.** Recruit/record a consented human set covering accents, code-switching, names, numerals, silence, real microphones and lengths; score ASR and cleanup separately. Pair engine comparisons by recording and keep speakers separate between development/holdout sets. Against: more fixtures alone do not remove subjective cleanup preferences; avoid publishing a single pooled WER as the product experience. Acceptance: every scored ASR case has a human-checked reference; cohort counts and failures are shown; no TTS result becomes a user-facing accuracy claim.

## Q03 — Build a locally inspectable stage-level diagnostic export

Parla already has monotonic phase tracing (`Trace.swift:15–28`) and persisted token/timing fields (`History.swift:11–21`). [FluidVoice's ASR result](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/TranscriptionProvider.swift#L105-L129) carefully separates model processing time from queue/setup overhead; [its PCM-readiness gate](https://github.com/altic-dev/FluidVoice/blob/6150956bef129fc1a413684db4c0eac61da078a5/Sources/Fluid/Services/AudioCaptureReadinessGate.swift#L29-L121) gives first-buffer arrival an explicit deadline.

**M.** Expose a manual export of model/app version, audio route, engine lifecycle, stage timings and delivery outcome; exclude text/audio/keys by default. Audit metric semantics against the current clean-before-paste flow before presenting charts. Against: existing tracing may suffice for a developer; do not add telemetry infrastructure to solve a support-export problem. Acceptance: source-independent diagnostic inspection, stale generation identified, first-PCM timeout distinguished from no speech, and no provider secret/raw transcript in the exported default payload.

## Things checked that are already sound

- Model choices and multilingual desktop decoding already exist; the gap is alternative families and Android language breadth.
- Warm mic/pre-roll, route-change handling, reused resampling and idle model unload exist. Do not re-add the August tasks.
- Local-server cleanup is already possible; Apple Intelligence would be a different setup experience.
- Whole-utterance snippets already bypass cleanup. Embedded-trigger behavior is deliberately constrained to avoid accidental expansion.
- Crash audio recovery already has a bounded stash. A recovery UI and user-requested replay are distinct from its storage mechanism.
- API retry is not the same as retrying a local save; Whispering's distinction is worth retaining.
- Meeting capture/AEC/diarization source can include optional or pre-production paths; a file existing does not prove signed-release or runtime qualification.
- No model speed/quality multiplier from the older research was accepted without a comparable measurement.
