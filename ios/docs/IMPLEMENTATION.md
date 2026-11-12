# Parla iOS implementation

## Targets

| Target | Contents | Links ParlaCore |
|---|---|---|
| `ParlaCore` (static library, module `ParlaCore`) | `Sources/Core/ParlaCoreIOS.swift` shim, the desktop files listed in `Scripts/parlacore.py`, whisper.cpp/ggml CPU sources | — |
| `Parla` (app) | `Sources/Shared`, `Sources/App` | yes, plus `-lc++` and Accelerate |
| `ParlaKeyboard` | `Sources/Shared` (minus intents/activity), `Sources/Keyboard` | no |
| `ParlaWidgets` | `Sources/Shared`, `Sources/Widgets` | no |
| `ParlaTests` | `Tests/ParlaTests.swift`, hosted by the app | via the app |

`Scripts/parlacore.py` is the single list of desktop files, whisper sources, include paths and defines; the generator, type checker and validator all read it.

### Desktop core reuse

The desktop Swift files are compiled unmodified from `../Sources/ParlaCore`. Six macOS-only files are excluded (AudioRecorder, ClipboardDelivery, Inserter, Hotkey, ShortcutDisplay, ParakeetTrust). The shim supplies only the declarations the shared files name: `ClipboardRestoreMode`, `Inserter.TailSwap`, an empty `HotkeyBindings`, the Parakeet trust types (admission always refuses with `unsupportedHost`), the Core Audio transport FourCCs used by `Trace`, `AudioRecorder.targetFormat/rms/convert`, and a streaming `Resampler` to 16 kHz mono Float32.

`import whisper` resolves through `Sources/Core/whisper/module.modulemap`, whose header path is relative to the Android-vendored whisper.cpp v1.9.1. The C/C++ build mirrors that copy's static CPU configuration: ggml-base, ggml (CPU backend registered), ggml-cpu, and whisper. `Sources/Core/CPUQuants.c` and `CPURepack.cpp` select the vendored `arch/arm` kernels for arm64 (iPhone and Apple Silicon Simulator) and `arch/x86` kernels for x86_64 Simulator, matching ggml’s architecture selection. Compiling the ARM repack file on x86_64 leaves x86-specific repack calls unresolved at link time. Defines: `GGML_SCHED_MAX_COPIES=4 _XOPEN_SOURCE=600 _DARWIN_C_SOURCE GGML_USE_CPU GGML_USE_CPU_REPACK GGML_USE_ACCELERATE ACCELERATE_NEW_LAPACK ACCELERATE_LAPACK_ILP64`, version strings, and `NDEBUG` in Release. No Metal, BLAS, OpenMP, KleidiAI, CoreML or parakeet. Defines and private include paths are in `OTHER_CFLAGS`, so they never reach Swift's clang importer. The C/C++ half builds at `-O3` in Debug as well, because ggml is unusable unoptimized.

## Dictation core

