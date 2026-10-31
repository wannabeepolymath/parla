# Parla mobile — cross-app dictation implementation plan

Date: 2026-10-23

Status: Product and execution boundaries confirmed with the user. Android implementation has started; iOS has not started. Platform feasibility gates below must pass before committing to a public release scope or date.

Implementation update: the user subsequently authorized **Android only**, with minimal code and no iOS work. The initial implementation lives in `android/`; see `android/README.md` for build instructions and remaining qualification. It uses one app module and native platform Views. Android does not depend on extracting the Swift domain package. Direct floating insertion uses Android 13+ accessibility input; Android 12 retains the voice IME and explicit Copy/Paste fallback. Milestone checkboxes below describe the original two-platform scope and must not be read as completed iOS work.

## 1. Confirmed product contract

The product is speaking naturally inside another application and receiving AI-cleaned text at the cursor. Keyboard integration and reliable cross-app delivery are the primary experience. The companion application provides setup, permissions, vocabulary, history, provider configuration, and recovery.

User-confirmed requirements:

- Native Android and iOS applications.
- Cross-app use is the main product, not a standalone recording application.
- AI cleanup is a central feature and is enabled after successful provider setup.
- Speech recognition runs on the user's device. Audio is not uploaded for transcription.
- Cleanup requests go directly from the device to the user's chosen AI provider using the user's own API key.
- No Parla-operated backend, proxy, hosted web frontend, account system, sign-in, entitlement server, or cloud sync.
- The mobile UI and orchestration run on the device. Third-party provider access and upstream model downloads are the explicit network dependencies; “no backend of ours” does not mean offline AI cleanup.
- The user bears any charges imposed by their chosen provider. There is no Parla subscription or usage billing in this scope.

This plan supersedes the earlier conversational proposal for managed cloud transcription, managed cleanup, authentication, and a Parla backend. It also supersedes deferring Android's floating microphone: that integration is in the initial scope.

Primary successful journey:

1. Focus a supported text field in a messaging, email, notes, browser, or AI-chat application.
2. Activate Parla through the platform's input surface.
3. Speak; see recording state and a clear stop/cancel control.
4. Stop; run on-device transcription and direct-provider AI cleanup.
5. Insert one finished result into the intended field when destination continuity can be established. Otherwise present an explicit Insert/Copy action.
6. The user reviews and sends using the destination application. Parla does not send messages or invoke an editor's Submit/Send action.

## 2. Initial scope and exclusions

Ship in the initial product:

- iOS keyboard extension plus companion recording application.
- Android floating microphone above the existing keyboard, with a native Parla voice IME as an alternative delivery path.
- On-device speech model installation, verification, cancellation, and deletion.
- Direct cleanup adapters matching desktop behavior: Anthropic and an OpenAI-compatible endpoint.
- Secure API-key entry in the companion app; connection validation; explicit model selection.
- Faithful cleanup, self-corrections, dictionary spellings, deterministic whole-utterance snippets, and cancellation.
- Default Clean mode, plus explicit Message and Email styles. A clearly labeled Original/Verbatim option bypasses cleanup.
- Local history with original and cleaned versions, copy, clear, and retention controls.
- Recovery after focus changes, provider failures, audio interruption, process termination, and uncertain insertion.
- A small in-app test editor for setup and unsupported-app fallback.

Defer until cross-app dictation is proven:

- General rewriting of arbitrary selected text in other applications. Selection access and replacement are capability-specific; desktop command-mode parity is not assumed.
- Fully on-device language-model cleanup, cloud speech recognition, automatic dictionary learning across other apps, and automatic language translation.
- Cross-device sync, accounts, managed API keys, subscriptions, teams, meeting transcription, and a hosted dashboard.
- A full replacement for Gboard/Apple Keyboard autocorrection, gesture typing, and emoji search. Provide basic keyboard functionality and a reliable switch-back control.
- Automatic always-on microphone activation, arbitrary iOS floating overlays, private APIs, and background-service workarounds.

## 3. Platform contracts and feasibility gates

### iOS

Use SwiftUI for the companion application and UIKit's `UIInputViewController` for the keyboard extension. Audio capture, speech inference, provider credentials, and cleanup HTTP requests belong in the companion process. The keyboard stays lightweight and uses `textDocumentProxy` for insertion.

