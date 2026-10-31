# Delivery/platform competitor audit — 2026-10-28

Read-only static source audit. No app execution, dependencies, builds, or project edits. Source existence is not proof of target-app compatibility or latency. All six repositories were shallow-cloned under `/tmp/wisper-competitive-2026-10-28/`; retain as research resources. Baseline includes current uncommitted Android implementation.

## Pinned corpus

| Repo | HEAD | License file |
|---|---|---|
| cjpais/Handy | 7bfb2e2c934b798bcf6e3627653aed2439996f89 | LICENSE, MIT |
| OpenWhispr/openwhispr | ec5852811c09cd7b76992fbbddaba49cc5acb523 | LICENSE, MIT |
| peteonrails/voxtype | dc499ad47444ba6ea80d8750aa3581c23120821c | LICENSE, MIT |
| goodroot/hyprwhspr | 0d2ec746a37229b0de8d21ddfffd2c0e62d45546 | LICENSE, MIT |
| VocaHQ/vocalinux | dbf8039196cc0cb5bad0fb7c1610334cd358c6a5 | LICENSE, AGPL-3.0 |
| notune/android_transcribe_app | 7abe07a2125733d008a21eb5a039e8204d3c6572 | LICENSE, MIT |

FUTO Voice Input was considered and excluded from the OSS corpus: its README identifies FUTO Source First License 1.0. Its ideas can be studied separately, but do not present it as an OSI-style open-source reference.

## Actionable findings

### D1. Receipt-aware macOS clipboard restoration — research spike