- **Settings**: desktop `Settings` through `SettingsStore`, at `Application Support/Parla/settings.json` in the app container (protected, excluded from backup), never in the App Group. Dictionary (ordered by priority), snippets, replacements, output mode (cleanup / raw / saved preset), presets, style, provider and language all live there. A fresh install starts with model cleanup off. A saved catalog model path is rewritten to the current container on load, because iOS moves the container on update.
- **Recognition**: `RecognitionFactory.acquire` with a `RecognitionRequest` built from settings, exactly as desktop. One handle per dictation; the model is released afterwards (Android parity; desktop keeps an idle resident). `Pipeline.transcript(samples:)` applies the desktop silence/minimum-duration floor and vocabulary hints; the floor is checked first so silence never loads a model.
- **Models screen**: the three `ModelCatalog` models. Download uses an ephemeral, cookie-free HTTPS session whose redirects stay on Hugging Face hosts. `ModelCatalog.install` checks size, markup and the pinned SHA-256 before an atomic move into `Application Support/Parla/models`. Explicit Download, Cancel, Delete and Use; deleting the selected model leaves it selected and missing, and dictation then refuses with a Models route. Downloads are not resumable and stop if iOS suspends the app.
- **Apple Speech**: offered when `SpeechTranscriber.isAvailable`. The user picks a supported locale and taps Prepare, which reserves the locale and downloads its assets through the desktop `AppleSpeechNative.assets` ports; each use re-checks installed and reserved state. Models lists Parla’s reserved languages with explicit Release actions. Preparation checks capacity and tells the user to release an unused reservation when full; a refused reservation is not treated as prepared. Reservation changes and dictation cannot overlap. Locales are not released automatically.
- **Cleanup**: `Pipeline(outputSettings:bundleID:nil)` with the desktop `makeCleanupClient` and `CredentialStore.shared`, environment overrides disabled. Apple Intelligence runs on device; Anthropic and OpenAI-compatible use the key in this iPhone's Keychain (generic password, `WhenUnlockedThisDeviceOnly`, not synchronizable, the app's default access group, so extensions cannot read it). A cleanup failure keeps the raw text and shows the reason; the session still completes. The iOS-only `CleanupHTTP` transport is injected for both dictation and history Retry, including the optional OpenAI-compatible `/models` discovery GET. It streams at most 256 KiB per response, refuses every redirect before forwarding a body or credentials, uses request and resource timeouts of at most 15 seconds, and disables cookies, cache and ambient credentials. iOS App Transport Security requires HTTPS endpoints.
- **History**: `LibraryStore` keeps raw, cleaned and final text per dictation. With retention on, audio is stored as 16 kHz mono PCM16 WAV (desktop `RecordingStore.writeWAV`). Retry reads it with `Eval.loadSamples` and re-runs recognition with current settings; without audio, it re-runs cleanup on the raw text. WAV or history-save failures keep the final text for delivery and show a separate history warning. Text is retained in the in-app temporary-result UI before writing the shared session, so a shared write failure still allows copying from Parla; cancellation and ownership checks precede saving and publication.
- **Per-app profiles**: not available. An iOS keyboard cannot learn which app hosts it through public API, so no bundle ID is passed and no profile UI is shown.
- **Icon and logo**: the desktop Parla artwork. `Scripts/make_icon.sh` crops the waveform from `../Resources/parla.svg` into the 1024 px app icon and copies the desktop waveform template (`../Resources/menubar.png`) as the in-app `ParlaLogo`.

## Capture

The app alone owns `AVAudioSession`/`AVAudioEngine`. Start checks the selected model first (missing → Models), then foreground state before and after the permission/cue steps. The tap feeds one streaming `Resampler`, so the app holds 16 kHz mono Float samples only, capped at 300 seconds; reaching the cap stops and transcribes, a conversion failure cancels. Interruptions, route changes and media resets cancel the session through a generation token. Stop and Retry enter the same background task lifecycle, giving iOS-limited time to finish; expiry cancels and every completion or cancellation ends the task.

## Keyboard handoff

The shared protected JSON envelope in the App Group holds one transient session (ID, generation, destination, document ID, keyboard instance, phase, command, result/error, expiry), guarded by `flock` across processes. Sequence: request in keyboard → open Parla → Start microphone → return to the host app → Stop in the keyboard → review → Insert once. Every insertion needs an explicit tap, matching request/document/keyboard-instance identity and an unexpired, unspent result; the result is consumed durably before `insertText`. The keyboard reads only `documentIdentifier` and traits, never surrounding or selected text, and refuses voice in secure, password, one-time-code, credit-card and phone-pad fields. Recording sessions expire after 330 s, processing after 600 s, delivery results become unusable after two minutes and are removed the next time Parla or the Parla keyboard runs. Results published to the shared session are capped at 256 KiB of UTF-8; oversized results stay in the app with instructions to copy there. The shared envelope size is checked before reading (allowing worst-case JSON escaping plus metadata), the keyboard render signature holds only text length and hash, and the review text view is cleared when hidden.

Widgets, the Live Activity (stop/cancel), the recording control and App Intents (start, stop, toggle, clipboard, Scratchpad) use the same session store and never start the microphone from a URL alone. Save current note requires an open editor; Cancel and dismissal clear its draft and identity so an intent cannot save abandoned edits.

## Platform differences

| Behavior | Desktop | Android | iOS |
|---|---|---|---|
| Recognition engines | Whisper, Apple Speech, Parakeet | Whisper | Whisper, Apple Speech (if available) |
| Resident model | idle unload after 300 s | unload per call | unload per dictation |
| Capture cap | 600 s | 300 s | 300 s |
| Profiles | per app/site | exact-app | none (no host identity) |
| First-run cleanup | on (Anthropic) | per settings | off until a provider is chosen |
| Environment key overrides | yes | — | ignored |
| Model download | resumable chunks | resumable chunks | single request, cancel restarts |
| ggml vector math | Metal xcframework | CPU | CPU + Accelerate |
| Retained audio | 128 MiB recovery store | recovery vault | history retention policy |