The keyboard cannot directly access the microphone. Full Access enables capabilities needed for shared-container communication; it does not grant microphone access. Request microphone permission in the companion application. Explain Full Access separately, and retain basic keyboard input and keyboard switching when it is refused.

Start with an explicit user-initiated recording session in the companion app, followed by the user's return to the destination. Investigate public, supported shortcut/session activation mechanisms during the spike. Do not base the architecture on automatic keyboard-to-app launches or automatic return to arbitrary host apps. Competitor behavior is evidence of a UX pattern, not proof that a particular implementation is supported.

A bounded, visibly active session for consecutive dictations may reduce switching if lifecycle and review validation succeeds. Recording indicators must remain truthful. Do not use silent playback or pretend an inactive microphone is recording to keep the app alive. Stop on explicit end, expiry, relevant interruption, or permission loss. Re-activation must be understandable when the process has been suspended or killed.

Implement session messages in an App Group using a versioned, atomically written journal. Notifications are wake hints; persisted state is authoritative. A notification cannot wake an arbitrarily suspended app. Record session IDs, generation, expiry, output state, and delivery state. Store secrets only in the host's credential store, not the App Group. Bound and remove transient transcripts; history-disabled mode must not leave a hidden persistent history there.

The current Whisper wrapper assumes Metal is available. Ordinary iOS background GPU execution is restricted. Qualify a CPU-capable mobile configuration and explicitly select the backend before starting inference; do not wait for an unsupported Metal operation to crash. Newer background GPU APIs are optional capability-based enhancements, not baseline requirements. Audio background permission does not guarantee unlimited processing after recording stops. Use bounded finalization; retain a recoverable pending result if execution expires.

The keyboard cannot reliably obtain another app's identity, full document, or full conversation. Use user-selected style and available field traits; never promise automatic context detection equivalent to macOS. Password fields and host apps that reject third-party keyboards are unsupported destinations.

**Gate I:** on a physical iPhone, demonstrate user activation, continued capture after switching apps, local transcription without unsupported background GPU use, direct cleanup, and insertion into a real host editor. Repeat after an interruption and process restart. If smooth consecutive use cannot be achieved, document the exact extra interactions before expanding UI work. A standalone recorder does not satisfy this gate.

### Android

Use Kotlin/Jetpack Compose for the companion application, an `InputMethodService` for voice IME delivery, and a separate overlay/accessibility integration for the floating microphone. Capture audio with Android audio APIs; run Whisper through a small NDK/JNI adapter.

Preferred daily use: keep the user's existing keyboard, tap or hold the floating microphone, speak, finish, and insert cleaned text. The overlay must not steal editor focus. Offer tap-to-toggle and hold-to-talk, with accessible stop/cancel controls.

The floating path needs microphone permission, overlay permission, and a narrowly scoped accessibility service for editor discovery and delivery. Explain each purpose at the point of setup. Do not claim `isAccessibilityTool` solely because dictation can benefit accessibility. Validate the Play declaration and disclosure requirements for the actual product.

Insertion is capability-based. Do not assume every editor exposes the same accessibility actions. Recheck the focused node and available selection immediately before delivery. Avoid blind whole-field replacement with `ACTION_SET_TEXT`; an asynchronously changed draft must not be overwritten. Where safe insertion cannot be established, retain the result and offer the voice IME or explicit Copy/Paste.

The voice IME uses the active `InputConnection` and `commitText`. It must detect connection replacement and editor changes. Keep this path usable without overlay/accessibility permissions. Switching to Parla's IME temporarily replaces the current keyboard; Parla cannot promise to replace another keyboard's microphone button.

Any clipboard fallback is explicit, sensitive, short-lived, and must not overwrite a newer clipboard value on cleanup. Prefer direct IME insertion when available. Do not rely on background clipboard reads.

Recording starts from a user action using a lifecycle permitted by the target Android version. Declare microphone foreground-service capabilities where used, provide recording status and Stop, and validate background-start/while-in-use rules. Do not assume an overlay permission alone authorizes recording. Test manufacturer battery behavior without requiring blanket battery-optimization exemptions during ordinary onboarding.

**Gate A:** on physical Pixel and Samsung devices, demonstrate the floating path over the existing keyboard and the IME path in real editors. Verify no focus theft, whole-draft replacement, accidental send, or duplicate insertion. Unsupported fields must produce a useful explicit fallback. The bubble cannot be declared complete based only on appearing on screen.