HOLDS: Parla ClipboardDelivery.paste uses a fixed restoration timer (Sources/ParlaCore/ClipboardDelivery.swift:41-63), with Inserter.insert selecting 0.8 seconds normally and 5 seconds for remote apps (Inserter.swift:33-36). Handy publishes lazy pasteboard data and records data-provider read receipts, ignores pre-injection reads, then waits for a quiet period or timeout. Evidence: [Handy paste_tx design and timing](https://github.com/cjpais/Handy/blob/7bfb2e2c934b798bcf6e3627653aed2439996f89/src-tauri/src/paste_tx/mod.rs#L1-L63), implementation paste_tx/macos.rs:57-64 and :263-326, tests mod.rs:224-277. Value: handle slow target apps without an arbitrary long clipboard lease. Effort M/L; needs busy-app, Chromium multiple-read, clipboard-manager and RDP qualification. Strongest objection: debug-gated upstream feature; a read receipt does not identify the destination or prove insertion, and timeout remains heuristic. Preserve Parla's superior all-item/all-representation snapshot; do not copy Handy's text/image-only snapshot regression.

### D2. Linux native output capability ladder

HOLDS: current Linux deliver::to_clipboard (linux/parlad/src/deliver.rs:17-52) only offers clipboard output. Voxtype implements TextOutput and a runtime-selected ladder wtype, eitype, dotool, ydotool, Wayland clipboard, X11 clipboard. [Source](https://github.com/peteonrails/voxtype/blob/dc499ad47444ba6ea80d8750aa3581c23120821c/src/output/mod.rs#L229-L250). Value: actual text-at-cursor on Linux; wider compositor and X11 coverage. Effort L and physical Linux testing. Strongest objection: M1 clipboard-only is deliberate (linux/VERIFY.md); each additional backend adds permissions/layout/focus risk. Never retry a backend after partial/unknown delivery.

### D3. GNOME/KDE via consented portal / EI output

HOLDS within current Linux M1 scope: no native output backend. [Voxtype eitype](https://github.com/peteonrails/voxtype/blob/dc499ad47444ba6ea80d8750aa3581c23120821c/src/output/eitype.rs#L1-L36) adds EI protocol output and KDE pacing; [Vocalinux portal](https://github.com/VocaHQ/vocalinux/blob/dbf8039196cc0cb5bad0fb7c1610334cd358c6a5/src/vocalinux/text_injection/remote_desktop_portal.py#L209-L280) negotiates keyboard injection. Value: expand beyond wlroots. Effort L. Strongest objection: portal consent/session persistence and desktop version vary; source comments listing desktops are not compatibility certification. Vocalinux's delivered-count/unknown outcome error at lines 51-62 and timeout cancellation at 379-415 is the useful safety model.

### D4. Linux terminal-aware paste routing

HOLDS as future output requirement: Parla's Linux deliver.rs has no synthesized paste, so no terminal routing yet. [OpenWhispr routing](https://github.com/OpenWhispr/openwhispr/blob/ec5852811c09cd7b76992fbbddaba49cc5acb523/src/helpers/clipboard.js#L1718-L1745) chooses terminal-specific chords and handles unknown targets; terminal signatures at lines 39-84. [Vocalinux focused window identity](https://github.com/VocaHQ/vocalinux/blob/dbf8039196cc0cb5bad0fb7c1610334cd358c6a5/src/vocalinux/text_injection/focused_window.py#L133-L165) tokenizes identity. Value: terminals, TUI assistants, IDE integrated terminals. Effort M after D2. Strongest objection: app-ID alone cannot tell whether the caret is in an IDE terminal; require explicit overrides and tests, not allowlist confidence.

### D5. Linux modifier release guard before synthetic output

HOLDS as future output requirement. [Voxtype ModifierGuard](https://github.com/peteonrails/voxtype/blob/dc499ad47444ba6ea80d8750aa3581c23120821c/src/output/modifier_guard.rs#L1-L16) takes passive EVIOCGKEY snapshots; wait_for_release at lines 134-146. Value: avoid turning dictation into compositor shortcuts when modifiers remain held. Effort M; prerequisite D2. Strongest objection: input-device permissions may be unavailable; disabling the guard is not proof that no keys are held. Parla macOS already guards synthetic delivery; do not report it missing globally.

### D6. Portal-based Linux global shortcut setup

PARTIAL: Parla Linux uses external compositor bindings, a deliberate M1 choice. [OpenWhispr GlobalShortcuts portal](https://github.com/OpenWhispr/openwhispr/blob/ec5852811c09cd7b76992fbbddaba49cc5acb523/src/helpers/gnomeGlobalShortcutsPortal.js#L1-L9) owns a D-Bus session and registration; success/failure at lines 151-155. Value: easier GNOME onboarding and fewer hand-edited config files. Effort M/L. Strongest objection: native compositor shortcuts are already a valid integration and portal support/key-release behavior varies. Only prioritize if expanding beyond wlroots.

### D7. Android standard recognition activity

HOLDS: Parla AndroidManifest.xml:18-41 exposes launcher, recording, accessibility and IME, but no RECOGNIZE_SPEECH activity. [Offline Voice Input manifest](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/AndroidManifest.xml#L62-L75) plus [RecognizeActivity result contract](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/java/dev/notune/transcribe/RecognizeActivity.java#L200-L240) return results and PendingIntent extras. Value: compatible keyboard mic buttons and speech-intent apps can invoke Parla without accessibility or switching keyboard. Effort M. Strongest objection: not universal keyboard support; Gboard is not promised, and the competitor's own README says it uses its own provider. Do not adopt competitor's automatic clipboard backup or invented confidence=1.0 behavior uncritically.

### D8. Android RecognitionService adapter

HOLDS: no RecognitionService registration in Parla's manifest. [Competitor service](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/java/dev/notune/transcribe/VoiceRecognitionService.java#L58-L84) bridges SpeechRecognizer callbacks and model readiness; manifest lines 110-122 binds BIND_RECOGNITION_SERVICE. Value: apps using SpeechRecognizer rather than activity intents. Effort M/L; reuse session ownership and permission model. Strongest objection: exported recognizer introduces lifecycle/permission/competing-session contracts; target Android SDK permission behavior requires runtime validation. Treat D7 and D8 as distinct caller APIs, not duplicate UI features.

### D9. Android voice IME subtype

HOLDS: Parla res/xml/parla_input_method.xml:5 declares imeSubtypeMode="keyboard". Existing ParlaInputMethodService is a real keyboard and should be preserved. Standard voice-keyboard discovery is a separate compatibility opportunity. [Competitor method.xml:6-8](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/res/xml/method.xml#L6-L8) explicitly declares imeSubtypeMode="voice"; manifest lines 124 onward registers its IME. Value: compatible keyboards whose mic button switches to system voice IME. Effort S/M plus HeliBoard/FlorisBoard tests. Strongest objection: changing subtype alone can affect keyboard discoverability and switching; this is a qualification spike, not a confirmed current failure.

### D10. Shared audio file transcription

HOLDS: Parla manifest has no audio share/view activity; DictationManager is microphone-session oriented. [Competitor share contract](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/AndroidManifest.xml#L78-L99) plus [URI and decode lifecycle](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/java/dev/notune/transcribe/TranscribeFileActivity.java#L95-L140) accepts SEND/VIEW and cancels decoding on destruction. Value: voice notes, recorder files, received audio without live mic. Effort L for bounded decoding/chunking and URI permissions. Strongest objection: broadens product beyond dictation and requires long-audio quality/memory tests. Never insert into a previous app automatically from this workflow.

### D11. Android local model catalogue / multilingual choices

HOLDS: Parla WhisperEngine.transcribe requires English at android/.../speech/WhisperEngine.kt:17-18; ModelStore.modelFile is one tiny.en path at ModelStore.kt:23. [Competitor ModelStore](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/java/dev/notune/transcribe/ModelStore.java#L14-L29) tracks imported GGUF models and active selection, with deleted-selection repair at lines 109-119. Value: multilingual and quality/speed choice. Effort L across engine abstraction, model integrity, RAM/cancel tests. Strongest objection: arbitrary model import broadens attack/crash surface; Parla's pinned hashes and verify-before-native-load are stronger and must remain. No speed/accuracy superiority measured here.

### D12. Optional playback suppression with owned restoration

HOLDS in searched Parla settings/audio paths: mediaPlaying exists only to discard pre-roll captured while output is active (AudioRecorder.swift:204-219), not to pause media. [Hyprwhspr MediaPauser](https://github.com/goodroot/hyprwhspr/blob/0d2ec746a37229b0de8d21ddfffd2c0e62d45546/lib/src/media_pauser.py#L140-L184) resumes only same bus owner still paused; [Voxtype MPRIS](https://github.com/peteonrails/voxtype/blob/dc499ad47444ba6ea80d8750aa3581c23120821c/src/audio/media.rs#L41-L107) pauses active players; Android competitor AudioFocusPauser.java:8-43 requests transient focus. Value: speaker playback less likely to pollute dictation. Effort M per platform. Strongest objection: intrusive for calls/live streams; opt-in, exclude communication apps, restore only changes owned by the session, cancel/quit covered. Not evidence that VAD/ASR quality improves by a measured amount.

### D13. Live captions from Android playback — separate product bet

HOLDS as expansion opportunity: Parla Android captures microphone and has no mediaProjection declaration or capture service. [Competitor capture](https://github.com/notune/android_transcribe_app/blob/7abe07a2125733d008a21eb5a039e8204d3c6572/app/src/main/java/dev/notune/transcribe/LiveSubtitleService.java#L252-L280) uses MediaProjection and AudioPlaybackCaptureConfiguration with MEDIA/GAME/UNKNOWN usage. Value: on-device captions for allowed playback. Effort L/XL, not near-term core parity. Strongest objection: Android playback capture is consent/DRM/app-policy limited and cannot be advertised as capture-any-app; continuous processing battery/thermal cost is unmeasured. Keep separate from meeting transcription promises.

## Things checked that were fine / stale claims rejected

- DOES-NOT-HOLD: Parla macOS has no clipboard preservation. ClipboardDelivery.snapshot:22-37 captures all representations and detects ownership changes; restore:67-71 does not overwrite new user copies. Stronger fidelity than several competitors.
- DOES-NOT-HOLD: Parla lacks secure-input protection. Inserter.focusTarget:118-128 checks IsSecureEventInputEnabled; password roles at :293, refusal messaging :159-166.
- DOES-NOT-HOLD: Parla requires an app allowlist for all paste. Current Inserter/insertion-destination logic allows opaque native-paste targets with destination identity guards.
- DOES-NOT-HOLD: Parla has no warm capture/pre-roll. AudioRecorder has warm engine setWarm:296, PreRollRing:39, Bluetooth gate:174-185, privacy-aware output-playing pre-roll discard:204-219. OpenWhispr MicStreamHold is comparable architecture, not a missing feature.
- DOES-NOT-HOLD: no mic disconnect handling. AudioRecorder.endCapture:250-260 explicitly finalizes through ordinary stop handling.
- DOES-NOT-HOLD: Android has no secure-field/clipboard handling. InputSafety, InputSupport.SensitiveClipboardLease, guarded IME/accessibility delivery exist. Do not replace them with blind clipboard paste from competitors.
- DOES-NOT-HOLD: no macOS language setting. Settings.language:33-36 supports multilingual-model language hints; current Android model support is the narrower gap.

## Deliberate behavior and validation limits

- Linux is intentionally M1 clipboard output; D2-D6 are roadmap decisions, not defects in a falsely advertised typing feature. linux/VERIFY.md says hardware verification remains.
- Android baseline is uncommitted and pending physical-device/target-app qualification; preserve it.
- Handy receipt path explicitly debug-gated and has pure transaction tests (pre-injection receipts, quiet period, timeout, ownership loss). That is implementation evidence, not proof it beats Parla on real apps.
- No benchmark, WER, launch-time, model-speed or runtime compatibility claims were established. All suggested app names are test targets or upstream code classifications, not supported-app certifications.
