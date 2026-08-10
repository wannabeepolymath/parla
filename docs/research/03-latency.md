# Latency: A Full Budget for One Dictation Turn

Dictation is judged on two numbers users can feel: *did it catch my first word*, and *how long after I let go does text appear*. This doc reconstructs the whole turn — keypress → mic hot → first sample → partial → hotkey-up → final transcript → LLM polish → text landed — and for each segment lists every optimization found across 24 audited repos with the file it came from and its measured saving. Almost every number here is quoted from a repo that measured it; where a repo only asserted, it says so.

**The one-line finding:** across the corpus, *perceived* dictation latency is dominated by plumbing, not inference. [watzon/pindrop](https://github.com/watzon/pindrop) `plans/028-transcription-latency-streaming.md` measured **~950 ms of pure fixed plumbing per dictation** against a decode that costs tens of milliseconds. Parla is already good at the back half (instant raw finalize) and pays the full price on the front half (cold mic every press).

---

## 0. The budget

Per-segment cost. "Parla today" is derived from Parla's own source constants and comments; "best in corpus" is the lowest measured figure any repo achieved.

| # | Segment | Parla today | Best in corpus | Source of the best figure |
|---|---|---|---|---|
| 1 | keypress → capture API called | ~0 ms + one sync `store.load()` JSON read | 0 ms | `Sources/Parla/main.swift:134` vs Handy `actions.rs` (settings cached) |
| 2 | capture start → device open | full `AVAudioEngine` + `installTap` + AUHAL device set, every press | **~0.1 ms** (clone a held stream) | OpenWhispr `src/helpers/micStreamHold.js` |
| 3 | device open → first PCM callback | not measured, not instrumented | 95 ms median, **240–270 ms built-in / 650–700 ms USB** press→first-buffer | FluidVoice `docs/research/instant-dictation-warm-mic-2026-06.md` |
| 4 | audio lost before capture is live | **all of it** (no pre-roll) | **0** (0.45 s ring prepend) | FluidVoice `AudioRecorder.swift`, macparakeet `AudioRecorder.swift` |
| 5 | during speech: partial → screen | none (shadow only, `liveTyping` hard-false) | 160–560 ms chunk cadence | Muesli `FeatureModelType.swift`, openless `parakeet.rs` |
| 6 | during speech: wasted compute | **~3.5 s GPU per 10 s dictation** (see §3) | 0 | Parla `main.swift:696-760` |
| 7 | hotkey-up → final transcript | ~130–200 ms warm encode (Parla's own measurement) | ~60 ms/s of audio warm; **1245 ms cold** | Parla `Transcriber.swift:44-45`; epicenter ADR-0016 |
| 8 | model cold-start, if unwarmed | avoided (silence warm-up at load) | avoided | Parla `main.swift:773-780` ✅ |
| 9 | transcript → LLM polish | **off the critical path** (raw lands first) | off the critical path | Parla `main.swift:400-477` ✅ |
| 10 | LLM round-trip | ~1 s, invisible | ~1 s | epicenter ADR-0099 |
| 11 | text landed (insertion) | ~150 ms main-thread `usleep` per 600 chars + up to 3× 50 ms AX wake | sub-10 ms | Parla `Inserter.swift:56,99`; hyprwhspr `dotool.rs:9-40` |

Segments 2–4 are Parla's entire gap. Everything from 7 onward is already at or near best-in-class.

---

## 1. keypress → mic hot

### The measured cost of a cold open

FluidVoice is the only repo that instrumented this properly, from real user diagnostic logs (issue #450 triage), `docs/research/instant-dictation-warm-mic-2026-06.md`:

| Phase | Median |
|---|---|
| `dictation_capture_start` → `shared_mic_engine_input_device_started` | **563 ms** |
| `dictation_capture_start` → `dictation_capture_engine_started` | **568 ms** |
| `dictation_capture_start` → `dictation_capture_first_buffer` | **662 ms** |
| `dictation_capture_engine_started` → first buffer | **95 ms** |

And the distribution is bimodal by device: **built-in ~240–270 ms, USB ~650–700 ms**.

Corroborating figures elsewhere in the corpus:

- **cjpais/Handy** `managers/audio.rs`: device enumeration **~40–110 ms**; `recorder.rs` HAL config query **~40–85 ms per open** ("worse on USB/Bluetooth"); mic first-callback **~10–200 ms on macOS, longer on Bluetooth/USB**.
- **Open-Less/openless** `coordinator/dictation.rs:2745-2760`: *"`Recorder::start` returning Ok only means `cpal Stream::play` completed, not that the audio thread is pushing PCM — macOS CoreAudio has a **50–200 ms** gap between AudioUnit start and the first `process_callback`."*
- **OpenWhispr** `micStreamHold.js` / `audioManager.js`: Windows WASAPI cold open is *"hundreds of ms, up to 10–15 s worst case"*.
- **hyprwhspr** issue #153: first recording after ~10 s idle failed outright with `paTimedOut` because PipeWire suspended the node.

### The fixes, ranked by measured saving

**(a) Split `prepare()` from `start()`.** VoiceInk (`Sources/VoiceInk/Services/CoreAudioRecorder.swift`) does everything expensive — `AudioComponentInstanceNew`, device binding, format negotiation, `AudioUnitInitialize` — at app launch and on every device-change notification, so the hotkey path is a single `AudioOutputUnitStart`. FluidVoice's version (`ASRService.swift:920-950`) is the same idea with an explicit privacy justification:

> *"Prepares the direct device callback without starting hardware IO. This keeps the default idle state privacy-friendly while removing device and ring allocation from the hotkey path."*

and at stop (`:1859-1865`):

> *"A prepared direct IOProc owns only fixed memory and registration; it does not run hardware, show the mic indicator, or hold Bluetooth in headset mode. Keep it prepared across idle periods."*

**(b) Keep a warm stream and hand out clones.** OpenWhispr's `micStreamHold.js` header states the number:

> *"Opt-in idle-hold: keep one 'master' mic stream open after a dictation so the next one re-acquires in **~0.1ms** (`track.clone`) instead of paying a cold driver open."*

Recordings only ever get `makeStream(track.clone())`, so releasing the master can never interrupt a live recording. Warmth is a **timestamp, not a latch** (`micWarmState.js`): `MIC_WARM_TTL_MS = 5000`, with `WARMUP_ACQUIRE_TIMEOUT_MS = 15000` kept deliberately independent because *"the cold-open worst case documented in audioManager is 10–15 s, and a machine that slow is exactly the one whose eventual success must still be recorded as warm."*

**(c) Do the hardware start off the main thread.** VoiceInk wraps `AudioOutputUnitStart` in a continuation on a dedicated `.userInitiated` serial queue with the comment *"Offload hardware start to avoid shortcut lag."* Muesli's postmortem of the same problem (`docs/2026-07-11-performance-and-correctness-audit.md`) notes that `await` on a `@MainActor` type doing synchronous work does **not** move it off the main actor — a real trap.

**(d) One device open per session, negotiated in a single pass.** macparakeet `AudioRecorder.swift:458-540` merged three separate PortAudio opens (channel probe, rate probe, real open) into one negotiation — candidate rates `[device_default] + [48000,44100,32000,22050,16000,8000]`, mono before stereo, **the first stream that opens is the one used**. Motivation was Bluetooth SCO heap corruption (#567), but it is also the single biggest start-of-session win in that codebase.

### Parla's state

`Sources/ParlaCore/AudioRecorder.swift:133-165` builds the tap and starts the engine inside `start()`, called synchronously from the fn-down handler (`main.swift:169`). `stop()` (`:175-181`) removes the tap and stops the engine. So **every dictation pays a full cold open**, and there is no instrumentation to say how much. `main.swift:134` additionally does a synchronous `store.load()` — a JSON file read and decode — on the keypress path, and `stream()` does it again at `:697`.

---

## 2. Pre-roll: the audio you already lost

Even with a warm mic, the first buffer arrives after the press. Two repos solve it identically, and they converged on the same constants.

**FluidVoice** `Sources/Fluid/Services/preparedMicCapture.swift` + `AudioRecorder.swift`: on hotkey key-*down*, `sendPrepareDictation()` opens the mic and starts a `MediaRecorder` at a 250 ms timeslice immediately, buffering into `prepared.chunks`. Only after `MIN_HOLD_DURATION_MS = 150` does the real start fire — and `recordingStartTime = prepared.startedAt`, so the pre-roll is *kept*. Guards: `PRE_ROLL_MAX_AGE_MS = 2000` discards stale pre-roll (stream retained), `PREPARED_MAX_AGE_MS = 10000` expires a forgotten prepare, and a generation counter stops a stale acquisition clobbering a newer one. The class comment records what it replaced:

> *"Replaces the one-shot `warmupMicDriver` (#845): a raced warm-up never resolved before the recording's own open, so it only ever added a concurrent double open."*

**moona3k/macparakeet** `Sources/MacParakeetCore/Audio/AudioRecorder.swift:37-90`: `DictationPreRollRingBuffer`, capacity `Int(Double(ASRConstants.sampleRate) * 1.0)` = **16,000 samples (1.0 s)**, updated from the audio tap under `OSAllocatedUnfairLock`, and:

```swift
static let preRollPrependSamples = Int(Double(outputSampleRate) * 0.45)  // 0.45 s
```

Both credit `kitlangton/Hex` as the reference implementation (1 s ring, 0.45 s prepend).

**The non-obvious guard, worth copying verbatim** (FluidVoice #474): if system media was confirmed playing at press time, the pre-roll contains pre-press *media* audio that no pause can silence — so it's discarded (`discardPreRollForActiveCapture` trims `preRollFramesWritten` from the WAV head) and the session is marked degraded rather than transcribed.

**Handy's cheaper variant of the same insight** (`audio_toolkit/audio/recorder.rs`, `run_consumer`): drain the pending `Cmd::Start` *before* processing the in-flight audio chunk.

> *"Commands used to be polled after processing, which silently dropped one buffer period of audio (~10ms built-in, up to ~100ms on Bluetooth) at every recording start."*

Handy also runs a Silero VAD with `VAD_PREFILL_FRAMES = 15` — 450 ms of pre-roll frames replayed on speech onset — the same 0.45 s number arrived at from a different direction.

**Parla has no pre-roll of any kind.** `AudioRecorder.samples` starts empty at `start()` (`AudioRecorder.swift:135`). The `shortTapThreshold = 0.2` in `Hotkey.swift:33` mitigates the *opposite* problem (accidental Globe taps) but does nothing for onset loss.

---

## 3. During speech

### Model warmth

Everyone converged on the same trick: run one throwaway inference on silence at load so the graph/kernel specialization is paid before the user's first word.

| Repo | File | Warm-up input | Stated saving |
|---|---|---|---|
| Parla | `main.swift:773-780` | 16,000 zero samples (1 s) | *"Metal shader/graph setup (hundreds of ms)"* ✅ |
| TypeWhisper | `NemotronStreamingEngine.swift:126-136` | 19,200 zeros (1.2 s, covers both chunk profiles) | *"CoreML specializes kernels lazily on the first prediction, not at load"* |
| OpenWhispr | `parakeetWsServer._warmUp()` | 16,000 samples of silence | *"eliminate first-request latency from JIT compilation"* |
| macparakeet | `CohereTranscribeEngine.swift:727-741` | 1 s of zeros | **~115 s** GPU-path specialization vs **~2 s** on ANE |
| OpenWhispr | `whisper.js:initializeAtStartup` | resident `whisper-server` | *"eliminates 2-5s cold-start delay"* |

macparakeet's benchmark table (`benchmarks/asr/README.md`, M4 Pro 48 GB, macOS 15) is the only committed cold-start comparison in the corpus: parakeet-v3 **0.38 s**, parakeet-v2 0.55 s, unified 0.93 s, nemotron-en 0.87 s, **whisper large-v3-turbo 2.29 s**, cohere **73 s**. Steady-state RTFx: ~81–93× Parakeet, **~14× Whisper**, ~11× Cohere.

Two failure modes worth naming:

- **Sleep evicts the model from VRAM.** OpenWhispr `whisper.js:shouldRewarmOnWake`: *"Only re-warm a running local GPU whisper-server: sleep evicts its model from VRAM. Skip remote/CPU servers, and skip while a transcription is in flight (#766)."*
- **Idle-unload can be an anti-optimization.** voicetypr sets `SIDECAR_IDLE_DISPOSE_MS = 60_000` — kill the whisper sidecar after 60 s idle. For a bursty dictation app that means *cold is the norm*, exactly the argument OpenWhispr issue #1207 makes: *"Dictation is bursty: short utterance, then minutes of reading or editing. Most bursts land past the 5 min window, so cold is the norm, not the exception."*

### Streaming that actually costs something

The important negative results:

**epicenter ADR-0016 refused streaming outright**, after measuring: *"streaming and chunked partial transcription… chunk-and-stitch carries a permanent boundary-accuracy tax."*

**pindrop `plans/028` is the definitive whisper.cpp note** and it is bad news for the naive approach:

> *"whisper-rs 0.16 has **no KV-reuse streaming API** (`state.full` takes a complete slice; true incremental decode needs patching whisper.cpp's C core), so 'streaming Whisper' is either naive sliding-window re-decode or segmented decode-ahead."*

But the same plan names the two knobs Parla is not using:

- `set_audio_ctx(n)` for short clips
- **`set_segment_callback_safe(SegmentCallbackData)`, which fires *during* `state.full` and yields completed-segment text live** — the actual streaming primitive for whisper.cpp, no re-decode required.

And the reference algorithm (`itsmontoya/scribble`, `incremental.rs`, ~100 lines): growing buffer → decode at min-window → emit all-but-last segment as final → **advance the buffer head past emitted audio** so finalized audio is never re-decoded.

pindrop's guardrail is the right one to steal verbatim: *"If a streaming partial is ever pasted and then revised in a user's app → stop; fall back to insert-at-stop. Never corrupt the user's document for 'juice.'"*

**FluidVoice's default engine does the naive thing and it's a documented weakness** (`ASRService.processStreamingChunk`): it grabs `audioBuffer.getPrefix(currentSampleCount)` — the *entire buffer from t=0* — and re-transcribes every tick. Their own audit calls it O(n²). The correct pattern (`ParakeetRealtimeProvider.consumeDelta`) exists in the same repo, unused by the default path.

### Parla's shadow stream is the most expensive thing on this list

`main.swift:696-760` runs the pass loop on **every** dictation. Do the arithmetic from Parla's own constants:

- gate: `snap.count - lastCount >= 8000` → 0.5 s of new audio (`main.swift:704`)
- `pauseBetweenPasses()` = 6 × 50 ms = 300 ms (`main.swift:676-681`)
- one whisper pass ≈ **130–200 ms warm** (Parla's own comment, `Transcriber.swift:44-45`)

→ ~2 passes/sec, each ~150–200 ms → roughly a **30–40 % GPU duty cycle for the entire duration of every dictation**. A 10 s dictation burns **~3.5 s of Metal work**.

And below the 15 s threshold, all of it is discarded: `StreamWindow.threshold = 15 * 16_000` (`Streaming.swift:20`), so `confirmed` stays empty and `self.window` is never set (`main.swift:757-759`). Typing is gated on `guard self.liveTyping else { return }` (`main.swift:737`) and `liveTyping` is hard-coded `false` at `main.swift:179`. **For any dictation under 15 s the loop produces zero output for ~3.5 s of compute.**

The README overclaims on the back of it (`README.md:95`): *"Release latency is therefore independent of how long you dictated."* No cut occurs until the tail exceeds 15 s, so a 14 s dictation re-encodes the whole buffer at fn-up. In practice this barely matters — `audio_ctx` is left at the full 30 s window (`Transcriber.swift:42-45`), so the *encode* is constant regardless — which is precisely why the shadow stream buys so little.

---

## 4. hotkey-up → final transcript

Parla's back half is genuinely good, so this section is mostly confirmation plus two cheap additions.

**Abort the in-flight pass at release.** Parla does this correctly with a boxed C abort callback (`Transcriber.swift:51-56, 96-99`) plus an `isRecording` recheck *before consuming* every result (`main.swift:720, 733`). openless's equivalent is `cut_streaming_audio()` (`coordinator/dictation.rs:971-978`), and its rationale is a quality fix Parla should also want:

> *"the ~50–100 ms of residual samples between the user's stop press and the actual mic shutdown leak in as low-level noise and cause hallucinated trailing tokens."*

**Pad the tail with silence — but only for non-Whisper models.** macparakeet `STTRuntime.swift` sets `dictationTrailingSilenceSeconds = 0.5`:

> *"Without the pad the TDT decoder can drop a fast final word that lands right on the end of the recording… FluidAudio's own fixed-size input padding does not help because the decode is bounded to the real (pre-pad) audio length."*

and — critically — *"never applied to Whisper because trailing silence there triggers hallucinations."* Parla is Whisper-only, so this is a **do not copy** entry.

**Bound the stop teardown.** epicenter `recorder/recorder.rs` uses `CAPTURE_CLOSE_TIMEOUT = 50ms` waiting for the channel to prove closed, because *"cpal's macOS backend does not promise the sender is gone"* after `drop(stream)` returns. openless sliced its watchdog sleep to `WATCHDOG_SLEEP_SLICE_MS = 50`, cutting worst-case stop wait **1000 ms → 50 ms**. Parla's `pauseBetweenPasses` uses the same 6×50 ms slicing trick for the same reason (`main.swift:677-680`) ✅.

**Everything else at this stage is noise.** epicenter ADR-0184 measured in-process PCM handoff vs a file round-trip at **under 4 ms**, and WAV write + fsync + read + decode at **14–79 ms** across 5–60 s clips — then refused the optimization as not worth weakening the "recording is saved before transcription" invariant.

---

## 5. Transcript → LLM polish

**Parla already has the correct architecture and should not change it.** Raw lands at the cursor before the POST is issued (`main.swift:400-477`); the cleaned text swaps in behind it under `canEraseTyped` verification. epicenter deliberately chose the opposite (`pipeline.ts:107-136`, ADR-0099 — hold delivery, mask ~1 s behind a HUD) with an argument worth knowing:

> *"Delivery is single-write to the cursor (deliver-after-polish)… delivering raw then polished would land two copies (a clipboard the user might paste mid-polish, or two cursor pastes)."*

Parla's `LiveTyper.swapPlan` + `Inserter.canEraseTyped` is exactly the machinery that makes the two-write version safe, so the tradeoff resolves the other way here.

**Warm the connection at record-start, not at transcript-ready.** voicetypr `commands/audio.rs:4154-4181` fires a HEAD at the STT origin and a `warm_ai_provider()` the instant recording begins, overlapping DNS+TCP+TLS with the user speaking. Measured cost of *not* doing it, voicetypr PR #106: `http_client()` rebuilt a fresh `reqwest::Client` per call, *"discarding the connection pool every request (~100–400 ms DNS+TCP+TLS every transcription)"*. Parla does this already (`main.swift:139-145`, HEAD with `timeoutInterval = 5`) ✅.

**Prewarm the prompt itself.** ghost-pepper `Cleanup/TextCleanupManager.swift:837-896` is the cleverest idea in the corpus for a *local* model: split the chat template on two sentinel tokens (`<|ghost-pepper-system-prefill-split|>`, `<|ghost-pepper-user-prefill-split|>`), call `prepareContext(for: plan.contextPrefix)` at hotkey-down, and reassemble only the dynamic tail at inference. The ~1,500-token system prompt is prefilled *while the user is still speaking*. Its cloud analogue — which nobody in the corpus does — is keeping the prompt byte-identical across calls so provider-side prefix caching hits, plus explicit `cache_control` for Anthropic. Parla's prompt is already static per-config (`Cleanup.swift:41-76`) so half of that is free.

**Avoid reasoning models for polish.** voicetypr `plans/030`: *"AVOID reasoning models (gpt-5-nano/mini, o4-mini, gemini-3.x-flash) — hidden reasoning tokens add 1–3 s latency, fatal for polish."* Handy disables reasoning per-provider and memoizes the rejection so later dictations skip the doomed attempt (`llm_client.rs`). ghost-pepper's measured local numbers: Qwen 3.5 0.8B ~1–2 s, 2B ~4–5 s, 4B ~5–7 s.

---

## 6. Polish → text landed

pindrop's line-item table (`plans/028`) is the reference budget for the insertion tail, and it is a clipboard design — but its component costs map onto Parla's keystroke design:

| Step | pindrop cost |
|---|---|
| pre-insert UI-stabilize sleep | 50 ms |
| `insert_text` pre-delay | 50 ms |
| clipboard set + settle | 50 ms |
| macOS paste via rdev (pre 50 + initial 50 + 4×50) | **300 ms** |
| clipboard restore (blocking) | **500 ms** |
| **total** | **~450 ms before text appears + 500 ms blocking restore ≈ 950 ms** |

Their fixes, all shipped: rewrite the paste as a direct CGEvent ⌘V with the Command flag set *on the V events themselves* (300 → 30 ms), tier the pre-paste delay (**0 ms macOS** / 20 ms Windows / 50 ms Linux, with `if !delay.is_zero()` so a 0 skips the sleep entirely), cut the clipboard settle to 15 ms on macOS, and move the restore to a background thread.

**hyprwhspr's number is the starkest** (`lib/src/output/dotool.rs:9-20`):

> *"The ~700 ms uinput device setup is paid once at daemon startup, not on every typed segment. **Sub-10 ms per call.** Strongly recommended for streaming backends, where 60+ output() calls land per session — without the daemon, the first call alone stalls for nearly a second."*

**Skip AX reads on the hot path.** OpenWhispr `ipcHandlers.js:2337`: *"macOS prepend-mode (`getPrecedingChar`) is intentionally skipped here — its Accessibility read costs **hundreds of ms**, too slow for the paste hot path."* Amical caps its AX extraction at `EXTRACTION_TIMEOUT_MS = 600` and uses a 2 s RPC timeout rather than the 5 s default.

**Parla's insertion cost, from its own constants** (`Inserter.swift`):

- 20 UTF-16 units per chunk, `usleep(5_000)` between chunks (`:25, :56`) → a 600-char transcript ≈ 30 chunks ≈ **150 ms of blocking `usleep` on the main actor**
- `usleep(5_000)` per backspace (`:74`) → a 200-grapheme swap erase ≈ **1 s**
- `usleep(50_000)` for the Electron AX wake-up (`:99`), reachable up to 3× per dictation (fn-down `main.swift:163`, finalize re-check `:407`, swap re-check `:515`) → **up to 150 ms**

openless (`unicode_keystroke.rs`) uses `INTER_KEYSTROKE_DELAY = 1 ms` per codepoint on macOS — 5× tighter than Parla's per-chunk 5 ms — with the comment *"Chromium / Electron / Tauri itself drop characters when keyDown/keyUp have no gap."* Windows there batches at `SENDINPUT_CHUNK_CHARS = 16` / `SENDINPUT_CHUNK_DELAY = 12 ms`.

---

## 7. The AirPods / Bluetooth problem

This is the one place where the naive latency fix is a **regression**, and eight repos independently learned it.

### The mechanism

Opening a Bluetooth *microphone* forces the link from A2DP (high-quality playback, no mic) into HFP/SCO (16 kHz mono mic, degraded playback). The renegotiation takes real time and produces garbage audio while it happens.

| Symptom | Measured | Source |
|---|---|---|
| HFP/SCO start tax | **~500–600 ms** (daemon-side, not the graph) | openless PR #388 validation |
| Cold BT/HAL activation outlier | **~4 s** | Handy PR #151 traces (first buffer 336–857 ms typical) |
| Cold-open worst case, any device | **10–15 s** | FluidVoice `audioManager.js`; OpenWhispr WASAPI |
| Digital silence during A2DP→HSP/HFP switch | **~1 s of exact zeros** | vocalinux issues #62, #136 |
| Playback quality while mic held | A2DP → 16 kHz mono for the whole session | Handy #96, #1885; macparakeet #481 |
| Battery cost of a held BT mic | **6–8 days → 1–2 days** (hearing aids) | macparakeet #481 |

### The traps

**Trap 1 — a warm-mic optimization becomes a system-wide audio regression.** Handy shipped `lazy_stream_close` (`STREAM_IDLE_TIMEOUT = 30s`) and documented the tradeoff explicitly: it *"keeps the mic actively capturing while idle — degrading bluetooth audio quality on macOS"*, so it ships **off by default**.

**Trap 2 — idle prewarm on Bluetooth is a self-sustaining feedback loop.** FluidVoice issue #752 is the definitive report. Counts from one log file over ~40 h idle: **704** `audio_engine_prewarm reason=idle_route_change`, **579** engine retirements, **3,714** `idle_route_change` lines, at **~1.5 cycles/sec with the machine completely idle**. The mechanism: prewarm opens the AirPods input → macOS flips to the 24 kHz mic profile → that flip *is* an `AVAudioEngineConfigurationChange` → retire + re-prewarm → device returns to 48 kHz → repeat. Terminal state was a swallowed `installTap` ObjC exception (`Engine IO device = 48000.0Hz, Input format = 24000.0Hz 1ch`) and a permanently dead dictation with a live-looking UI.

**Trap 3 — silence detection cancels every Bluetooth recording.** vocalinux #62/#136: the mute detector saw the ~1 s of true digital silence during renegotiation and killed the session. Fix was a grace period (skip the first 0.5 s / 5 samples) plus an off switch.

**Trap 4 — a dead BT mic looks like a working one.** vocalinux #70: A2DP has no microphone at all; the OS-level profile switch is WirePlumber's job, not the app's, but it lands in your issue tracker as an app bug regardless.

### The fix, assembled from what actually shipped

1. **Never hold a warm/pre-roll lease on a Bluetooth input.** FluidVoice `AudioRecorder.isBluetoothInputProvider` drops the lease outright (#481). macparakeet does the same. Detection heuristic from vocalinux `_is_bluetooth_device`: match `bluetooth|bluez|hands-free|handsfree` — *deliberately not bare `headset`*, which false-positives on wired USB. On macOS the clean signal is `kAudioDevicePropertyTransportType != kAudioDeviceTransportTypeBluetooth` (FluidVoice `AudioDeviceService.swift:39`).
2. **Trailing-debounce route-change notifications, with a supersession counter.** FluidVoice `warmCaptureRefreshDebounce` + `warmRefreshGeneration` — Core Audio fires duplicates and each refresh restarts the engine which triggers the next notification.
3. **Gate the "ready" cue on first real PCM, not on `start()` returning.** FluidVoice `AudioCaptureReadinessGate`: `firstPCMTimeoutNanoseconds = 2_000_000_000`, up to 3 attempts, 300 ms settle between. The start sound then never lies. macparakeet's `verify_and_play_sound()` polls `frames_since_start` every 50 ms for up to 1.5 s, then `verify_stream_stable()` sleeps 200 ms and requires the counter to have advanced *again*.
4. **Explicitly unbind the input AudioUnit at stop** or Bluetooth stays in the low-quality profile. FluidVoice `ASRService.swift:2490-2516`:
   ```swift
   /// This is CRITICAL for releasing Bluetooth devices so macOS can switch back to high-quality A2DP mode
   var unknownDevice = AudioObjectID(kAudioObjectUnknown)
   AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global, 0, &unknownDevice, …)
   ```
5. **Don't force 16 kHz on the device.** Handy PR #1084: *"instead of forcing the microphone to open at 16kHz (which can cause issues with bluetooth codecs, some ALSA drivers, and other devices that advertise 16kHz support but produce suboptimal audio), use the device's native/default sample rate and let the existing FrameResampler downsample."* Parla already does this (`AudioRecorder.swift:148` uses `input.outputFormat(forBus: 0)`) ✅.
6. **Grace period before any silence/mute gate.** ≥0.5 s, plus an off switch (vocalinux).
7. **Never take an exclusive/primary audio session for a UI beep.** Handy #646: activating the audio session to play the "ready" chime made macOS treat Handy as primary media playback, and Handoff yanked the user's AirPods off their phone.

---

## 8. Ranked by ms saved per hour of work

Estimated saving is per-dictation user-visible latency (or, where noted, compute/battery). Effort is Parla-specific.

| # | Change | Saving | Effort | Ratio |
|---|---|---|---|---|
| 1 | Gate the shadow stream on `liveTyping \|\| duration > threshold` | **~3.5 s GPU per 10 s dictation** (compute/battery, not cursor latency) | S (~1 h, one guard) | huge |
| 2 | Cache `Settings` instead of `store.load()` on fn-down + per stream pass | ~1–5 ms, removes disk I/O from keypress | S (~1 h) | high |
| 3 | Cache the `focusTarget()` AX-wake result per session | up to **150 ms** of main-actor `usleep` | S (~2 h) | high |
| 4 | Drop `usleep` 5 ms → 1 ms per keystroke chunk (openless's macOS value) | **~120 ms** on a 600-char transcript | S (~1 h) | high |
| 5 | Pre-roll ring buffer (1.0 s ring, 0.45 s prepend) | **0 lost onset**; user-perceived as the biggest fix | M (~6 h) | high |
| 6 | Warm mic lease with Bluetooth exclusion + route debounce | **240–700 ms** press→first-sample | M (~10 h) + BT traps | med-high |
| 7 | Instrument the turn (structured `[latency]` log line) | 0 ms, but nothing else is measurable without it | S (~2 h) | prerequisite |
| 8 | `cut_streaming_audio()` equivalent: stop feeding the pipeline before mic teardown | quality (kills hallucinated trailing tokens) | S (~2 h) | high |
| 9 | Anthropic `cache_control` on the static prompt prefix | ~100–300 ms of an already-invisible leg | S (~2 h) | low (invisible) |
| 10 | True streaming insert via `whisper_full_params.new_segment_callback` | perceived: text during speech | L (~30 h+, blocked on the fn-merge bug) | low |

**Do not do:** `set_audio_ctx` narrowing (Parla A/B'd it — `Transcriber.swift:42-45` records that restricting it to clip length collapsed one-word clips to `*` and triggered multi-second retry storms; pindrop's plan 028 recommends it generically without Parla's counter-evidence). Trailing-silence padding (macparakeet's fix is explicitly *not* for Whisper). Idle model unload (voicetypr's `SIDECAR_IDLE_DISPOSE_MS = 60_000` is the corpus's clearest anti-pattern for a bursty app).

---

## What Parla should do

Ordered. Each item names the file and an effort size.

1. **Ship a latency trace before optimizing anything else. (S, ~2 h)**
   `Sources/Parla/main.swift` + `Sources/ParlaCore/AudioRecorder.swift`. Copy epicenter's shape (`src-tauri/src/timing.rs`, 70 lines): an env-gated `OnceLock<Bool>` so every helper is a branch-and-return when disabled, then one greppable line per dictation. Stamp: `fn_down`, `recorder_start_returned`, `first_pcm_callback`, `fn_up`, `final_pass_done`, `landed`, `cleaned_swapped`, plus the input device's transport type. FluidVoice's #450 latency table and pindrop's plan-028 budget only exist because someone shipped the instrument first. Parla currently has *zero* timing instrumentation on the capture path.

2. **Gate the shadow stream. (S, ~1 h)**
   `Sources/Parla/main.swift:696-760`. `liveTyping` is hard-`false` (`:179`) and `StreamWindow.threshold` is 15 s, so every dictation under 15 s spends ~30–40 % GPU duty cycle producing nothing. Guard the loop entry on `liveTyping`, or on an elapsed-duration check that only starts passes once the buffer approaches `StreamWindow.threshold`. Also fix `README.md:95` — "release latency is independent of how long you dictated" is false below the cut threshold.

3. **Pre-roll ring buffer. (M, ~6 h)**
   `Sources/ParlaCore/AudioRecorder.swift`. 16,000-sample (`1.0 s`) ring under the existing `NSLock`, `preRollPrependSamples = 7_200` (0.45 s) spliced in at `start()` before live capture is marked active. Copy macparakeet's constants (`Sources/MacParakeetCore/Audio/AudioRecorder.swift:37-90`) and FluidVoice's two guards: discard pre-roll older than 2 s, and discard it entirely when system media was playing at press time. This requires (4) to be useful, since a cold engine has no ring to fill.

4. **Split `prepare()` from `start()`, with Bluetooth excluded. (M, ~10 h)**
   `Sources/ParlaCore/AudioRecorder.swift:133-165`. Build the engine, bind the AUHAL device and install the tap at app launch and on device-change; `start()` becomes `engine.start()`. Three non-negotiable guards from §7: (a) never hold the warm engine when the resolved input's `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeBluetooth`; (b) trailing-debounce route-change notifications with a generation counter (FluidVoice #752 — 3,714 route-change events in 40 h idle); (c) explicitly unbind the input AudioUnit (`kAudioObjectUnknown`) at teardown so AirPods return to A2DP. Also observe `AVAudioEngineConfigurationChange`, which Parla does not handle at all today.

5. **Stop feeding the pipeline before mic teardown. (S, ~2 h)**
   `Sources/Parla/main.swift` fn-up path. openless `coordinator/dictation.rs:971-978`: the ~50–100 ms of residual samples between the stop press and actual mic shutdown *"leak in as low-level noise and cause hallucinated trailing tokens."* Parla's abort machinery already exists (`Transcriber.swift:51-56`); this is about trimming the tail of `samples` before the final pass, not about the abort.

6. **Cut the fixed insertion sleeps. (S, ~2 h)**
   `Sources/ParlaCore/Inserter.swift:56, 74, 99`. Drop the inter-chunk `usleep(5_000)` toward openless's macOS value of 1 ms per codepoint (`unicode_keystroke.rs`) — ~150 ms → ~30 ms on a 600-char transcript. Cache the Electron AX wake-up (`:99`) result per bundle ID per session instead of re-`usleep(50_000)`-ing at fn-down, finalize and swap. Keep the pacing non-zero: openless and OpenWhispr both document that zero delay drops characters in Chromium/Electron.

7. **Get `Settings` off the keypress path. (S, ~1 h)**
   `Sources/Parla/main.swift:134` and `:697` both call `store.load()` — synchronous file read + JSON decode — on the hot path. Cache with an mtime check, or reload only on the Hub's `onSaved` callback which already exists (`main.swift:63-69`).

8. **Add `cache_control` to the Anthropic system prompt. (S, ~2 h)**
   `Sources/ParlaCore/Cleanup.swift:41-76`. The system prompt is static per-config; nobody in the corpus sends `cache_control`. Off the critical path, so this is a cost win more than a latency one — but the prompt is already the right shape (stable prefix, dynamic user message), so it's near-free.

9. **Fix `AudioRecorder.convert`'s per-buffer converter. (S-M, ~4 h)**
   `Sources/ParlaCore/AudioRecorder.swift:110-132`. A new `AVAudioConverter` per tap callback allocates on the realtime thread *and* resets the resampler filter state at every buffer boundary (the `.endOfStream` drain is per-buffer). That injects a discontinuity every ~85 ms for the whole recording. Cache one converter keyed on the input format and feed it `.noDataNow`, as VoiceInk's `ReusableAudioConverter` does (`AudioRecorder.swift:210-300`, which also keeps a free-list of output buffers). This is a WER fix wearing a latency costume, but it's on the same lines of code as (3)/(4).

10. **Only then consider real streaming insert. (L, 30 h+)**
    `Sources/ParlaCore/Streaming.swift` + `Sources/ParlaCore/Inserter.swift`. Blocked on the fn-merge bug (`main.swift:172-178`). When unblocked, use `whisper_full_params.new_segment_callback` (pindrop `plans/028`) rather than sliding-window re-decode — whisper-rs/whisper.cpp has no KV reuse, so re-decode is the only alternative and it carries a permanent boundary-accuracy tax (epicenter ADR-0016). Adopt pindrop's stop condition verbatim: *"If a streaming partial is ever pasted and then revised in a user's app → stop; fall back to insert-at-stop."* Parla's `LiveTyper.diff` + `canEraseTyped` already implement the safe half of this.