## 4. Reuse and module boundaries

Current repository findings:

- `Package.swift` targets macOS only, and `Frameworks/whisper.xcframework` contains only a macOS slice.
- `Cleanup.swift`, `CleanupFactory.swift`, and `OpenAICompatClient.swift` implement the direct-provider architecture the user wants.
- `Pipeline.swift` contains snippet expansion, cleanup validation, and raw fallback, but references `AudioRecorder.rms` and `Eval.normalizeForWER`.
- `Streaming.swift` also references `AudioRecorder.rms`.
- `DictionaryLearner.swift` depends on normalization/edit-distance helpers in `Eval`, whose audio-loading path imports AVFoundation and uses the desktop recorder.
- `Settings.swift` depends on desktop `HotkeyBindings` and stores inline API keys. Do not copy that secret-storage design into mobile.
- `DictationSession.swift` imports Foundation but depends on desktop `Inserter.FocusTarget` and `AudioRecorder.EndReason`; it is not directly portable.
- `HistoryStore` uses a local JSON array. It is not a multi-process app/extension database.
- `linux/parla-core` is a useful behavioral reference, not an Android application or a reason to rewrite the Apple code in Rust.

Proposed structure (new paths are implementation targets, not existing files):

| Path | Responsibility |
|---|---|
| `Sources/ParlaDomain/` | Portable Swift cleanup contracts, prompt construction, text normalization, snippets, audio math, and mobile-independent value types; preserve applicable MIT notices |
| `Sources/ParlaCore/` | Existing macOS integration and compatibility adapters; keep desktop behavior intact |
| `Tests/ParlaDomainTests/` | Pure-rule and fixture parity tests |
| `ios/ParlaMobile.xcodeproj` | Companion app and keyboard extension targets, entitlements, schemes, signing configuration |
| `ios/ParlaMobile/` | Onboarding, capture, local inference, provider setup, Keychain, history, model installation |
| `ios/ParlaKeyboard/` | Basic keyboard, dictation controls, session status, insertion, switch keyboard |
| `ios/ParlaSessionBridge/` | Small extension-safe shared types and App Group journal; no inference/model dependency |
| `android/` | Gradle project with `app`, `core`, `speech`, and `input` modules |
| `android/core/` | Kotlin prompt/text-rule equivalents and direct HTTP providers |
| `android/speech/` | Capture, resampling, model lifecycle, Whisper NDK/JNI boundary |
| `android/input/` | Voice IME, overlay, accessibility integration, destination tracking |
| `eval/mobile/` | Shared behavior fixtures, synthetic insertion payloads, device matrix, and opt-in real-audio evaluation instructions |
| `.github/workflows/mobile.yml` | Reproducible build and offline tests after project setup |

Keep Swift implementation reuse between macOS and iOS. Share versioned behavior fixtures and model metadata across Android and Apple; implement Android integration in Kotlin. Share the upstream C/C++ speech engine through native bindings. Do not introduce a web UI, cross-platform UI runtime, or a wholesale Rust migration for this work.

Define narrow boundaries:

- `AudioCapture`: start, stop, cancel, interruption, and mono PCM output at the engine's required sample rate.
- `SpeechRecognizer`: model availability, language capability, cancellation, and transcription result.
- `CleanupProvider`: transcript + explicit style/context + dictionary/snippets -> cleaned text or typed failure.
- `CredentialStore`: read/write/delete provider credentials; no dependency on ordinary settings serialization.
- `DeliveryAdapter`: destination capability, current continuity evidence, insertion request, and delivered/failed/uncertain result.
- `SessionStore`: versioned session state and optional local history.

Extract only what mobile uses. Keep desktop bundle-ID categorization, hotkeys, updater, accessibility, and clipboard code outside the portable target. Replace audio-math and normalization dependencies before moving pipeline code; do not make the keyboard link the entire desktop core or speech model runtime.

## 5. Cleanup, configuration, and data behavior

### Direct provider setup

The companion app asks for provider, model, API key, and optional custom HTTPS endpoint. There is no Parla account. Provider accounts, if needed to obtain keys, exist outside Parla. Explain provider billing and that text leaves the device for cleanup.

