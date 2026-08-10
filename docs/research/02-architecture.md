# Architecture Patterns Across 24 Open-Source Dictation Apps

Seven structural decisions recur in every dictation app of consequence: engine abstraction, session state machine, threading model, core-vs-shell split, plugin seam, persistence, and IPC. This doc names the best-in-class implementation of each with its repo and file, then contrasts Parla's `ParlaCore`/`Parla` split against them. The last section is a ranked list of what to change, with effort sizes.

Parla today: **1,577 lines in `Sources/ParlaCore/`, 1,170 in `Sources/Parla/main.swift`** — 43% of the logic-bearing code lives in an `NSApplicationDelegate`.

---

## 1. Engine / provider abstraction

### The shape everyone converges on

Two protocols, not one. Batch and streaming have different isolation requirements and different lifetimes, and every app that tried to unify them split them back apart.

| Repo | Batch protocol | Streaming protocol | Discovery |
|---|---|---|---|
| [peteonrails/voxtype](https://github.com/peteonrails/voxtype) | `Transcriber` (sync `transcribe(&[f32]) -> String`) | — | `as_streaming() -> Option<&dyn StreamingTranscriber>` on the batch trait |
| [watzon/pindrop](https://github.com/watzon/pindrop) | `TranscriptionEngine` (`@MainActor`) | `StreamingTranscriptionEngine` (**not** `@MainActor`) | `Transcription/TranscriptionEngine.swift` |
| [TypeWhisper/typewhisper-mac](https://github.com/TypeWhisper/typewhisper-mac) | `TranscriptionEngine` (`@MainActor`) | `StreamingTranscriptionEngine` (not `@MainActor`) | plugin-declared capability |
| [amicalhq/amical](https://github.com/amicalhq/amical) | `TranscriptionProvider` | same interface, `transcribe/flush/reset/warmup?` | `core/pipeline-types.ts` |
| [cjpais/Handy](https://github.com/cjpais/Handy) | `enum LoadedEngine` (11 variants) | `StreamCmd` over a worker thread | `managers/transcription.rs:179` |

**voxtype's `as_streaming()` is the cheapest good answer** — one trait, an optional downcast, no parallel registry. From `src/transcribe/mod.rs:92-150`:

```rust
pub trait Transcriber {
    fn transcribe(&self, samples: &[f32]) -> String;
    fn as_streaming(&self) -> Option<&dyn StreamingTranscriber> { None }
    fn prepare(&self) {}
    fn last_detected_language(&self) -> Option<String> { None }
}
```

Callers ask the engine what it can do rather than consulting a config table. TypeWhisper does the same thing across nine engines via `Transcriber::as_streaming()`-equivalent capability queries — and critically, asks the *loaded session*, not a static catalog: Handy's `managers/model_capabilities.rs` calls `session.model().capabilities()` at load time and reconciles the registry, because a catalog flag that disagrees with the binary is worse than no flag (Handy issue #1601: "Non-whisper archs can advertise `Feature::InitialPrompt` yet reject the whisper-kind run extension with INVALID_ARG, so the whisper extension must be gated on the arch, not on the feature").

### Model catalog as a compiled-in artifact

Handy's `src-tauri/src/catalog/catalog.json` is **embedded in the binary** — 67 models, `catalog_version: 2`, each entry carrying a pinned commit revision, per-quant `{filename, quant, size_bytes, sha256}`, and capability flags. The model picker works with zero network. The mirror fallback is a plain static host: the URL is literally `{mirror}/{repo_id}/{revision}/{filename}`, so bytes from HF or the mirror verify against the same hash.

Nobody else does this and everyone else pays for it. hyprwhspr (`lib/src/setup/model.rs`, 3,900 lines) has **no checksum verification at all** — `rg 'sha256|checksum|hashlib'` over `src/` returns nothing. thewh1teagle/vibe verifies byte-length only (`desktop/src-tauri/src/cmd/download.rs`) and accepts a `vibe://download/?url=` deep link, so any remote file lands in the models folder unverified. macparakeet fixes it properly (`Sources/MacParakeetCore/Services/ModelDownloadCoordinator.swift`): manifest → per-file sha256 → **delete on mismatch**, and pre-existing files are re-hashed every run so a corrupt cache can't survive an upgrade.

Handy's download hardening is the other half worth stealing (`managers/model.rs:1890-2050`):

```rust
const ATTEMPT_STREAMS: [usize; 4] = [4, 1, 1, 1];
// "Eight simultaneous connections were all reset on an affected network in #1579,
//  while one stream succeeded; four is a less aggressive fast path."
```
Plus a fresh HTTP client per attempt ("so a wedged connection from the previous try can't poison the retry"), `.with_token(None)` (a stale cached HF token breaks public downloads), and a 60 s stall watchdog because hf-hub has no internal timeouts.

### Scheduling: reserve a slot for the interactive path

[moona3k/macparakeet](https://github.com/moona3k/macparakeet) has the only real control plane (ADR-016, `Sources/MacParakeetCore/STT/STTScheduler.swift:853-885`): **one** `STTScheduler` actor per process owning admission, priority, backpressure and cancellation, delegating model lifecycle to exactly one `STTRuntime`. Two slots:

- `interactive` — dictation only, **reserved**, so interactive latency is never queued behind batch work
- `background` — `meetingFinalize` (rank 0) > `meetingLiveChunk` (1) > `fileTranscription` (2); backpressure drops the *oldest* pending `meetingLiveChunk`

A single FIFO queue (which is what Parla has) works exactly until the app gains a second job type.

---

## 2. Session state machines

### The pattern: pure reducer, effects as data

The three best implementations are all `(state, event) → (state, [effect])` with zero I/O, so every interleaving is unit-testable without a microphone, a window server, or an ASR model.

| Repo | Representation | LOC | Testable headless |
|---|---|---|---|
| [moona3k/macparakeet](https://github.com/moona3k/macparakeet) | `mutating func handle(_ e: DictationFlowEvent) -> [DictationFlowEffect]`, 45 effect cases | 513 | yes |
| [amicalhq/amical](https://github.com/amicalhq/amical) | `(state, event) -> {state, commands[]}` + separate interpreter | 355 + 453 | yes |
| [cjpais/Handy](https://github.com/cjpais/Handy) | `enum Stage` owned by one mpsc consumer thread + `simulate()` harness | 521 | yes |
| [moinulmoin/voicetypr](https://github.com/moinulmoin/voicetypr) | `RecordingStateMachine::is_valid_transition` explicit match | 233 | yes |
| [EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter) | capture *derived* from recorder; outcome a separate track | — | yes |
| [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) | booleans spread across `ASRService`/`ContentView` | — | **no** |
| **Parla** | booleans on `AppDelegate` + a 150-line `onEdge` switch | — | **no** |

macparakeet's states (`Sources/MacParakeetCore/DictationFlow/DictationFlowStateMachine.swift`):

```
idle → ready → checkingEntitlements(mode) → startingService(mode)
     → recording(mode) → processing → finishing(outcome) → idle
     + pendingStop(mode)     // stop arrived while startRecording still in flight
     + cancelCountdown       // 5s undo window
```

Two details worth copying verbatim:

1. **`pendingStop` is a real state, not a dropped event.** A stop that arrives during an in-flight start is *remembered* and auto-fires on `recordingStarted`. Handy models the same thing as `PttAction::DeferRelease` with a 50 ms `RELEASE_GRACE` and a `simulate()` test replaying a 13-event X11 auto-repeat burst asserting `starts == 1, stops == 0` (`transcription_coordinator.rs`, issue #1539).
2. **Every async completion event carries a `generation: Int`**, and the machine drops stale events with `guard gen == generation else { return [] }`. Handy generalises this to `cancel_generation: AtomicU64` checked at *six* pipeline checkpoints, plus `complete_unless_cancelled(fut, || rm.was_cancelled_since(gen))` polling every 25 ms so a slow LLM call is abandonable.

### Terminal-state guarantee via a Drop guard

Handy's `stop()` unconditionally sets `Stage::Processing`; the async pipeline holds a `FinishGuard` whose `Drop` impl sends `ProcessingFinished → Idle` **on every exit path including panic**. voicetypr solves the same problem with a `force_state()` escape hatch that logs `[FLOW] FORCE setting state ... (bypassing validation)` — honest, but reactive rather than structural.

The failure this prevents is the loudest bug class in the corpus. hyprwhspr #556: a device re-enumeration reset `is_pressed = false` without emitting a Release event, and over seven days **28 of 46 recordings ended in ≤0.3 s and 4 ran to the 180 s cap**. hyprwhspr has no recording timeout at all.

### Interruption ≠ termination

[EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter) `apps/epicenter/src-tauri/src/recorder/recorder.rs` splits `end_capture` from `stop`: an unplugged mic ends *capture* but not the *recording*. The slot stays occupied, the staged WAV stays on disk, `current()` keeps answering with a typed `EndedReason` (`deviceDisconnected | permissionRevoked | streamFailed | storageFailed`), and only the owner's `stop`/`cancel` resolves it. The ordinary stop path then finalizes and transcribes it like any other recording. No pending-interruption inbox, no acknowledgement protocol — the cleanest interruption design in the corpus, in ~30 lines.

---

## 3. Threading and concurrency

### The measurement that settles the `@MainActor` question

[watzon/pindrop](https://github.com/watzon/pindrop), `Transcription/StreamingTranscriptionEngine.swift:36-42`:

> *"Deliberately NOT @MainActor: per-buffer decode must never queue behind UI work. A busy render loop (the orb animates at 30fps) starves main-actor hops to ~10/sec while audio arrives at ~50/sec, so partials pile up and burst out only at stop."*

**~50 buffers/sec in, ~10 main-actor hops/sec out.** That is the only hard number in the corpus for main-actor starvation, and it is the reason both pindrop and TypeWhisper keep batch on `@MainActor` and streaming off it.

pindrop's companion rules (`StreamingSessionController.swift:568-593`):
- The audio tap yields into an `AsyncStream` whose continuation is captured **directly**, not via `self`, so the callback never re-enters the main actor.
- One `Task.detached(priority: .userInitiated)` consumes it; the engine handle is snapshotted once per session so the pump never routes through the `@MainActor` service.
- `bufferingPolicy: .bufferingNewest(32)` — ~8 s at a 4,096-frame 16 kHz tap. **The live path may drop; the file-backed recorder retains the complete waveform for offline finalize.**

### Bounded queues, dropping on the audio thread

Every app that got this right uses a bounded channel with a non-blocking send. Epicenter (`recorder.rs`): `mpsc::sync_channel` at `CAPTURE_QUEUE_CHUNKS = 200` (~2 s), `try_send` **drops on full** — "the only outcome that keeps a stalled disk from stalling the audio thread" — with drop reports throttled to `DROP_REPORT_INTERVAL = 1s`. voicetypr wraps the entire cpal callback in `catch_unwind(AssertUnwindSafe(...))` because a panic unwinding across `extern "C"` **aborts the process** (commit `1000e1d`).

TypeWhisper adds the RT-safety rules explicitly (`AudioRecorder.swift:154-175`): `OSAllocatedUnfairLock` for `sampleCounter`/`atomicAudioLevel`/`preRollBuffer` because *"Avoids Task allocation on the audio thread which causes priority inversion."*

Handy's `StreamRouter` exists so the per-frame feed costs *a single relaxed atomic load* when no stream is running: `if !self.open.load(Relaxed) { return; }` — no Tauri state lookup, no mutex.

### Engine leasing

Handy leases the engine **out of the mutex** during streaming rather than holding it under lock, structurally excluding batch contention (`managers/transcription.rs`). Four independent atomics express the state — `router.open`, `active_stream_worker`, `active_engine_lease`, `stream_active` — each cleared by a `StreamWorkerGuard` Drop impl so a panicking worker can't wedge the app. TypeWhisper does the same with `StreamingEngineLease` + `streamingLifecycleEpoch` (`TranscriptionService.swift`).

### Hard deadlines on non-cooperative work

TypeWhisper, `StreamingSessionController.swift:691-779`: `withFinalizeTimeout` uses **independently owned detached tasks and a lock-protected first-result-wins resolver**, explicitly because structured `TaskGroup` + `cancelAll()` cannot return while a non-cooperative child (Core ML inference) is still running. voxtype's own audit reaches the same conclusion: *"cancellation only works when the timed-out operation cooperatively exits"* — after issue #67, where files longer than a few minutes hung at 0% forever ("tested leaving it for several hours") because `performCompleteDiarization()` was called synchronously on 83 million samples with no chunking, no timeout, no cooperative cancellation.

**Parla already gets this right** via `AbortBox` + the C trampoline in `Sources/ParlaCore/Transcriber.swift:96-99` — `whisper_full` polls the abort callback, so fn-up genuinely kills an in-flight pass. That is a cooperative cancel primitive most of the corpus lacks.

### Platform-conditional serialization

macparakeet `Sources/MacParakeetCore/Services/ANEInferenceGate.swift`: a process-wide 1-permit async mutex around every `AsrManager.transcribe(...)`, **a pure no-op on macOS 15+**:

```swift
if #available(macOS 15.0, *) { false } else { true }
```

Justified by crash telemetry: SIGBUS 36 occurrences, **36/36 on macOS 14 (14.4–14.8), zero on 15/26/27**, chip-agnostic across M1–M3. Concurrent CoreML inference corrupts a shared read-only mmapped weights region on macOS 14 (FluidAudio #661). The gate is applied *inline* at every call site rather than via a helper, because the closure captures the actor-owned non-`Sendable` `AsrManager` and Swift 6 only permits that inline — which means it is enforced by a comment, not the compiler. That is the fragility to avoid.

---

## 4. Core vs shell

### The rule that holds

| Repo | Core (no UI) | Shell | CLI shares core | Orchestrator LOC |
|---|---|---|---|---|
| [moona3k/macparakeet](https://github.com/moona3k/macparakeet) | `MacParakeetCore` (no SwiftUI) | `MacParakeet` + `MacParakeetViewModels` (38 VMs) | `MacParakeetCLI`, 33 commands | pure FSM 513 + coordinator |
| [Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli) | `MuesliCore` — "deliberately UI-free so the CLI can link it" | `MuesliNativeApp` | `muesli-cli` (same SQLite) | `main.js` 1,833 |
| [cjpais/Handy](https://github.com/cjpais/Handy) | `transcription/`, `audio_toolkit/`, `managers/` | React settings UI | `bin/cli.rs` | `lib.rs` 1,008 |
| [watzon/pindrop](https://github.com/watzon/pindrop) | — | — | — | `AppCoordinator.swift` **6,219** |
| [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) | — | — | — | `ContentView.swift` **4,472** |
| [OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr) | — | — | — | `ipcHandlers.js` **7,700+** |
| [voquill/voquill](https://github.com/voquill/voquill) | — | — | — | `DictationSideEffects.tsx` 915 |
| **Parla** | `ParlaCore` 1,577 | `Parla` | `parla-eval` | `main.swift` **1,170** |

macparakeet is the only project that *enforces* the split: each `MacParakeetCore` subsystem carries its own README documenting entry point, invariants and "how to verify a change", checked by `scripts/check-readme-references.sh` in CI.

### The anti-pattern, stated by its own author

[voquill/voquill](https://github.com/voquill/voquill) `docs/desktop-architecture.md`: **"Rust is the API, TypeScript is the Brain."** Rust holds zero business logic. Consequences, all real:

- The dictation state machine, pipeline, provider dispatch and delivery decisions live in a React component (`DictationSideEffects.tsx`, 915 lines, 12 `useRef`s), so the whole feature is dead if the webview is wedged.
- Audio crosses the IPC boundary as JSON `number[]` — `AudioChunkPayload { samples: Vec<f32> }` emitted every 100 ms (~4,800 JSON numbers, 10×/sec) plus the entire recording returned at stop.
- Their answer to WebView2 freezing background JS is `--disable-renderer-backgrounding --disable-background-timer-throttling` plus a keepalive timer, *because the hotkey state machine lives in JS*.

pindrop's 6,219-line `AppCoordinator` owns hotkeys, event taps, recording, batch pipeline, streaming handoff, context sessions, media queue, MCP, note editors, escape handling, indicator lifecycle and history persistence. `StreamingSessionController` was carved out of it in 2026-07 and the file is still that size. FluidVoice's `stopAndProcessTranscription` is a ~400-line function inside a SwiftUI `View` doing mode routing, ASR stop, AI enhancement, five formatting passes, history, clipboard, focus restore, typing dispatch, analytics and overlay lifecycle.

**Parla is at 1,170 and already showing the symptom**: `finish()` is 243 lines (`main.swift:321-558`), `transform()` 112, `stream()` 66, and the `hotkey.onEdge` switch is 150 lines nested *inside* `applicationDidFinishLaunching`. That is ~630 lines of session logic inside an `NSApplicationDelegate` that also owns the status item, the menu builder, the model downloader and launch-at-login.

---

## 5. Plugin systems

Two exist in the corpus and both are cautionary.

**[TypeWhisper/typewhisper-mac](https://github.com/TypeWhisper/typewhisper-mac)** went all-in: `TypeWhisperPluginSDK/` is a separate SwiftPM package defining `TranscriptionEnginePlugin`, `LLMProviderPlugin`, `LiveTranscriptionCapablePlugin`, `PostProcessorPlugin`, `ActionPlugin`, `HostServices`. **Every engine is a plugin, including the local ones** — the app core contains zero ASR code. 46 bundles ship. Loading is in-process `Bundle(url:)` + `NSClassFromString(manifest.principalClass)`, which requires `com.apple.security.cs.disable-library-validation` and means **a crashing plugin takes down the app**.

Then Swift ABI bit them (issue #327): adding a protocol requirement to the SDK shifted the witness-table layout, old-SDK plugins loaded fine and then crashed with `EXC_BAD_ACCESS ... at 0x10` inside `TranscriptionEnginePlugin.transcribe`; the other direction failed at `dlopen` with `Symbol not found: _$s20TypeWhisperPluginSDK34DictionaryTermsCapabilityProvidingMp`. Response: an explicit `sdkCompatibilityVersion` in `manifest.json`, `PluginSDKCompatibility.isCompatible(...)`, `IncompatibleExternalBundle.Reason.sdkCompatibility(expected:actual:)`, and a bundled fallback when the external bundle is rejected. **If you ship binary plugins in Swift, you version the ABI on day one.**

**[altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice)** shows the cost of a seam for a feature that isn't there: `Sources/Fluid/Services/PrivateAIProvider.swift` is `#if PRIVATE_AI_PROVIDER` guarding a `PrivateAIProviderBridge` that **does not exist in the repo** (`rg 'PrivateAIProviderBridge'` → 1 hit, that line). ~450 lines of protocols, unavailable shims, a registry with `nonisolated(unsafe)` mutable statics and a bootstrap `installOnce`, all guarding an absent binary.

**Conclusion for Parla: don't.** A protocol + a factory function inside the same module gives every benefit at zero ABI cost. Parla already has exactly this for cleanup — `CleanupProviding` + `makeCleanupClient(...)` in `Sources/ParlaCore/CleanupFactory.swift` — and it works. ASR simply hasn't been given the same treatment.

---

## 6. Persistence

| Repo | Settings | History / transcripts | Migration story |
|---|---|---|---|
| [cjpais/Handy](https://github.com/cjpais/Handy) | `tauri-plugin-store` JSON | SQLite (rusqlite + `rusqlite_migration`, 4 migrations) | versioned migrations |
| [watzon/pindrop](https://github.com/watzon/pindrop) | UserDefaults | SwiftData, `TranscriptionRecordSchema.swift` **2,017 lines**, V1→V12 | 4 dedicated migration test suites |
| [Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli) | UserDefaults / TOML | GRDB SQLite (`DatabaseManager.swift`, 1,547 lines) | long chain |
| [moona3k/macparakeet](https://github.com/moona3k/macparakeet) | TOML via `toml_edit` (comments survive) | SQLite | — |
| [EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter) | CRDT workspace (Yjs) | immutable blobs (`@epicenter/blobs`) | schema is release-local policy |
| [goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr) | `config.json` | none | `share/config.schema.json` **kept in sync by `tests/test_config_schema_sync.py`** |
| [peteonrails/voxtype](https://github.com/peteonrails/voxtype) | TOML + serde defaults | SQLite (meetings) | `parse_config_with_defaults` + round-trip test |
| **Parla** | `settings.json` (tolerant decode) | `history.json` (cap 50) | **none** |

### SwiftData will cost you five releases

pindrop's is the clearest warning in the corpus: **five separate startup-crash releases** from SwiftData store corruption — #32/#35 (missing `ZPROMPTPRESET`), #74 (first-fetch failure after update), #76/#77 (`SwiftDataError error 1` just from opening Settings → Dictation), #78 (the repair itself bricked stores). PR #80's root cause is the lesson:

> *"The affected store was valid at the SQLite level, and its metadata reported the current model identifier (`V1.0.11`)… However, its physical tables were **missing 11 columns** introduced by earlier lightweight migrations. Because the metadata version matched the inferred version and all expected schema objects existed, `repairIfNeeded` treated the store as healthy without comparing the individual table columns."*

**Version-metadata equality is not a schema health check.** Also: the startup probe fetched *only* `TranscriptionRecord`; the fix probes all nine models at container creation to force deferred schema errors into the repair path before the container is retained. Residual reality, from #77's last comment: *"just updating to v1.22.4 didn't work, I had to uninstall completely and reinstall."*

Parla's JSON files are the right call at this size. What it's missing is versioning.

### Two cheap patterns worth copying today

1. **Schema-sync test** — hyprwhspr's `tests/test_config_schema_sync.py` asserts every config key exists in both `ConfigManager.default_config` *and* `share/config.schema.json`. Multiple voxtype bugs came from keys existing in one surface only (voxtype `4a12dae`: "register inject_mode and stream_start_retry_delay in the config schema"); voxtype #146 shipped a `task: "translate"` setting that was **stored and never passed to the engine**.
2. **Empty-config round-trip invariant** — voxtype `src/config/parse.rs:87` asserts `parse_config_with_defaults("")` TOML-round-trips equal to `Config::default()`, so the hand-rolled default and the serde default can't drift. This exists because of issue #421: a config containing only `[hotkey]` failed with `missing field 'audio'` — *serde's per-field defaults fill in omitted fields, not omitted parent sections*.

Parla's tolerant `init(from:)` in `Sources/ParlaCore/Settings.swift:14-22, 51-65` already handles the field case; the round-trip test is the missing half.

---

## 7. IPC and process isolation

Two unrelated problems share this heading. **Isolation** answers "a native crash must not kill the app." **Control plane** answers "something outside the app must be able to start a dictation." Most projects need both; Parla has neither.

### Control plane: files + signals beats a socket at this size

| Repo | Transport | Commands |
|---|---|---|
| [goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr) | named FIFO + Unix socket in `$XDG_RUNTIME_DIR/hyprwhspr/`, plus SIGUSR1/SIGUSR2 | `start[:lang]\|stop\|cancel\|submit\|model_unload\|model_reload` |
| [peteonrails/voxtype](https://github.com/peteonrails/voxtype) | plain files in `$XDG_RUNTIME_DIR/voxtype/`, **consumed (deleted) on read** | `state`, `cancel`, `output_mode_override`, `profile_override`, `model_override` |
| [moona3k/macparakeet](https://github.com/moona3k/macparakeet) | `macparakeet-cli`, 33 commands, versioned contract (`spec --json`), exit codes 0/1/2/130 | full surface |
| [Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli) | `muesli-cli` sharing the same SQLite file | stdout = machines, stderr = humans |
| **Parla** | none | — |

voxtype's consume-on-read rule is the cheap correctness trick: every override file is deleted the moment it is read (`read_output_mode_override`, `src-tauri/src/daemon.rs:197-260`), with a regression test `test_output_mode_override_file_consumed_after_read`, so a stale override can never leak into the next session. hyprwhspr's `RecordingControlServer.parse_commands` deliberately takes only the **last** valid line of a burst.

Every project with a control plane also has a **single-instance lock** — hyprwhspr `flock` on `$XDG_RUNTIME_DIR/hyprwhspr/hyprwhspr.lock`, vibe `tauri-plugin-single-instance` (whose macOS handshake is documented as racy: *"two processes launched in the same instant can both survive it"*), macparakeet `flock` at `~/.local/share/…/instance.lock` with stale-PID cleanup. Parla has none: a second `Parla.app` launch installs a second CGEventTap and a second status item, and both react to every fn press.

### Model residency is a policy, and it needs an owner

Parla loads one `whisper_context` in `Transcriber.swift:17-26` and frees it only in `deinit` — resident for the process lifetime. Fine at base.en (148 MB); not fine the moment recommendation #2 lands `large-v3-turbo` (1.6 GB) or a user picks `large-v3` (3.1 GB).

Handy's `ModelUnloadTimeout::{Never, Immediately, Min2, Min5(default), Min10, Min15, Hour1}` with a 10 s idle-watcher thread is the shape, and the reason it lives in the host is stated in ADR-0012: *"a backgrounded webview timer throttles exactly when idle eviction must fire."* Two rules worth copying verbatim: the watcher **refuses to unload while recording** (it touches the activity timestamp instead), and `Immediately` is handled after each transcription rather than on the tick so it cannot fire mid-recording. TypeWhisper reaches the same design from the opposite direction — `moinulmoin/voicetypr` shipped `gpu_isolation` specifically so *"No GPU power draw between transcriptions (important for laptops)"*, and macparakeet's `model_keepalive` exists because a resident Vulkan/CUDA context kept an Optimus dGPU out of D3cold and drained a laptop battery in 1–1.5 h (voxtype #591).

### Isolation: native crashes are unrecoverable in-process

| Repo | What's isolated | Mechanism | Why |
|---|---|---|---|
| [thewh1teagle/vibe](https://github.com/thewh1teagle/vibe) | whole ASR runtime | `sona serve --port 0`, one JSON line on stdout | whisper.cpp SIGILL/SIGSEGV containment |
| [moinulmoin/voicetypr](https://github.com/moinulmoin/voicetypr) | Vulkan whisper | sidecar exe, newline JSON | driver abort kills only the sidecar |
| [OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr) | ONNX Runtime | Electron utility process | native `bad_alloc` would kill main |
| [Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli) | MLX local LLM | `NSXPCConnection` to `MuesliRefineXPC` | GPU memory reclaimable by killing the service |
| [amicalhq/amical](https://github.com/amicalhq/amical) | keyboard listener | re-spawns **its own exe**, loopback TCP `set_nodelay(true)` | rdev `grab()` blocks; crashed hook is recyclable |
| [watzon/pindrop](https://github.com/watzon/pindrop) | nothing | — | — |
| **Parla** | nothing | — | — |

vibe's handshake is the one to copy (`desktop/src-tauri/src/sona/process.rs:22-25`): spawn with `--port 0`, read one line of JSON from stdout — `{"status":"ready","port":52341}` — parse into `ReadySignal`. **No polling, no fixed port, no health-check loop.** Both stdout and stderr get reader threads; stderr is retained in an `Arc<Mutex<String>>` capped at 8,192 bytes *so a crash message can be attached to the user-facing error*.

voicetypr's containment is enforced in CI: `windows/assert-no-vulkan-import.ps1` asserts the main exe does not import `vulkan-1.dll`, and `cargo tree -e features -i whisper-rs` asserts Vulkan is off for the app. When the GPU→CPU fallback double-loaded the model (~3 GB spike → OOM), the fix was to unload the failed GPU sidecar *before* the CPU fallback loads.

Two sidecar scars worth pre-empting:
- **Corporate proxies intercept 127.0.0.1.** vibe commit `4548ed3`: `reqwest::Client::builder().no_proxy()` — telemetry showed a user getting a full `<!DOCTYPE html>` login page back from a *localhost* model-load request.
- **Two components caching "is the model loaded" desync.** vibe PR #1259: "Remove Vibe's duplicate model-residency cache and let Sona handle idempotent model loading", after PR #1218 had to add "detect dead cached processes before trusting loaded-model state".

### The non-sidecar alternative

Handy stays in-process and buys safety with `catch_unwind(AssertUnwindSafe(...))` around every engine call: on panic the engine is **not** returned to the mutex (effectively unloading it), `current_model_id` is cleared, a `model-state-changed{unloaded}` event fires, and the next attempt reloads. Release profile keeps `panic = "unwind"` specifically to make this work. `[profile.release] panic = "unwind"` is load-bearing.

**Swift has no `catch_unwind`.** A `GGML_ASSERT` or `abort()` inside ggml is process death, full stop. Handy's own README concedes "Whisper models crash on some Windows/Linux configurations" and the fix is unknown — their defense is survive-rather-than-fix, and Swift doesn't offer even that.

---

## 8. Where Parla's structure breaks

### What's already right

- `ParlaCore` genuinely is a library — 12 files import only `Foundation`; only `Inserter.swift` and `Hotkey.swift` touch AppKit, both because CGEvent/AX require it. `parla-eval` links it and runs headless.
- `Sources/ParlaCore/Hotkey.swift` **is** a pure state machine with injected time and 18 unit tests covering autorepeat, shift-latching, and swallow-vs-pass per chord. The pattern is already in the codebase.
- `Sources/ParlaCore/Streaming.swift` (`StreamWindow`) and `LiveTyper.swift` are pure value types, fully tested.
- `CleanupProviding` + `makeCleanupClient` is a correct provider abstraction — and the Hub's config banner calls the *real* factory (`HubPages.swift:147-162`) so it cannot disagree with runtime.
- `AbortBox` gives cooperative cancellation of `whisper_full`, which most of the corpus lacks.

### Where it breaks, feature by feature

| Feature you will add | What breaks | Sites to edit today |
|---|---|---|
| Second whisper model (`large-v3-turbo`) | `defaultModelPath()` hardcodes `ggml-base.en.bin`; `downloadModel()` hardcodes one URL; `"~148 MB"` is a literal in two files; eval hardcodes the path | `Transcriber.swift:11-15`, `main.swift:923`, `main.swift:1001`, `HubPages.swift:35`, `parla-eval/main.swift:43` |
| Non-English dictation | `language` is never set → framework default `"en"` with `detect_language=0`. `scripts/download-model.sh` already fetches multilingual models that would still decode English. | `Transcriber.swift:30-79` |
| Parakeet / a cloud STT fallback | `WhisperTranscriber` is a concrete class with no protocol; `transcriber: WhisperTranscriber?` is typed on `AppDelegate` and threaded through `finish`/`transform`/`stream` | `Transcriber.swift`, `main.swift:33,696,762` |
| Live streaming insertion | `liveTyping = false` hard-coded; `StreamWindow.join` is a bare `" "` concat with no overlap/agreement reconciliation; `Settings.liveStreamingEnabled` is dead code | `main.swift:179`, `Streaming.swift`, `Settings.swift:43` |
| Long-form / meeting mode | `samples: [Float]` grows unbounded at 64 KB/s (~230 MB/hour) with no cap; `snapshot()` copies the whole buffer every ~300 ms | `AudioRecorder.swift:11,169-173` |
| A second concurrent job (file transcribe, re-transcribe from history) | one `processTask` FIFO chain, no priority, no reserved interactive slot — a queued file job delays the next dictation | `main.swift:186,211,229,304,773` |
| Any second session-state field | 7 correlated fields on `AppDelegate` (`isRecording`, `liveTyping`, `focus`, `typed`, `commandMode`, `commandSelection`, `window`) with no invariant, mutated from ≥5 call sites | `main.swift:21-74` |
| Settings schema change | 4 unversioned stores + UserDefaults; one ad-hoc migration already runs on **every** HUD init | `Settings.swift`, `History.swift`, `Scratchpad.swift`, `HUD.swift:143` |
| A larger model (`large-v3-turbo`, 1.6 GB) | context is loaded once and freed only in `deinit` — no unload policy, no idle watcher, resident forever | `Transcriber.swift:17-28` |
| CLI / agent / Shortcuts control | no control surface at all: no CLI, no socket, no file trigger, no URL scheme | — |
| A second app launch | no single-instance lock → two CGEventTaps, two status items, both fire on fn | `main.swift:87-262` |
| Any ggml crash | whisper in-process, Swift cannot `catch_unwind` a C++ abort | `Transcriber.swift` |

### Three structural observations

1. **`isRecording` is a second copy of recorder state.** Epicenter derives capture state from the recorder rather than mirroring it (`state/dictation-lifecycle.svelte.ts`: "capture is *derived* from the recorder machines… never a second copy"). Parla's `isRecording` is written on main and read from the streaming loop *and* from inside the C abort callback on whisper's compute threads — flagged in-code as a benign race (`main.swift:701`), which it is today and won't be after one more reader.

2. **"The chain is the synchronization" is a comment, not a type.** `self.window: StreamWindow?` is written by `stream()`, read by `finish()`, and nil'd by `cancelDictation()` — three tasks, correct only because all three are queued on `processTask` in order. `Streaming.swift:8-10` and `main.swift:45-47,757-759` say so explicitly. Nothing in the type system or a test enforces it. Handy replaced exactly this with generation counters plus explicit atomics; TypeWhisper with `streamingLifecycleEpoch`.

3. **The shadow stream is pure waste below 15 s.** With `liveTyping` permanently false, `stream()` burns a full `whisper_full` pass every ~300 ms and discards the result; the only retained output is `confirmed`, which is written only after the tail exceeds `StreamWindow.threshold` = 15 s. For every dictation shorter than that — the overwhelming majority — it is continuous Metal work for zero benefit. Epicenter faced the same choice and *documented a refusal* (ADR-0016: streaming and chunked partials rejected, "chunk-and-stitch carries a permanent boundary-accuracy tax"), then spent its effort on a measured 1 s cold-model-load prewarm instead.

---

## What Parla should do

Ordered by value per line of code. Effort: S ≤ half a day, M ≤ two days, L ≥ a week.

**1. Extract `DictationSession` as a pure state machine into `Sources/ParlaCore/`. (M)**
`(State, Event) -> (State, [Effect])`, zero AppKit, modelled on macparakeet's `DictationFlowStateMachine.swift`. States: `idle | starting(mode) | recording(mode) | pendingStop(mode) | processing | inserting`. Absorb the 7 correlated `AppDelegate` fields. Every async completion event carries the existing `generation`; the reducer drops stale ones. `main.swift`'s `onEdge` switch becomes an interpreter that executes `[Effect]`. This is the enabling change for everything below — and Parla already proved the pattern works one layer down in `Hotkey.swift`. Target: `main.swift` under 500 lines.

**2. Give `Transcriber.swift` a protocol and a factory. (S)**
`protocol Transcribing { func transcribe(_:initialPrompt:shouldAbort:) throws -> String }` plus `makeTranscriber(settings:) throws -> Transcribing`, mirroring the shape of `CleanupFactory.swift` that already works. Move the model path, URL and size out of five hardcoded sites into one catalog struct. Copy voxtype's `as_streaming() -> Option<...>` idea as `var streaming: StreamingTranscribing? { nil }` so future engines advertise capability rather than the app consulting a table.

Ship an **unload policy in the same change**, not after. Today the context is freed only in `deinit` (`Transcriber.swift:28`), which is fine at 148 MB and wrong at 1.6–3.1 GB. Handy's shape: a `ModelUnloadTimeout` enum defaulting to 5 min, a 10 s idle watcher that **refuses to unload while recording** (it touches the activity timestamp instead), and an `Immediately` case handled after each transcription rather than on the tick so it cannot fire mid-recording.

**3. Set `params.language` explicitly and delete the dead `flash_attn` line. (S)**
`Transcriber.swift:21` sets `flash_attn = true`, which v1.9.1 already defaults to — the comment is stale. More importantly `language` is never set, so multilingual models silently decode English (`detect_language = 0`). Add a `Settings.language` field (`"en"` / `"auto"` / BCP-47) and thread it through. voxtype's `resolve_whisper_prompt` (`src/transcribe/backends/base.rs:108`) is the other half worth copying: their shipped English prompt applies **only** when the detected language is English or unknown, because *"A prompt written in one language pulls the decoder toward that language"* (voxtype #233 — a Portuguese speaker got English out while the log correctly printed `[LANG] auto-detected: pt (p=1.00)`).

**4. Decide the shadow stream: delete it or make it earn its keep. (S to delete, L to finish)**
Today it is a `whisper_full` pass every 300 ms whose output is discarded for every dictation under 15 s. Either (a) gate `stream()` on `samples.count > StreamWindow.threshold` so short dictations never start it — pure win, ~5 lines — or (b) commit to live insertion and pay for the reconciler. If (b), copy pindrop's `LiveTranscriptStabilizer` shape: hold back the last 3 words as volatile, align each pass by longest committed suffix (≤6 words), commit-only typing, and count backspaces in **Unicode scalars, not bytes**. Note Parla's Linux never-send-BackSpace rule makes commit-only mandatory, not optional. Also fix `StreamWindow.join`'s bare `" "` concat — it's the seam where duplicate words appear.

**5. Process and capture lifecycle safety: single-instance lock, buffer cap, interruption reason. (S)**
There is no single-instance guard anywhere in `main.swift` — a second launch installs a second CGEventTap and a second status item, and both fire on every fn press. Every project in the corpus with a global hotkey has one (hyprwhspr and macparakeet use `flock` with stale-PID cleanup; vibe uses `tauri-plugin-single-instance` and documents its macOS handshake as racy). Ten lines.

`AudioRecorder.samples` is unbounded at 64 KB/s. Add `CaptureLimits.maxSamples` (Epicenter uses 10 min at 16 kHz = ~40 MB, `AudioRecorder.swift:446`, because "batch inference currently accepts one contiguous Data value"). Separately, adopt Epicenter's `end_capture` vs `stop` split: a mic that dies mid-dictation should mark the recording ended with a typed reason (`deviceDisconnected | permissionRevoked | streamFailed`) and let the ordinary stop path finalize whatever was captured, rather than silently producing nothing.

**6. Fix the per-buffer `AVAudioConverter`. (S)**
`AudioRecorder.convert(_:)` constructs a **new** converter for every tap buffer and drains it with `.endOfStream`, so 48 kHz→16 kHz resampling restarts its filter at every ~85 ms boundary — a discontinuity per buffer for the whole recording, and an allocation on the realtime thread. Cache one converter keyed on `(inputFormat, outputFormat)` (TypeWhisper's `ReusableAudioConverter`, `AudioRecorder.swift:210-300`, also keeps a free-list of 4 output buffers). Converter failure currently returns `[]` silently — count it and surface it.

**7. Version the settings file and add the two cheap invariant tests. (S)**
Add `schemaVersion: Int` to `Settings`. Add hyprwhspr's schema-sync test in spirit (every `Settings` field is reachable from the Hub or documented as file-only) and voxtype's round-trip invariant: `Settings(from: emptyJSON)` must equal `Settings()`. Fold `hudDockEdge`/`hudDockOffset` out of UserDefaults into `settings.json` and delete the `removeObject(forKey: "hudOrigin")` migration hack that runs on every HUD init (`HUD.swift:143`).

**8. Take Handy's model-download hardening wholesale. (M)**
`installModel(from:)` currently **deletes the existing model before the move** (`main.swift:952`) — a failed move leaves the user with nothing. Add: sha256 in the catalog, verify after download, delete-on-mismatch, `.part` staging + atomic rename, `ATTEMPT_STREAMS: [4,1,1,1]` backoff, and a stall watchdog. macparakeet re-hashes pre-existing files on every run so a corrupt cache can't survive an upgrade — cheap and worth it.

**9. Add a reserved interactive slot before adding a second job type. (M, deferrable)**
Not needed today — one `processTask` FIFO is correct for one job type. Needed the moment file transcription, re-transcribe-from-history, or meeting mode exists. macparakeet's `STTScheduler` two-slot design (`STTScheduler.swift:853-885`) is the target; do it when the second job type lands, not before.

**10. Sidecar the whisper context. (L, defer until a crash report justifies it)**
Swift cannot `catch_unwind` a ggml `abort()`. Every project that hit real ggml crashes ended up isolating (vibe, voicetypr, OpenWhispr). vibe's `--port 0` + one-JSON-line handshake is the minimum-ceremony version, and retaining the child's stderr in a capped buffer so the crash message reaches the user error is the detail that makes it worth doing. **Do not build this speculatively** — but instrument first: log whisper model+params on every load so the first crash report is actionable.

**11. Add a control surface — one file trigger, not a CLI. (S, when someone asks)**
Parla is drivable only by fn. The cheapest useful version is voxtype's: a small set of files under `$XDG_RUNTIME_DIR`-equivalent (`~/Library/Application Support/Parla/run/`) polled on the existing timer — `state` for readers, and `start`/`stop`/`cancel` triggers **consumed on read** so a stale trigger can never leak into the next session (voxtype has a regression test for exactly that). That unlocks Shortcuts, Raycast, Karabiner and agent control without building macparakeet's 33-command CLI. Do not build a socket until a second consumer exists.

Explicitly **not** recommended: SwiftData (pindrop's five crash releases), a plugin SDK (TypeWhisper's ABI roulette, FluidVoice's 450 lines guarding an absent binary), or moving orchestration out of Swift (voquill's "TypeScript is the Brain").
