# Which open-source Wispr Flow alternatives support NVIDIA Parakeet TDT v2 — and what to know about the model

## 1. Short answer

**Almost nobody ships v2 as their primary model anymore.** v2 (English-only, May 2025) was superseded by v3 (25 European languages, Sept 2025), and the ecosystem moved: of ~39 audited repos with real Parakeet support, **all 16 "default" apps default to v3 or a v3-derived GGUF** — not one defaults to v2. v2 survives as a *selectable English-only alternate*, kept because it is still marginally better on English (6.05 vs 6.32 avg WER) and never auto-detects the wrong language.

Apps that actually ship v2 today, ranked by how first-class that v2 support is:

| # | Repo | Why it ranks here |
|---|---|---|
| 1 | **[Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)** | `parakeet-tdt-0.6b-v2` is a full catalog entry ("Parakeet V2", 474 MB) in `VoiceInk/Transcription/FluidAudio/FluidAudioModelManager.swift` `modelVersionMap`, no experimental badge, one-click download. App defaults to v3. |
| 2 | **[cjpais/Handy](https://github.com/cjpais/Handy)** | Two v2 paths: ONNX int8 (`src-tauri/src/managers/model.rs`, `EngineType::Parakeet`) and `parakeet-tdt-0.6b-v2-gguf` in `src-tauri/src/catalog/catalog.json`. Parakeet is the headline engine; v3/unified are the recommended picks. |
| 3 | **[altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice)** | `.parakeetTDTv2` is a first-class `SpeechModel` case; `FluidAudioProvider.swift:55` selects `.v2` vs `.v3`. Default is v3 on Apple Silicon. |
| 4 | **[AbhishekBarali/SpeakoFlow](https://github.com/AbhishekBarali/SpeakoFlow)** | v2 present twice — legacy int8 ONNX dir (`model.rs:412-480`) and GGUF catalog. Default is `parakeet-unified-en-0.6b-gguf`. |
| 5 | **[Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli)** | `parakeetEnglish` = `FluidInference/parakeet-tdt-0.6b-v2-coreml` in `Models.swift:13-29`; CLI exposes `parakeet-v2`. Default alias points at v3. |
| 6 | **[moona3k/macparakeet](https://github.com/moona3k/macparakeet)** | `ParakeetModelVariant.v2` → `AsrModelVersion.v2`, documented as "English-only opt-in". Default is v3. |
| 7 | **[hoomanaskari/mac-dictate-anywhere](https://github.com/hoomanaskari/mac-dictate-anywhere)** | `.englishOnly` → `.v2` in `TranscriptionEngine.swift:142-149`. Default `.multilingual` (v3). |
| 8 | **[peteonrails/voxtype](https://github.com/peteonrails/voxtype)** | Built-in downloader carries `parakeet-tdt-0.6b-v2` **and** `v2-int8`. Config default is v3; engine default is Whisper. |
| 9 | **[watzon/pindrop](https://github.com/watzon/pindrop)** | `ModelManager.swift:508-538` marks v2 `.available` and selectable. Default model is `openai_whisper-base`. |
| 10 | **[Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper)** | Settings picker offers v2 (464 MB, "English-only, higher recall") vs v3; `LanguageUtil` gates v2 to `["en"]`. Default engine is Whisper. |
| 11 | **[TypeWhisper/typewhisper-mac](https://github.com/TypeWhisper/typewhisper-mac)** | `ParakeetPlugin.swift:840-867` `enum ParakeetVersion { v2, v3 }`, user-selectable; v2 reports `supportedLanguages == ["en"]`. Plugin defaults to v3; app headlines WhisperKit. |
| 12 | **[moinulmoin/voicetypr](https://github.com/moinulmoin/voicetypr)** | `src-tauri/src/parakeet/models.rs` ships v2 with `apple_silicon_only: true` ("V2 CoreML model crashes on Intel Macs — SIGFPE in Espresso"). |
| 13 | **[mrkvn/muni](https://github.com/mrkvn/muni)** | Genuinely loads v2 (`AsrModels.downloadAndLoad(version: .v2)` in the ANE sidecar) — but gated behind `MUNI_ASR_BACKEND=parakeet`, no bundled binary, undocumented. Dev-only. |
| 14 | **[chidiwilliams/buzz](https://github.com/chidiwilliams/buzz)** | Accepts *any* HF repo id matching `parakeet`, so v2 loads — but the code is unreleased (latest tag v1.4.4 has zero Parakeet code), there is no Parakeet entry in `ModelType`, and only v3 is tested. |

If you just want v2 running with the least friction: **VoiceInk** (macOS) or **Handy** (macOS/Windows/Linux). If you don't specifically need English-only determinism, take v3 — every one of these apps defaults to it for good reason.

---

## 2. Full support table (audited repos)

| Repo | Support | Variant | Runtime backend | Platforms | Evidence |
|---|---|---|---|---|---|
| [cjpais/Handy](https://github.com/cjpais/Handy) | **default** | v2 + v3 (int8 ONNX); ~13 GGUF Parakeet variants incl. `parakeet-unified-en-0.6b` (rank 1) | transcribe-rs 0.3.8 (ONNX/ort) + transcribe-cpp 0.1.3 (GGUF) | macOS Intel+AS, Win x64/aarch64, Linux x64 — **CPU-only** | `src-tauri/src/managers/model.rs:750-779`; `transcription.rs:613-621`; `catalog/catalog.json` first entry |
| [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) | **default** | v3 (default), v2, `parakeet_realtime_eou_120m-v1` | FluidAudio fork (CoreML/ANE), `Package.swift:13` branch `B/cohere-coreml-asr` | macOS Apple Silicon (Intel → Whisper) | `SettingsStore.swift:4341-4343` `isAppleSilicon ? .parakeetTDT : .whisperBase` |
| [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) | **default** | v3 (default/onboarding), v2, `parakeet-unified-0.6b` | FluidAudio (CoreML), pinned rev `88d6d81` | macOS 14.4+ | `StarterModeFactory.swift:5` `defaultTranscriptionModelName = "parakeet-tdt-0.6b-v3"` |
| [Kieirra/murmure](https://github.com/Kieirra/murmure) | **default** | v3 int8 only (SmoothQuant encoder from Olicorne) | Rust `ort` 2.0.0-rc.10, hand-written TDT greedy decoder | macOS x64/arm64, Win x64, Linux (AppImage/deb/rpm) | `src-tauri/src/model/model.rs:6`; `engine/engine.rs` — **only** transcription path |
| [Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli) | **default** | v3 (recommended), v2, Parakeet Realtime EOU 320ms | FluidAudio exact 0.15.1 (CoreML/ANE) | macOS 14.2+ Apple Silicon | `Models.swift:113` `static let whisper = parakeetMultilingual` |
| [moona3k/macparakeet](https://github.com/moona3k/macparakeet) | **default** | v3 (default), v2, `parakeet-unified-en-0.6b` | FluidAudio exact 0.15.4 | macOS 14.2+, M1+ | `SpeechEnginePreference.swift` `defaultParakeetModelVariant = .v3`; locale check can start CJK users on WhisperKit |
| [Gremble-io/Detto](https://github.com/Gremble-io/Detto) | **default** | v3 (sole ASR engine linked) | FluidAudio 0.14.2 via first-party `GrembleVoiceParakeet` | macOS **26+**, Apple Silicon only | `Package.swift` links only `GrembleVoiceParakeet`; `DictationController.swift:52-53` hardcodes `asrEngine: .parakeet` |
| [notune/android_transcribe_app](https://github.com/notune/android_transcribe_app) | **default** | v3 GGUF Q4_K_M, bundled + SHA-256 pinned | transcribe-cpp 0.1.3 (ggml) via JNI cdylib | **Android arm64-v8a only**, minSdk 26, no INTERNET permission | `app/build.gradle.kts:165-174`; `src/engine.rs:65` |
| [DictionLabs/Diction](https://github.com/DictionLabs/Diction) | **default** | v3 INT8 (`dictionlabs/parakeet:latest-int8`, 651.9 MiB) | Self-hosted Docker, OpenAI-compatible `:5092`; Go gateway proxies | Linux/Docker + NVIDIA GPU (server); iOS 17+ client | `gateway/core/backends.go` DefaultBackends; README Step 1 compose |
| [Whamp/chirp-stt](https://github.com/Whamp/chirp-stt) | **default** | v3 (`istupakov/parakeet-tdt-0.6b-v3-onnx`), int8 | onnx-asr, forced `CPUExecutionProvider` | Windows only, CPU-only | `src/chirp/setup.py` REPO_MAP; `parakeet_manager.py` — sole engine |
| [AbhishekBarali/SpeakoFlow](https://github.com/AbhishekBarali/SpeakoFlow) | **default** | `parakeet-unified-en-0.6b` (default) + v2/v3 ONNX + 8 more GGUF Parakeets | transcribe-rs 0.3.11 (ONNX) + transcribe-cpp 0.1.2 (GGUF) | Win x64/aarch64, macOS AS+Intel, Linux | `model.rs:81` `RECOMMENDED_MODEL_ID`; `settings.rs:1290-1294` |
| [saurabhav88/EnviousWispr](https://github.com/saurabhav88/EnviousWispr) | **default** | v3 CoreML int8, pinned rev `aed0274` | FluidAudio (own mirror fork) + Cloudflare R2 model mirror | macOS 14+, Apple Silicon | `SettingsDefaultValues.swift:13` `selectedBackend = .parakeet` |
| [hoomanaskari/mac-dictate-anywhere](https://github.com/hoomanaskari/mac-dictate-anywhere) | **default** | v3 (default), v2, `parakeet-tdt-ctc-110m`, EOU streaming 320ms | FluidAudio 0.15.5 (CoreML) | macOS 14+, **universal** (Parakeet is not ANE-gated) | `Settings.swift:1093-1094`; `TranscriptionEngine.swift:142-149,702` |
| [sebsto/wispr](https://github.com/sebsto/wispr) | **default** | v3 CoreML + Parakeet Realtime EOU 120M/160ms | FluidAudio 0.15.5, `StreamingEouAsrManager`, `.cpuAndNeuralEngine` | macOS **26+** only | `OnboardingModelSelectionStep.swift:138` forces `KnownID.parakeetV3`, non-skippable |
| [tristanmuzzu/parakeet-dictation](https://github.com/tristanmuzzu/parakeet-dictation) | **default** | v3, int8 with fp32 fallback | onnx-asr (ONNX Runtime CPU) | Windows 10/11 x64 only | `dictation.py:48` `MODEL_NAME`; `:535-539` |
| [homelab-00/TranscriptionSuite](https://github.com/homelab-00/TranscriptionSuite) | **default** | v3 — `nvidia/…` (NeMo) and `mlx-community/…` (MLX) | NeMo/CUDA **or** parakeet-mlx/Metal | Linux+Win via Docker+NVIDIA GPU; macOS AS native. **Not** on CPU/Vulkan runtimes, **not** in Live Mode | `modelSelection.ts` `MAIN_RECOMMENDED_MODEL`; `instanceMatrix.ts` `defaultMainModelFor` |
| [thewh1teagle/vibe](https://github.com/thewh1teagle/vibe) | supported | v3 GGUF (`vibe-app/parakeet-tdt-0.6b-v3-gguf`) | Sona sidecar v0.3.5 → `parakeet-rs` (GGML) | macOS arm64/x64, Linux x64/arm64, Win x64 | `docs/models.md:40-45`; `.sona-version`; release v3.0.22. Default is whisper-large-v3-turbo |
| [OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr) | supported | v3, `parakeet-unified-en-0.6b` (+2 Nemotron streaming) | **sherpa-onnx 1.13.4** bundled WS server binaries | macOS arm64/x64, Win x64, Linux x64 | `scripts/download-sherpa-onnx.js:13`; `parakeetServer.js:86`. Default provider `whisper` |
| [EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter) | supported | v3 — GGUF on main, int8 ONNX at v7.x | transcribe-cpp 0.1.0 (main) / transcribe-rs 0.2.1 (v7.x) | macOS Metal, Win x64 Vulkan + aarch64, Linux Vulkan | `apps/epicenter/src-tauri/src/transcription/catalog.rs`, `recommended: false`. Was the **only** local engine on Windows at v7.5+ |
| [matthartman/ghost-pepper](https://github.com/matthartman/ghost-pepper) | supported | v3 | FluidAudio ≥0.13.6 (CoreML) | macOS 14+ | `SpeechModelCatalog.swift:97-105`; default is `whisperSmallEnglish` |
| [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) | supported | **v3 + v2** CoreML | FluidAudio 0.15.4 | macOS Apple Silicon only | `FluidAudioEngine.swift`; `AppPreferences.swift:38` defaults `selectedEngine = "whisper"` |
| [TypeWhisper/typewhisper-mac](https://github.com/TypeWhisper/typewhisper-mac) | supported | **v3 + v2** (plugin `com.typewhisper.parakeet`) | FluidAudio exact 0.15.5 | macOS 14+, **arm64 only** (plugin manifest) | `ParakeetPlugin.swift:4,59,608,642-644`; one of 11 engines |
| [moinulmoin/voicetypr](https://github.com/moinulmoin/voicetypr) | supported | **v3 + v2** CoreML | FluidAudio ≥0.15.2 via bundled Swift `ParakeetSidecar` | macOS 14+ **Apple Silicon only**; Win/Intel → Whisper | `src-tauri/src/parakeet/models.rs`; `tauri.macos.conf.json` externalBin |
| [watzon/pindrop](https://github.com/watzon/pindrop) | supported | **v2 + v3** available; 1.1b `.comingSoon` | FluidAudio exact 0.15.4 | macOS 14+ | `ParakeetEngine.swift`; **trap:** the `.parakeet` streaming enum case actually instantiates `NemotronStreamingEngine` |
| [goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr) | supported | v3 (`nemo-parakeet-tdt-0.6b-v3`), int8 default | **onnx-asr** (`onnx-asr[cpu,hub]` / `[cuda,hub]`) + Silero VAD | **Linux only** (Wayland/Hyprland); CPU, NVIDIA GPU auto-detected | `lib/src/backends/onnx_asr_backend.py:24-27`; default backend is `pywhispercpp`, but `setup` pre-selects onnx-asr as option 1 |
| [peteonrails/voxtype](https://github.com/peteonrails/voxtype) | supported | **v2, v2-int8, v3, v3-int8, parakeet-unified-en-0.6b** | `parakeet-rs` 0.3.5 over `ort` 2.0.0-rc.12 | Linux x86_64 (avx2/avx512/CUDA/MIGraphX) + aarch64; macOS Apple Silicon | `src/config/engines/parakeet.rs`; `engines/mod.rs:41-44` marks Whisper `#[default]` |
| [better-slop/hyprwhspr-rs](https://github.com/better-slop/hyprwhspr-rs) | supported | v3 ONNX (`istupakov/parakeet-tdt-0.6b-v3-onnx`) | `parakeet-rs` 0.3.4 → `ort` 2.0.0-rc.12 | **Linux only**, Hyprland/Wayland, **glibc only** (musl dropped) | `src/config.rs:504-506`; `src/transcription/parakeet.rs:5`. Default provider `whisper_cpp` |
| [daniel-carreon/sflow](https://github.com/daniel-carreon/sflow) | supported | v3 (`mlx-community/parakeet-tdt-0.6b-v3`) | **parakeet-mlx** ≥0.3.0 | macOS Apple Silicon (Intel → Groq fallback) | `core/transcriber_parakeet.py`; default is `whisper-turbo-local`. **Repo is frozen** — successor is `sflow-next` |
| [voquill/voquill](https://github.com/voquill/voquill) | partial | v3 ONNX — but only as a model *ID* | External **Speaches** container; Voquill's own engine is whisper.cpp | Anywhere you run the Speaches container; picklist is enterprise-admin-only | `enterprise/admin/src/utils/provider-models.utils.ts`; issue #9 closed: "didn't seem to work very well" |
| [kstonekuan/tambourine-voice](https://github.com/kstonekuan/tambourine-voice) | partial | **Not Parakeet TDT** — upstream serves `nvidia/nemotron-speech-streaming-en-0.6b` | NeMo on a separate CUDA WebSocket server | Client Win/macOS/Linux; server needs NVIDIA GPU | `server/services/nvidia_stt.py` calls the peer a "Parakeet ASR server" in comments only |
| [heardlabs/heard](https://github.com/heardlabs/heard) | partial | v3 via `mlx-community/parakeet-tdt-0.6b-v3` | parakeet-mlx (MLX/Metal) — inside the **closed-source** `heard_power` subprocess | macOS 13+, Apple Silicon; **paid Power plan only** | `THIRD-PARTY-NOTICES.md:15-23`; OSS build has `voice_service_cmd = ""` → no STT at all |
| [mrkvn/muni](https://github.com/mrkvn/muni) | partial | **v2** (ANE), model-agnostic ONNX path | parakeet-rs 0.3.5 (ort rc12) **or** FluidAudio 0.14.8 (ANE) | macOS 14+ Apple Silicon | `parakeet-ane-sidecar/…/main.swift`; requires `MUNI_ASR_BACKEND=parakeet`, no bundled sidecar binary |
| [chidiwilliams/buzz](https://github.com/chidiwilliams/buzz) | partial | any `parakeet*` HF id (v2 or v3); only v3 tested | HF Transformers 5.x `AutoModelForTDT/RNNT/CTC` on torch | Linux/Win/macOS AS. **Intel macOS excluded** (pinned transformers <5) | `buzz/transformers_whisper.py` `_transcribe_parakeet`. **Unreleased** — v1.4.4 has zero Parakeet code; HF autocomplete filters `filter=whisper` so it's undiscoverable |
| [amicalhq/amical](https://github.com/amicalhq/amical) | planned | v3 int8 ONNX in **open PR #123** | onnxruntime-node (proposed) | none shipped | PR #123 OPEN, `REVIEW_REQUIRED`, `feat/parakeet-tdt-only`; main has no `parakeet-provider.ts` |
| [digimata/parrot](https://github.com/digimata/parrot) | planned | v3 named in docs/.plan M7 and open PR #28 | undecided (FluidAudio vs CoreML); PR #28 proposes a Docker HTTP service | none | `ModelRegistry.swift` is 3 WhisperKit models; `docs/architecture.md:98` |
| [mkiol/dsnote](https://github.com/mkiol/dsnote) | planned | v2 requested (issue #287), v3 in follow-up | none — engines are DeepSpeech/Vosk/April/whisper.cpp/faster-whisper | none (Linux + Sailfish app) | Issue #287 open since 2025-07-02; maintainer: "I will investigate what can be done" |
| [VocaHQ/vocalinux](https://github.com/VocaHQ/vocalinux) | planned | unspecified | proposed via whisper.cpp `parakeet-cli`; blocked on pywhispercpp#171 | none (Linux only) | Issue #527 open; `recognition_manager.py:1012-1018` is a 4-way vosk/whisper/whisper_cpp/remote_api branch |
| [gurjar1/OmniDictate](https://github.com/gurjar1/OmniDictate) | planned | v3 + `parakeet-unified-en-0.6b` named in research doc | none — ships faster-whisper | none (Windows only) | `docs/research/STT_MODEL_RESEARCH_2026.md:162-174`; `core_logic.py:61-84` has no Parakeet branch |
| [drajb/whisper-local](https://github.com/drajb/whisper-local) | planned | v3/v2 named in a research doc; roadmap user story | none — faster-whisper + whisper.cpp | none (Win + macOS) | `docs/roadmap/roadmap.md:99`; zero `parakeet` hits under `src/` |

### Secondary table — ~40 apps found outside the audit (README/source-level check only, **not** file-verified to the same standard)

| Repo | ★ | Platform | Support | Runtime | Variant |
|---|---|---|---|---|---|
| [BryceWG/BiBi-Keyboard](https://github.com/BryceWG/BiBi-Keyboard) | 736 | Android | supported | ONNX on-device | v3 |
| [MaximeRivest/maivi](https://github.com/MaximeRivest/maivi) | 292 | Linux/macOS/Win | default | ONNX / parakeet-mlx | v3 |
| [Aayush9029/petal](https://github.com/Aayush9029/petal) | 257 | macOS | supported | parakeet-mlx | **v3 / v2** / tdt-ctc-110m |
| [ykdojo/super-voice-assistant](https://github.com/ykdojo/super-voice-assistant) | 207 | macOS | supported | CoreML/ANE | v3 |
| [GravityPoet/ChordVox](https://github.com/GravityPoet/ChordVox) | 174 | macOS/Win | supported | sherpa-onnx | v3 |
| [fayazara/Kaze](https://github.com/fayazara/Kaze) | 167 | macOS | supported | FluidAudio | v3 |
| [n0an/VivaDicta](https://github.com/n0an/VivaDicta) | 103 | iOS + watchOS | supported | CoreML/ANE | v3 |
| [zachswift615/speak2](https://github.com/zachswift615/speak2) | 89 | macOS | supported | FluidAudio | v3 |
| [KlymSerhii/Vox](https://github.com/KlymSerhii/Vox) | 84 | macOS + Win | supported | ANE / ONNX DirectML | v3 |
| [dmarzzz/VoxTerm](https://github.com/dmarzzz/VoxTerm) | 83 | macOS | supported | parakeet-mlx | v3, tdt-1.1b |
| [minburg/outspoke](https://github.com/minburg/outspoke) | 66 | Android | default (only engine) | 3× ONNX sessions | v3 INT8 |
| [r3dbars/transcripted](https://github.com/r3dbars/transcripted) | 55 | macOS | default | CoreML/ANE | v3 |
| [RisorseArtificiali/anti-vocale](https://github.com/RisorseArtificiali/anti-vocale) | 53 | Android | supported | ONNX | tdt SmoothQuant / int8 |
| [rcspam/dictee](https://github.com/rcspam/dictee) | 50 | **Linux Qt/KDE plasmoid** | supported (primary) | parakeet-rs (ORT) | v3 + Canary |
| [writingmate/aidictation](https://github.com/writingmate/aidictation) | 36 | macOS/Win/iOS/Android | supported | CoreML + ONNX | v3 |
| [blakkd/faster-whisper-hotkey](https://github.com/blakkd/faster-whisper-hotkey) | 28 | Linux | supported | NeMo/ONNX | v3 |
| [Pashtet495/AutoSpeechWriter](https://github.com/Pashtet495/AutoSpeechWriter) | 27 | Windows | default | CrispASR (CPU/Vulkan) | v3 |
| [damien-schneider/echo](https://github.com/damien-schneider/echo) | 26 | Tauri desktop | supported | transcription-rs | v3 |
| [gabrimatic/local-whisper](https://github.com/gabrimatic/local-whisper) | 26 | macOS/iOS/Android | default | MLX / sherpa-onnx INT8 | v3 |
| [ibuhs/Lekh-flow](https://github.com/ibuhs/Lekh-flow) | 24 | macOS | default for English | FluidAudio | v3 |
| [getdictus/dictus-ios](https://github.com/getdictus/dictus-ios) | 20 | iOS keyboard | supported | CoreML | v3 |
| [Quobi-AI/Quobi-Dictation](https://github.com/Quobi-AI/Quobi-Dictation) | 19 | Win/Linux | default | sherpa-onnx CPU | **v2 (EN) + v3** |
| [0xbrando/dictate](https://github.com/0xbrando/dictate) | 17 | macOS AS | default | FluidAudio ANE | v3 |
| [benedict2310/ora](https://github.com/benedict2310/ora) | 16 | macOS | default | FluidAudio | v3 |
| [eliasmocik/dum-dictation](https://github.com/eliasmocik/dum-dictation) | 14 | desktop | default | sherpa-onnx | tdt |
| [Danmoreng/vox-transcribe](https://github.com/Danmoreng/vox-transcribe) | 11 | Android | supported | ONNX/LiteRT | v3 |
| [eddmann/VoiceScribe](https://github.com/eddmann/VoiceScribe) | 11 | macOS | supported | FluidAudio | v3 |
| [zainzafar90/yap](https://github.com/zainzafar90/yap) | 10 | macOS | supported | FluidAudio | v3 |
| [swairshah/hearsay](https://github.com/swairshah/hearsay) | 8 | macOS | supported | FluidAudio | v3 |
| [tmoreton/yaprflow](https://github.com/tmoreton/yaprflow) | 8 | macOS | default | CoreML/ANE | v3 |
| [osadalakmal/parakeet-dictation](https://github.com/osadalakmal/parakeet-dictation) | 8 | macOS | default | MLX | tdt-0.6b |
| [nirajrajgor/stt](https://github.com/nirajrajgor/stt) | 2 | macOS | default | MLX | tdt-0.6b |
| [mworzala/relay](https://github.com/mworzala/relay) | 1 | macOS 26+ ARM | default | ANE | v3 |
| [mlutonsky/voicetype-win](https://github.com/mlutonsky/voicetype-win) | 1 | Windows | default | onnx-asr | v3 |
| [rdlwicked/voice-input](https://github.com/rdlwicked/voice-input) | 1 | Linux | supported | ONNX | tdt-1.1b |
| [Today20092/futo_with_parakeet_backup](https://github.com/Today20092/futo_with_parakeet_backup) | 1 | Android | default (FUTO fork) | ONNX Runtime | v3 |
| [felixmuth/voicetype](https://github.com/felixmuth/voicetype) | 0 | macOS | supported | FluidAudio ANE | tdt-0.6b |
| [b12consulting/rosella](https://github.com/b12consulting/rosella) | 0 | macOS | default | MLX | tdt-0.6b |
| [stefanlindqvist/parakeet-dictation](https://github.com/stefanlindqvist/parakeet-dictation) | 0 | Windows | default | ORT DirectML | v3 int8 |

Rejected on inspection: [karansinghgit/speaktype](https://github.com/karansinghgit/speaktype) (391★) — README says "Parakeet coming soon", WhisperKit only today.

---

## 3. Confirmed NO Parakeet

**Whisper-only / whisper.cpp / faster-whisper:** savbell/whisper-writer · themanyone/whisper_dictation · jakovius/voxd · AshBuk/dabri · karolswdev/HoldSpeak · Notely-Voice/NotelyVoice · soupslurpr/Transcribro · woheller69/whisperIME · Saik0s/Whisperboard · liamadsr/macOS-speech-to-text-open-source · human37/open-wispr *(distinct from OpenWhispr/openwhispr)* · ryleighnewman/YapToText · AkuchiS/Yap · benmaster82/writher · beausterling/CustomWispr · primaprashant/hns · giusmarci/openwhisp *(transformers.js)*.

**Non-Parakeet local engines:** Open-Less/openless *(Qwen3-ASR / Foundry / sherpa SenseVoice)* · yan5xu/ququ *(FunASR Paraformer)* · WenJing95/SayKey *(sherpa SenseVoice)* · Jeffrey0117/SpeakSlow *(sherpa Paraformer/Zipformer)* · ideasman42/nerd-dictation *(VOSK)* · papoteur-mga/elograf *(nerd-dictation wrapper, VOSK)* · FrigadeHQ/yap *(Apple SpeechAnalyzer)*.

**Cloud-only, no local inference at all:** zachlatta/freeflow · tover0314-w/opentypeless · Turtlecute33/WisprBoard · basilysf1709/golos *(Deepgram)* · evoleinik/fnkey *(Deepgram/Groq)* · prasanjit101/whishpy *(Groq/OpenAI)* · nutanc/openvoiceflow *(OpenAI)*.

*Three of these were downgraded from the audit's original label by verification: `zachlatta/freeflow` (claimed partial — a free-text model field on an OpenAI-compatible client is protocol genericity, not support), `jakovius/voxd` and `primaprashant/hns` (claimed planned — an unanswered third-party issue and an unmerged outside-contributor plan doc are not roadmaps).*

---

## 4. What Parakeet TDT 0.6B v2 actually is

**Identity.** [`nvidia/parakeet-tdt-0.6b-v2`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), released 2025-05-01. Single artifact `parakeet-tdt-0.6b-v2.nemo`, **2,472,222,720 bytes (2.47 GB)** fp32. No safetensors — HF `AutoModel` will not load it. You need `nemo_toolkit["asr"]` or a community port.

**Architecture.** FastConformer encoder, XL config, **24 layers**, trained with full global attention (8× depthwise-separable conv subsampling, 256 channels, kernel 9 — ~2.4× faster than vanilla Conformer at equal quality). Decoder is **TDT** (Token-and-Duration Transducer, [arXiv:2304.06795](https://arxiv.org/abs/2304.06795)): the joint net emits two independently normalized distributions, P(token) and P(duration), so the decoder *skips* encoder frames instead of stepping one at a time — up to 2.82× faster than plain RNN-T. **~600M params.** Offline/non-streaming; no cache-aware streaming config ships.

**Training.** ~120,000 h English: 10k h human-transcribed (NeMo ASR Set 3.0 — LibriSpeech, Fisher, VCTK, VoxPopuli, Europarl-ASR, MLS, Common Voice, AMI) + 110k h pseudo-labeled (YouTube-Commons, YODAS, LibriLight). 150k steps on 64×A100, then 2.5k steps on 4×A100 over ~500 h clean data.

**Accuracy / speed.** HF Open ASR Leaderboard (`.eval_results/open_asr_leaderboard.yaml`, eval 2025-04-15):

| | WER % |
|---|---|
| **Average** | **6.05** |
| LS test-clean / test-other | 1.69 / 3.19 |
| SPGISpeech / TEDLIUM-v3 | 2.17 / 3.38 |
| VoxPopuli / GigaSpeech | 5.95 / 9.74 |
| AMI / Earnings-22 | 11.16 / 11.15 |

**RTFx 3,386 at batch 128.** That is a datacenter batch number — single-utterance dictation is nowhere near it. Noise degrades steeply: 6.95 @ 10 dB, 8.23 @ 5 dB, 11.88 @ 0 dB. µ-law 8 kHz telephony only costs 6.05 → 6.32, so it holds up on phone audio.

**Native features.** Automatic punctuation and capitalization (no separate P&C model). **Char, word, and segment timestamps** from the TDT duration head (`transcribe(..., timestamps=True)`) — real model alignment, not Whisper's DTW approximation. Resolution floor is the 80 ms frame. 16 kHz mono in. Up to 24 min single-pass with full attention — a memory bound on an A100-80GB, not an architectural cap. **No 30 s receptive-field constraint**, so no Whisper-style forced-window artifacts.

**License: CC-BY-4.0.** Commercial use permitted, including closed-source, SaaS, and paid apps. Obligations are attribution (credit NVIDIA, link the license, note modifications) and no added restrictions/DRM. Fine-tunes and quantized ports are permitted derivatives, and it does **not** infect your surrounding code. Not the NVIDIA Open Model License, not NC, not research-only. This permissiveness is exactly why ~15 independent ONNX/GGUF/CoreML/MLX ports exist. Caveat that is *not* a license term: 110k h of training data is pseudo-labeled from YouTube-Commons/YODAS; NVIDIA licenses the weights regardless, but data provenance is not addressed. The card also states no bias mitigation was performed.

**v2 vs [v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)** (2025-08-14, also CC-BY-4.0, same 600M FastConformer-24L + TDT):

| | v2 | v3 |
|---|---|---|
| Languages | **English only** | 25 European (bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro, sk, sl, es, sv, ru, uk) |
| Training | ~120k h | ~660k h (Granary: MOSEL, YTC, YODAS + NeMo ASR Set 3.0) |
| English WER / RTFx | **6.05** / 3,386 | 6.32 / 3,333 |
| Multilingual | — | Fleurs 11.97, MLS 7.83, CoVoST 11.98; 24-lang avg 9.7% |
| Long-form | 24 min documented | 24 min full attn, **up to 3 h with local attention** |
| Language selection | n/a | **auto-detect only, cannot be forced** |

Decision rule: pure English → v2 is still marginally better and never mis-detects. Anything mixed or non-English → v3, at a cost of ~0.27 WER absolute on English. v2's exact SentencePiece vocab size is **not published** — sources conflict (v3's card says 8,192, the Canary-v2/Parakeet-v3 paper says 16,384). Don't quote a number for v2.

**Context (2026):** 6.05 no longer tops the leaderboard — Cohere Transcribe (~5.42) and IBM Granite Speech 4.1 2B (~5.33) are ahead. But nothing near the top of the WER table is within an order of magnitude of ~3,300 RTFx. Parakeet still owns accuracy-per-unit-compute.

---

## 5. How it runs off NVIDIA hardware

Parakeet is **not** NVIDIA-locked. NVIDIA hardware is required only if you use NeMo itself. Real-world desktop dictation speeds: **10–35× realtime on plain CPU**, **35–190× on Apple Silicon**.

| Runtime | Language | Platforms | Accel | v2 | v3 | Quant | Notes |
|---|---|---|---|---|---|---|---|
| **[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)** | C/C++ + Swift, Rust, Python, TS bindings | macOS, Linux, Win | Metal, Vulkan, CUDA, HIP/ROCm, CPU | ✅ | ✅ | GGUF F16→Q4_K_M | 1.7k★, MIT, 499 commits. The pragmatic cross-platform choice |
| **[FluidAudio](https://github.com/FluidInference/FluidAudio)** | Swift SPM | macOS 14+, iOS 17+ | **CoreML → ANE** | ✅ | ✅ + streaming EOU | compiled `.mlmodelc` | 2.6k★, Apache-2.0. **~110–190× RT on M4 Pro.** Powers ~15 of the apps above |
| **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)** | C/C++ + 12 bindings | Linux, macOS, Win, Android, iOS, HarmonyOS, WASM, RPi, RK3588, Jetson; x86/ARM/**RISC-V** | CPU; NPU (RKNN/QNN/Ascend); CUDA | ✅ | ✅ | prebuilt int8 | 14.1k★, Apache-2.0. Most production-hardened. **Offline only** — no true streaming for TDT |
| **[onnx-asr](https://github.com/istupakov/onnx-asr)** | Python (numpy + onnxruntime **only**) | Win/Linux/macOS, x86+ARM | CPU, CUDA, TensorRT, CoreML, DirectML, ROCm, WebGPU | ✅ | ✅ | `quantization="int8"` | MIT. Best published cross-hardware numbers |
| **[parakeet-mlx](https://github.com/senstella/parakeet-mlx)** | Python | **Apple Silicon only** | MLX → Metal GPU (**not** ANE) | ✅ | ✅ (default) | bf16/fp32, community 8-bit | 970★. ~24× RT on M4 — slower than ggml-Metal or ANE. Means bundling Python |
| **[transcribe-rs](https://github.com/cjpais/transcribe-rs)** / **[parakeet-rs](https://github.com/altunenes/parakeet-rs)** | Rust (ORT) | macOS, Win x64, Linux x64, Jetson | CPU default; CUDA/ROCm/DirectML/Metal/Vulkan/WebGPU features | ✅ | ✅ | int8, int4 | MIT. Youngest API of the serious options |
| **[parakeet.cpp](https://github.com/mudler/parakeet.cpp)** | C++17 | macOS, Linux, Win (prebuilt) | CPU, CUDA, Metal, Vulkan, HIP | ✅ | ✅ | GGUF f16→q4_k | 755★ but only ~38 commits. Claims byte-identical output to NeMo, 1.11–1.69× faster CPU |
| **NeMo** | Python/PyTorch | **Linux only** (Win = WSL2) | NVIDIA GPU | ✅ | ✅ | none | Reference impl. `pip install nemo_toolkit[asr]` drags in PyTorch. **Not a desktop dependency** |

**Measured, transcribe.cpp on an 11 s clip:** M4 Max Metal Q8_0 → 68 ms (**163×**) · M4 Max CPU Q4_K_M → 312 ms (35×) · Ryzen 7 4750U Vulkan Q8_0 → 673 ms (16×) · same CPU Q4_K_M → 1.05 s (10×). Quantization is nearly free: LS test-clean WER 1.68% at F32 → **1.72% at Q4_K_M** (483 MB).

**onnx-asr RTFx:** Ryzen 9800X3D CPU 36.8 · same int8 30.5 · **ARM Cortex-A53 1.1** · RTX 5070 Ti CUDA 88.7 · TensorRT fp16 329.2 · T4 57.6. Note int8 is *slower* than fp32 on a fast x64 CPU — you take it for the ~670 MB / ~2 GB-RAM footprint vs ~6 GB fp32, not for speed. And a weak ARM SBC barely clears realtime.

**Floor case:** Handy quotes ~5× realtime on a mid-range i5, minimum Intel Skylake. Fine for 5–20 s dictation clips.

**ONNX exports are not interchangeable** — sherpa-onnx wants a 3-file encoder/decoder/joiner split, onnx-asr wants istupakov's layout, transcribe.cpp wants GGUF, FluidAudio wants `.mlmodelc`. Match the export to the runtime: [istupakov/parakeet-tdt-0.6b-v2-onnx](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v2-onnx) · [csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8](https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8) · [onnx-community/parakeet-tdt-0.6b-v2-ONNX](https://huggingface.co/onnx-community/parakeet-tdt-0.6b-v2-ONNX) (browser) · `handy-computer/*` (GGUF) · `mlx-community/*` · `FluidInference/*-coreml`.

---

## 6. When Whisper is still the better call

These are the failure modes with receipts, not caveats-for-form.

**1. You cannot force a language.** v3 auto-detects and there is no `language=` equivalent. Murmure's maintainer, [issue #309](https://github.com/Kieirra/murmure/issues/309): *"There is no way to force a specific language, this is a limitation of the model architecture itself."* Roughly a dozen Murmure issues are the same bug — dictate French, get English. [#365](https://github.com/Kieirra/murmure/issues/365) shows mid-sentence flip-flop; [#295](https://github.com/Kieirra/murmure/issues/295) shows LID drifting to English after ~50 utterances in one session. Handy's own code comments this: `transcription.rs:1665-1667` — "Some multilingual engines (notably Parakeet V3) always auto-detect and ignore Handy's selection." **If your users are bilingual, Whisper wins outright.**

**2. Repetition hallucination on clean audio.** Handy's maintainer on [#448](https://github.com/cjpais/Handy/issues/448): *"This is a Parakeet hallucination for sure. If you use whisper this one will go away and others will come instead."* [#649](https://github.com/cjpais/Handy/issues/649) is deterministic — "two two" → *"Two two two two two two two two two two two."* Whisper hallucinates *content* (invents plausible text, mostly on silence/noise). Parakeet hallucinates *duration* — the TDT duration head under-advances and a short function word repeats mid-utterance. Parakeet's version happens on **clean** audio, which Whisper's usually doesn't. Mitigation is app-side: a consecutive-duplicate-word collapser with a small allowlist ("had had", "that that"). ~10 lines, kills the most visible failure.

**3. Trailing silence can zero your transcript.** [NeMo #15757](https://github.com/NVIDIA-NeMo/Speech/issues/15757), open: a 2.2 s speech crop decodes fine; the same crop **+ 400 ms of zeros decodes to `''`**. Cause: log-mel normalization runs over the whole buffer including the silence, shifting the prefix features. This is exactly what push-to-talk hands the model on key-up. Trim the tail, or pass true speech length as the valid length, and retry on empty.

**4. The 24-minute number does not survive ONNX export.** [Handy #1332](https://github.com/cjpais/Handy/issues/1332): 5–9 minute recordings **silently vanish** — no transcript, sometimes no WAV. Root cause traced in-thread: the v3 encoder's self-attention has a relative position bias precomputed for **337 positions**; a ~7 min recording yields ~5337 encoder frames after subsampling → `Attempting to broadcast an axis by a dimension other than 1. 337 by 5337`. Confirmed on M1/M2/M3, v2 and v3. Duplicates #1464, #1483. **Chunk at ≤60 s with decoder-state carryover, and persist the WAV before transcribing.**

**5. v2/v3 are not streaming models.** [Handy #1830](https://github.com/cjpais/Handy/issues/1830) is the definitive teardown: the GGUF carries `att_context_style = "regular"` with `att_context_left/right = -1`, so `supports_streaming = false` is derived from the hparams at load. **No config flag can make the offline export stream.** Measured cost of the batch path (GTX 1650, Vulkan, Q8_0): ~220 ms fixed CPU-side overhead per utterance, and **8.4 s for a 170 s dictation** vs ~0.6 s for a cache-aware streaming model on 53 s. For live partials you need a *different* checkpoint (`parakeet-unified-en-0.6b` or `nemotron-speech-streaming-en-0.6b`) — and re-test proper nouns, since the tokenizers differ ([NeMo #15657](https://github.com/NVIDIA-NeMo/Speech/issues/15657): unified-en emits `Pr ⁇ vos` for "Prévost" where **v2 got it right**).

**6. No prompt biasing.** Whisper takes `initial_prompt`; Parakeet has no equivalent. Proper nouns and jargon are the shared weak spot but Whisper has a lever and Parakeet doesn't — which is why every serious Parakeet app builds a custom-dictionary/word-boosting layer, and why those layers are fiddly ([Murmure #386](https://github.com/Kieirra/murmure/issues/386): boosting "insuffisance chronique rénale" forces "rénale" to appear even when only the first two words were said).

**7. Cold start recurs.** [OpenWhispr #1078](https://github.com/OpenWhispr/openwhispr/issues/1078): hotkey→armed is ~6 s cold vs <3 s warm, because the sherpa-onnx process is absent from the process table when idle and reloads the ~624 MB model on demand. Pathological case: [Handy #1841](https://github.com/cjpais/Handy/issues/1841) — NVIDIA + Vulkan with `KHR_coopmat`, reload after idle unload takes **70–76 s** rebuilding the shader pipeline set. Workaround `GGML_VK_DISABLE_COOPMAT=1`, no measurable inference cost. Pre-warm and pin the model.

**8. License asymmetry.** Whisper is **MIT**. Parakeet is CC-BY-4.0 — commercial-friendly but attribution is a real obligation.

**9. Ecosystem maturity.** whisper.cpp has no Parakeet equivalent of comparable maturity, `transformers`/faster-whisper/CTranslate2 tooling is far deeper, and 99 languages plus X→EN translation are simply not on the table for Parakeet.

**Other landmines:** `model.transcribe()` is not thread-safe ([NeMo #15771](https://github.com/NVIDIA-NeMo/Speech/issues/15771)) · TDT CUDA-graph capture irreversibly corrupts `torch.load()` process-wide ([#15423](https://github.com/NVIDIA-NeMo/Speech/issues/15423)) · timestamp path crashes on empty decodes ([#14427](https://github.com/NVIDIA-NeMo/Speech/issues/14427)) and length-mismatches confidences on v3 ([#15143](https://github.com/NVIDIA-NeMo/Speech/issues/15143)) · non-ASCII install paths break model loading on Windows ([Handy #574](https://github.com/cjpais/Handy/issues/574), [#1585](https://github.com/cjpais/Handy/issues/1585)) · fine-tuning to a new language works badly ([#13825](https://github.com/NVIDIA-NeMo/Speech/issues/13825), [#14140](https://github.com/NVIDIA-NeMo/Speech/issues/14140)) · v2's card explicitly says **"not recommended for word-for-word/incomplete sentences"** — i.e. the one-to-three-word voice commands dictation users actually produce. Test that case yourself.

---

## 7. Recommendation by platform

### macOS
**[Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)** or **[altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice)**. Both default to Parakeet v3 on the ANE via FluidAudio, both keep v2 one click away, both keep Whisper as the bilingual escape hatch. VoiceInk additionally ships `parakeet-unified-0.6b` for true streaming. If you want the app that *is* Parakeet with nothing else in the way: **[moona3k/macparakeet](https://github.com/moona3k/macparakeet)** (M1+, macOS 14.2+, includes its own benchmark table — 3.22% macro WER on LibriSpeech, and honest about failing CJK at 171 CER Korean). Avoid parakeet-mlx-based apps for daily driving: MLX runs on the Metal GPU, not the ANE, and measures ~24× RT vs ~110–190× for CoreML.

### Windows
**[cjpais/Handy](https://github.com/cjpais/Handy)** — the only mature option that is genuinely cross-platform, with real Windows x64 *and* aarch64 builds. Parakeet runs CPU-only there (`Cargo.toml`: "ONNX Runtime on Windows is CPU-only, no ort-directml"). For a lighter Windows-native tool, **[Whamp/chirp-stt](https://github.com/Whamp/chirp-stt)** or **[tristanmuzzu/parakeet-dictation](https://github.com/tristanmuzzu/parakeet-dictation)** — both are single-purpose onnx-asr CPU apps with no engine abstraction to get in the way. **[EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter)** is worth knowing because Parakeet was the *only* local engine it shipped on Windows through v7.5–v7.11 (whisper-rs/MSVC CRT conflicts), so its Windows Parakeet path is unusually well-exercised.

### Linux — wlroots/Wayland specifically
**[goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr)** is the direct fit: Wayland/Hyprland-native, systemd, no X11 assumption, onnx-asr backend with `nemo-parakeet-tdt-0.6b-v3` int8 hardcoded as that backend's default, CPU everywhere with NVIDIA GPU auto-selected via `nvidia-smi`. The setup wizard pre-selects it as option 1, so a fresh `hyprwhspr setup` + Enter gets you Parakeet even though the shipped config default is `pywhispercpp`. If you prefer Rust to Python: **[better-slop/hyprwhspr-rs](https://github.com/better-slop/hyprwhspr-rs)** — evdev + wl-clipboard-rs + enigo Wayland feature, Parakeet compiled in by default (cargo feature `parakeet = ["parakeet-rs"]`), just run the download script and set `"provider": "parakeet"`. **glibc only** — musl releases were dropped precisely because Parakeet wouldn't build. For broadest hardware coverage: **[peteonrails/voxtype](https://github.com/peteonrails/voxtype)** ships prebuilt `-onnx-avx2/avx512/cuda-12/cuda-13/migraphx` binaries plus `linux-aarch64-onnx`, and is the only one with a real AMD ROCm/MIGraphX path. **[Kieirra/murmure](https://github.com/Kieirra/murmure)** ships AppImage/deb/rpm and is 100% Parakeet with no fallback — the least configuration, at the cost of CPU-only int8 and no language selection at all. **[rcspam/dictee](https://github.com/rcspam/dictee)** is the KDE/Plasma option if you're not on wlroots.

### Mobile
**Android:** [notune/android_transcribe_app](https://github.com/notune/android_transcribe_app) — Parakeet v3 GGUF bundled at build time with a pinned SHA-256, transcribe.cpp/ggml via JNI, **no INTERNET permission in the manifest** (verified in `AndroidManifest.xml`), arm64-v8a only. That is the strongest offline-privacy story on the list. For a keyboard rather than an app: [BryceWG/BiBi-Keyboard](https://github.com/BryceWG/BiBi-Keyboard) (736★, Parakeet among 6 ONNX engines) or [minburg/outspoke](https://github.com/minburg/outspoke) (Parakeet-only, 3× ONNX sessions). Explicitly **not** upstream whisperIME — maintainer rejected Parakeet twice ("too big for most phones", "it is English only"); the multi-engine work lives in the fork `pcraciunoiu/whisperIME`.

**iOS:** thin. [getdictus/dictus-ios](https://github.com/getdictus/dictus-ios) (keyboard) and [n0an/VivaDicta](https://github.com/n0an/VivaDicta) (iOS + watchOS), both CoreML v3. Neither is audit-verified at file level.

---

### Flagged as unknown / unverified

- **v2 SentencePiece vocab size** — not published on the model card; v3's card (8,192) and the Canary-v2 paper (16,384) disagree. Do not quote a number.
- **`DictionLabs/Diction` container internals** — the `dictionlabs/parakeet:latest-int8` image and the iOS on-device build are closed source; whether it runs NeMo, ONNX, or TensorRT is undisclosed. Docker Hub says "Requires an NVIDIA GPU" while the README's model table says "fast on CPU, faster on GPU" — the two sources conflict.
- **`heardlabs/heard`** — Parakeet is real and shipping, but entirely inside the proprietary `heard_power` subprocess. Cloning the OSS repo gives you TTS and **no STT at all**.
- **`chidiwilliams/buzz`** — the Parakeet code is merged and tested but **unreleased**; latest tag v1.4.4 (2026-03-14) has zero Parakeet code and the promised v1.5.0 does not exist.
- **`EpicenterHQ/epicenter`, "no v2 anywhere"** — GitHub code search was 403 rate-limited during that check; the negative is unconfirmed, though nothing in any file read references v2.
- **The ~40-app secondary table** — README/source-level checks only, not held to the audit's file-and-line evidence standard. Treat support levels there as indicative.
- **`Saik0s/Whisperboard`** — the only Parakeet signal is an off-hand maintainer comment on unrelated issue #51 ("one of the things I am working on"); code on main has not moved since Sept 2024. Classified none, but it is the borderline case.