Use iOS Keychain and Android Keystore-backed encryption. Ordinary settings contain a credential reference, not the API key. Exclude secrets from exports, diagnostics, shared containers, backups where appropriate, and logs. Do not bundle a developer-owned provider key. The keyboard extension does not need to read credentials.

Initially support the existing Anthropic and OpenAI-compatible request shapes. Reuse the current provider isolation rules; switching providers must not attach the old provider's key to a new endpoint. Require an explicit model for mobile setup. Test connectivity with a fixed non-sensitive sample only after the user taps Test. Show authentication, quota/rate-limit, model, endpoint, and connectivity failures distinctly.

Use HTTPS for remote endpoints, normal certificate validation, and origin-bound credential handling across redirects. A self-hosted local-network endpoint is an advanced follow-up if needed; `localhost` on a phone refers to that phone, not the user's Mac. Do not silently relax platform transport restrictions.

### Cleanup semantics

- Clean mode preserves meaning, language, names, quantities, dates, and user corrections; removes fillers and fixes punctuation/grammar.
- Message and Email are explicit user choices. Do not infer broad host-app context that the OS does not expose.
- Exact whole-utterance snippets expand deterministically before the model request.
- Treat dictated text as data, not instructions to an agent. Providers receive no tool-execution capability.
- Preserve existing sanitation, empty-output, extreme-expansion, and truncation guards, and extend evaluations for mobile cases. Length guards do not prove semantic correctness.
- Finish cleanup before automatic insertion. Partial transcripts and model output may appear only in Parla's own UI.
- Cancellation invalidates late inference/network results by session generation. Retrying cleanup does not create another insertion request.
- Use bounded request deadlines and deliberate retries. A network retry can incur additional provider cost; avoid unbounded automatic retries.

The user can inspect the original transcript. If cleanup fails, show the reason and offer Retry or Use Original; do not silently call the raw output “cleaned.” If connectivity is absent, local speech recognition still works, but provider-based AI cleanup does not. Never switch to cloud transcription as a fallback.

### Privacy and storage

Audio stays on-device and is discarded after processing by default. An optional recovery/diagnostic audio setting must state retention and disk use. Local history defaults to a bounded 50-entry policy consistent with desktop, with an off switch and clear action; canceled and sensitive-field sessions are excluded. Pending text is transient when history is off and must have an expiry.

Cleanup sends only transcript text, applicable user-configured dictionary/snippets, and the selected style. Sending selected external text would require a separate explicit rewrite action in a later milestone. Do not collect whole conversations, screenshots, or unrelated app content. Provider retention is governed by the user's provider; do not promise zero retention for third parties.

No analytics endpoint, automatic diagnostic upload, remote configuration dependency, or push-notification server. Diagnostics are local and user-exported with secrets/content omitted by default. Model downloads use pinned upstream artifact URLs, expected sizes, and hashes; no Parla download service is required. App Store/Play distribution and optional build CI do not introduce runtime hosted services.

## 6. Session and insertion correctness

Use an explicit state machine: idle -> recording -> transcribing -> cleaning -> ready -> delivering -> delivered. Additional outcomes: canceled, interrupted, cleanupFailed, deliveryFailed, deliveryUncertain, and expired.

Every session has a unique ID and generation. Persist output independently of delivery acknowledgement. Capture destination evidence at start, invalidate on observed editor/selection/context changes, and recheck at delivery. On iOS, incomplete proxy context is not proof of destination continuity; ask for explicit insertion when continuity cannot be established.

An application can crash after inserting text but before persisting its acknowledgement. Therefore, do not claim exactly-once delivery across process failure. Mark that case uncertain, show the recovered result, and do not automatically replay it.

Do not replace an entire existing draft to insert a phrase. Do not delete text to implement Undo unless ownership and unchanged context can be established; otherwise retain the original and let the host editor handle undo. Test Unicode graphemes, emoji, selection replacement, existing text on both sides of the cursor, and single-line field normalization. Never use Enter/Return as an insertion mechanism that can submit content.

## 7. Implementation milestones

### M0 — prove the product interaction before building the hub

- [ ] Create minimal iOS companion/keyboard and Android overlay/IME projects with stable identifiers and debug schemes.
- [ ] Implement insertion of a fixed local sample into real destination editors, including focus-change refusal and explicit fallback.
- [ ] Add local microphone capture and a small pinned Whisper model to each spike.
- [ ] Add direct cleanup using a key entered locally through each app's secure setup UI.
- [ ] Run Gate I and Gate A above; record activation steps, insertion results, microphone lifetime, and actual limitations.
- [ ] Select supported OS/device baselines from the results. Candidate baselines are iOS 17+ and Android 12+, subject to validation; use store-required target SDKs at release time.
- [ ] Confirm the app/extension lifecycle and intended distribution path before expanding the feature set. Preserve existing license notices and resolve mobile distribution licensing requirements before release.

Exit: polished speech reaches supported fields in real apps on both platforms. No hosted component or app sign-in is involved. A recorder that only copies text inside its own window does not pass. If a platform gate fails, document the failing path and a revised interaction; do not quietly substitute a standalone app.

### M1 — extract portable behavior without regressing desktop

- [ ] Add `ParlaDomain` and extract normalization, edit distance where needed, PCM math, snippets, cleanup contracts, prompts, and output validation.
- [ ] Separate portable settings from desktop hotkeys, filesystem paths, and inline credentials.
- [ ] Adapt desktop `ParlaCore` to use the extracted code while retaining its public behavior and settings compatibility.
- [ ] Create shared fixtures from existing `eval/cases`, adding explicit style and output expectations.
- [ ] Implement Kotlin equivalents against those fixtures. Track fixture/prompt versions locally; no remote prompt service.

Exit: desktop build/tests and offline eval verification pass; Swift and Kotlin agree on deterministic fixtures. No desktop settings migration is required merely to install mobile.

### M2 — production local speech and direct cleanup

- [ ] Add pinned iOS device/simulator Whisper artifacts without removing the macOS slice; build Android native libraries for the supported ABIs.
- [ ] Implement lifecycle-aware capture, sample conversion, interruption handling, cancellation, and serialized inference.
- [ ] Qualify small English and multilingual model candidates. Do not default every phone to the existing 574 MB desktop model. Download size is not runtime memory use.
- [ ] Implement resumable/cancellable model installation, checksum verification, space checks, corruption recovery, and deletion.
- [ ] Implement secure provider setup and the two provider adapters, with cancellation and typed failures.
- [ ] Preserve local transcription and explicit Use Original when provider cleanup is unavailable.

Exit: actual mobile audio is transcribed locally; only the documented text payload reaches the selected cleanup endpoint. Provider errors do not lose the transcript or trigger automatic duplicate delivery.

### M3 — production cross-app integration

- [ ] Replace spike iOS communication with the versioned App Group journal and lifecycle recovery.
- [ ] Implement basic iOS keyboard input, keyboard switching, session controls, clear activation instructions, and Full Access-denied behavior.
- [ ] Implement Android overlay focus handling, accessibility disclosure/setup, field capability checks, and reliable IME fallback.
- [ ] Apply session-generation cancellation and delivered/uncertain recovery consistently on both platforms.
- [ ] Qualify safe automatic insertion per editor; show explicit Insert/Copy when continuity or delivery cannot be verified.
- [ ] Add single-line behavior, sensitive-field refusal, and tested cursor/selection semantics.

Exit: the cross-app matrix below passes for the declared supported combinations. Optional permissions can be refused without breaking the companion app or Android IME path.

### M4 — minimal companion app and daily-use polish

- [ ] Build setup in this order: explain direct processing -> microphone permission -> install speech model -> configure/test provider -> first cleaned sample -> cross-app integration setup -> real-app test.
- [ ] Offer a clearly labeled raw-transcription trial if provider setup is skipped; do not mark AI cleanup as configured.
- [ ] Add vocabulary/snippets, Clean/Message/Email choices, original-text access, and local history controls.
- [ ] Add accessibility labels, readable status, dynamic text sizing, haptics, and one-handed stop/cancel controls.
- [ ] Add local diagnostics and a permission/connection repair screen with no account requirement.

Exit: users can complete setup and dictate in another app without a command line, hosted dashboard, or sign-in to Parla.

### M5 — release qualification

- [ ] Add offline CI builds and deterministic tests. Live-provider evaluations are explicit local runs with the operator's own key, not a default CI requirement.
- [ ] Complete physical-device, background lifecycle, cleanup-quality, and energy/memory checks.
- [ ] Verify privacy disclosures, keyboard review behavior, Android accessibility declarations, permissions, third-party notices, and distribution licensing.
- [ ] Prepare TestFlight and Play testing builds with accurate supported-app/device documentation.
- [ ] Record unresolved limitations and final device/model choices before public release.

Exit: release documentation matches observed behavior; unsupported paths are explained; product readiness does not depend on a Parla service being available.

Dependency order: M0 -> M1 -> M2 -> M3 -> M4 -> M5. iOS and Android implementation can progress independently after the shared behavior contracts are fixed. Use M0 results to estimate the remaining work; mobile background execution and editor compatibility have not yet been validated for Parla.

## 8. Verification and acceptance

Use existing checks after shared Swift code changes: `swift build`, `swift test`, and `swift run parla-eval verify`. Add platform build/test commands once the actual Xcode schemes and Gradle modules exist; do not document unverified commands as already runnable.

Automated checks should cover substantive behavior: prompt parity, exact snippet matches, output guards, secret exclusion from serialization/logs, endpoint-key isolation, late cancellation, focus invalidation, session expiry, insertion acknowledgement loss, and model-integrity failures. Use fake provider responses for offline coverage of authentication, rate limit, malformed output, timeout, and cancellation. Do not make normal tests dependent on real API spending.

Physical cross-app matrix:

| Area | Required examples |
|---|---|
| Messaging | WhatsApp plus Messages on iOS; an Android messaging app; Slack or Telegram |
| Email | Gmail; Apple Mail on iOS or another Android mail client; subject and body separately |
| Notes | Apple Notes on iOS; Keep or Samsung Notes on Android |
| Browser | Safari/Chrome ordinary inputs and multiline/contenteditable fields |
| AI chat | ChatGPT and another available AI-chat composer; insert without submitting |
| Restricted input | Password, numeric/phone fields, app rejecting third-party keyboards, missing accessibility node |
| Lifecycle | App switching, field switching, keyboard dismissal, screen lock, incoming call, headset change, process death, permission revocation |
| Text integrity | Existing draft, selection, emoji, combining marks, RTL text, multiline text, names, numbers, and self-corrections |

Record each app version, OS, device, input route, result, and fallback. A skipped/uninspectable case is not a pass. Use test drafts and local harness fields; never send messages as part of verification.

Measure start-to-capture and stop-to-local-transcript separately from cleanup request time and final insertion time. Report cold/warm models and network conditions separately. Establish latency budgets using M0 measurements; do not carry desktop timings into mobile claims. Include sustained dictation and repeated short utterances to expose battery drain, thermal throttling, and memory pressure.

Evaluate cleanup with real accented/noisy mobile speech and the existing numbers, correction, jargon, snippets, and injection fixtures. Measure zero-edit rate and preserved meaning; WER alone cannot validate cleanup. Test English initially and qualify any multilingual claims against the selected multilingual model; an English-only model cannot satisfy Hindi/Hinglish or other-language requirements.

Product release gates:

- No silent wrong-field insertion, overwritten draft, accidental send, or replay after uncertain delivery in the tested matrix.
- Core cross-app interaction passes on the declared minimum devices, including iPhone background execution and Android overlay/IME routes.
- All speech recognition stays on-device; network inspection shows only user-selected cleanup traffic and explicit model downloads.
- API keys are absent from ordinary settings, shared extension data, diagnostics, and source control.
- Cleanup failure offers a usable original; provider setup is required only for the AI feature, not for launching Parla.
- No Parla account, sign-in, backend dependency, managed credentials, or remote configuration is needed at runtime.

## 9. Primary references checked during planning

- [Apple custom keyboard architecture and restrictions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
- [Apple keyboard Full Access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
- [Apple review guidelines — background services and keyboard extensions](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Metal background restrictions](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background)
- [Apple optional background GPU resource](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources/gpu)
- [Android input methods](https://developer.android.com/develop/ui/views/touch-and-input/creating-input-method)
- [Android foreground-service restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Google Play accessibility API policy](https://support.google.com/googleplay/android-developer/answer/10964491)
- [whisper.cpp upstream — mobile platforms and examples](https://github.com/ggml-org/whisper.cpp)
- [Wispr Flow iPhone setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- [Wispr Flow Android setup](https://docs.wisprflow.ai/articles/8858845757)

These sources establish constraints and reference patterns. They do not substitute for implementing and testing Parla on physical mobile devices. Recheck applicable platform/store requirements at implementation and submission time.
