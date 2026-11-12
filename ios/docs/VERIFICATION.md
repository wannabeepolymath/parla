# Verification

Run: 2026-11-12–13, Asia/Kolkata. Xcode 26.6 (17F113), iPhoneSimulator SDK 26.5, iOS 26.5 Simulator, local **iPhone 17** (`50C01478-E2B8-4C5F-A9E8-05862F140B2B`). Debug builds include arm64 and x86_64; runtime tests use arm64. No physical-device build, archive, model download or recognition run was performed.

Evidence is local and git-ignored: `ios/evidence/simulator-2026-11-12/`. Paths below are relative to that directory. No evidence, team ID or credential is committed.

## Build and test commands

From the repository root (the README also has commands using the Simulator name):

```sh
xcodebuild -project ios/Parla.xcodeproj -scheme Parla -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=50C01478-E2B8-4C5F-A9E8-05862F140B2B' \
  -derivedDataPath ios/evidence/simulator-2026-11-12/DerivedData \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
xcodebuild -project ios/Parla.xcodeproj -scheme Parla -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=50C01478-E2B8-4C5F-A9E8-05862F140B2B' \
  -derivedDataPath ios/evidence/simulator-2026-11-12/DerivedData \
  -resultBundlePath ios/evidence/simulator-2026-11-12/tests-05-lifecycle.xcresult \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

Ad-hoc signing reports `Signature=adhoc`, `TeamIdentifier=not set`. Simulator entitlements are injected by Xcode; the app and extensions can access `group.dev.parla.ios`. `CODE_SIGNING_ALLOWED=NO` also builds and runs, but the device log reports “client is not entitled” for App Group access. Use ad-hoc signing for keyboard/shared-storage verification. `Configuration/Signing.xcconfig` still has an empty `DEVELOPMENT_TEAM`.

| Check | Result | Evidence |
|---|---|---|
| Generate project | Deterministic project regenerated from scripts; no manual pbxproj edits | `Scripts/generate_project.py`, generated project |
| Structural validation | PASS, 745 checks | `project-validation-final.log` |
| Static type/syntax check | PASS, all 7 stages, 26 native compilation units (after architecture fix) | `typecheck.log`, `../implementation/typecheck-results.json` |
| Initial unsigned build | Failed at x86_64 app link | `build-01.log` |
| Architecture-correct unsigned build | PASS: app, keyboard, widgets, ParlaCore | `build-02.log` |
| Ad-hoc build | PASS: app, keyboard, widgets, ParlaCore; both Simulator architectures linked | `build-03-adhoc.log`, `app-signing-details.log` |
| Keyboard appearance fix build | PASS | `build-04-keyboard.log` |
| First hosted test run | 33 executed, 2 unexpected failures from one fixture and its teardown | `tests-01.log`, `tests-01.xcresult` |
| Fixture-corrected test run | PASS: 33 tests, 0 failures | `tests-02.log`, `tests-02.xcresult` |
| Ad-hoc hosted test run | PASS: 33 tests, 0 failures | `tests-03-adhoc.log`, `tests-03-adhoc.xcresult` |
| First keyboard-fix hosted test run | PASS: 33 tests, 0 failures; subsequent UI audit found teardown crashes outside these tests | `tests-04-keyboard.log`, `tests-04-keyboard.xcresult` |
| Final lifecycle-fix hosted test run | PASS: 33 tests, 0 failures | `tests-05-lifecycle.log`, `tests-05-lifecycle.xcresult` |

Nonfatal warnings remain in vendored whisper/ggml (integer precision, etc.) and SDK auto-link diagnostics. They were not suppressed. Duplicate vendor basenames were handled by Xcode's distinct object names; no basename workaround was needed.

## Confirmed blockers and fixes

1. **Architecture mismatch at link time.** `Scripts/parlacore.py` originally compiled ARM quantization/repack sources for x86_64 as well. The app link missed seven x86 repack functions, including `ggml_quantize_mat_q8_K_4x8` and `ggml_gemm_q2_K_8x8_q8_K`. `Sources/Core/CPUQuants.c` and `CPURepack.cpp` now select the existing ARM or x86 vendor sources using compiler architecture macros. The manifest, generator, validator and syntax checker use the same native-source list. Both architectures now link. Vendor sources are unchanged.
2. **Test fixture setup.** `SessionStorageTests.testAppReplacesOversizedEnvelopeSoDictationCanStartAgain` wrote its oversized file before any transaction had created the UUID directory. The write failed with file-not-found, then teardown failed on the same absent directory. `setUpWithError` now creates the directory before seeding fixtures. No assertion or expected behavior was changed.
3. **Simulator App Group access.** Unsigned execution lacks the injected entitlement. Rebuilding/installing with ad-hoc signing and no team restored container access. `app-group-container.txt`, `device.log` and the keyboard request appearing in the app prove access; `shared-session-after-cancel.json` records a cancelled keyboard session. This is a documented invocation change, not a committed team/signing credential.
4. **Keyboard document-proxy lifecycle.** Selecting the keyboard initially crashed while bridging the host's absent Objective-C UUID to Swift in `render(force:)`, called from `viewDidLoad`. Deferring initial rendering allowed the keyboard to load, revealing two more traps when `textDidChange` ran during host teardown. Rendering is now restricted to the visible lifecycle, polling stops in `viewWillDisappear`, and the redundant document UUID was removed from the render cache key. `textDidChange` already forces redraws when the document changes. Request/insertion identity checks remain intact.

No file under `Sources/ParlaCore` changed. Root `swift build` was not run: the requested macOS compatibility build was conditional on a shared desktop change. All implementation changes are inside `ios/`.

## Executed unit tests

| Suite | Tests |
|---|---:|
| CleanupTransportTests | 3 |
| DeliveryTests | 2 |
| DesktopCoreGlueTests | 8 |
| EditorAndBackgroundTests | 2 |
| RetentionTests | 2 |
| SessionStorageTests | 13 |
| SpeechReservationTests | 3 |
| Total | 33 |

These exercise injected recognition/cleanup, silence and duration floors, local transforms, model-file rejection, PCM16 WAV round-trip, streaming resampling, retention, one-time delivery, cancellation/ownership, storage failures, bounded shared results, background-task seams, editor state, speech-reservation seams, and synthetic cleanup HTTP limits/discovery/307/308 refusal. HTTP fixtures do not contact a network. They do not exercise actual model inference, hardware capture or real speech assets.

## Simulator screen and behavior pass

The device was opened through T3 `device_list` / `device_open` on host `local`. All launches, deep links, taps, text entry, keyboard settings and captures used the exact returned `agent-device` command. `simctl` was used only for installation, logs and container metadata; `xcodebuild` ran the tests.

Visited all four onboarding pages, Home/history, menu, Scratchpad, note editor, Dictionary, Snippets/editor, Models, Settings, Language, all three Cleanup provider forms, rewrite/translation preset forms, Replacements/editor, retention/privacy/help sections, feedback sharing, Local account, export sharing and delete confirmation. No delete or share destination was selected. A typed note was saved and survived app relaunch. Cleanup remains off and the provider was restored to Anthropic; no key was entered.

Apple Speech is unavailable on this Simulator, so its conditional preparation section is absent. Per-app profiles deliberately have no iOS screen, as explained in Settings and IMPLEMENTATION.md. History remains empty: transcript detail, retained-audio playback and Retry are unreachable without recording/creating a transcript under this task's constraints.

The keyboard was added through Settings → General → Keyboard → Keyboards, and Full Access was enabled. After the lifecycle fixes, typing, deletion, voice-panel entry, a shared keyboard request, cancellation and Hide keyboard were exercised. The app displayed the matching pending banner and removed it on cancellation. Microphone capture was never started.

Final teardown/reopen regression check: PASS on the complete fix. The same keyboard process survived typing, deletion, request/cancel, hiding, reopening and hiding again. The request/cancel banner transitions are recorded in `final-regression.log`; final screenshots are `38`–`43`. No new crash report appeared during the final check.

### Screenshots

45 PNGs are retained under `screenshots/`; `SCREENSHOTS.md` is a clickable local index. `01`–`05` capture the initial unsigned onboarding pass; the app screen pass thereafter used ad-hoc signing. Pre-fix fallback captures and repaired keyboard captures are distinguished below.

- `01-launch.png` — onboarding welcome.
- `02-onboarding-keyboard.png`, `03-onboarding-keyboard-repeat.png` — keyboard setup page (second capture repeats the visible portion).
- `04-onboarding-privacy.png`, `05-onboarding-practice.png` — remaining onboarding pages.
- `06-home.png`, `07-menu.png` — empty history and navigation.
- `08-scratchpad.png`, `09-note-editor.png`, `10-note-saved.png` — empty, editor and saved-note states.
- `11-dictionary.png`, `12-snippets.png`, `13-snippet-editor.png` — vocabulary screens.
- `14-models.png` — all three models; no download started.
- `15-settings.png`, `16-language.png` — settings and language list.
- `17-cleanup-anthropic.png`, `18-cleanup-apple.png`, `21-cleanup-openai.png` — provider forms.
- `19-preset-rewrite.png`, `20-preset-translate.png` — unsaved preset forms.
- `22-replacements.png`, `23-replacement-editor.png` — replacements.
- `24-settings-lower.png`, `25-feedback-share.png` — retention/privacy and feedback sheet.
- `26-local-account.png`, `27-delete-confirmation.png`, `28-export-share.png` — local account and its confirmations/sheet.
- `29-add-keyboard.png`, `30-keyboard-access.png` — system keyboard installation/access settings.
- `31-keyboard-before-fix.png`, `31-keyboard-before-fix-retry.png` — Apple keyboard fallback during the initial crashes.
- `31-keyboard-fixed.png`, `32-keyboard-typing.png`, `33-keyboard-voice.png` — loaded Parla keyboard, typed character and voice panel.
- `34-keyboard-request.png`, `35-keyboard-cancelled.png`, `36-keyboard-hidden.png` — shared request, cancellation and hiding.
- `37-keyboard-voice-reopened.png` — reopened voice panel.
- `38-final-keyboard.png`, `39-final-request.png`, `40-final-cancelled.png`, `41-final-hidden.png`, `42-final-reopened.png`, `43-final-hidden-again.png` — complete lifecycle-fix regression. `31-keyboard-fixed` through `37` were captured after the initial appearance-only fix; these final six captures verify the teardown fix as well.

Accessibility capture sometimes fell back from Simulator AX to XCTest/private AX. Stale refs were refreshed; settled refs required their complete state suffix. Extension refs sometimes used window-local coordinates, so screenshots supplied screen coordinates. These automation limitations are separate from the reproduced extension crashes.

## Crashes

Four keyboard SIGTRAP reports were collected: two startup traps (`ParlaKeyboard-2026-11-13-001153.ips`, `...001327.ips`) and two teardown traps after the initial appearance-only change (`...002019.ips`, `...002320.ips`). They all point to `UUID._unconditionallyBridgeFromObjectiveC` from the render signature, through `viewDidLoad` or `textDidChange`. The initial symbolication is in `keyboard-crash-symbol.txt`; lifecycle/system logs are in `device.log` and `keyboard-host.log`.

No iOS app or widget crash was observed. Two older desktop Parla reports predate this run and refer to another executable, so they are excluded (`crash-report-inventory.json`). Final post-fix inventory: four earlier keyboard reports, zero reports after the complete fix. The final regression began at 2026-11-13 00:29:26 IST; `final-audit.json` records the final inventory time and matching report list.

## Consumer-copy findings (listed, not rewritten)

- **Onboarding/setup:** “shared dictation handoff,” “host text,” and “secure and excluded fields” expose implementation terminology (`Sources/App/OnboardingView.swift`).
- **Models:** “quantized,” “HTTPS,” “pinned size,” “SHA-256,” and the versioned model name “Large v3 Turbo” (`Sources/App/ModelsView.swift`, display names from the shared ModelCatalog).
- **Dictionary:** “2,048-byte recognition hint,” “8,192-byte cleanup budget,” and “256 bytes” (`Sources/App/NotesAndLexicon.swift`).
- **Cleanup / Anthropic:** raw model identifier `claude-haiku-4-5`; “Local servers may not need one” appears even for Anthropic (`Sources/App/SettingsView.swift`, shared credential/model labels).
- **Cleanup / Apple Intelligence:** the locale code `en`; provider privacy text mentions HTTPS, Keychain and App Group (`Sources/App/SettingsView.swift`).
- **Cleanup / OpenAI-compatible:** “Base URL (https://…/v1)” and the corresponding base-URL validation messages (`Sources/App/SettingsView.swift`).
- **Settings:** “16 kHz audio,” “audio route changes,” “interruptions,” and “temporary delivery result” make the retention/audio explanation technical (`Sources/App/SettingsView.swift`).
- **Preset editor:** “dictated text never supplies instructions” describes an internal prompt boundary (`Sources/App/SettingsView.swift`).
- **Keyboard request:** “No automatic app switch or return is promised” and “voice handoff” are developer-oriented descriptions (`Sources/Keyboard/KeyboardViewController.swift`).
- **Local account/export:** “JSON” and the share preview's raw settings identifiers, including desktop-oriented keys such as `hotkeys` (`Sources/App/SettingsView.swift`, `LibraryStore.swift`). The export format is intentionally JSON, but it is user-visible technical content.

## Not verified

- No models downloaded, hashed at catalog size, loaded or decoded; no CPU inference speed/memory/accuracy assessment.
- No microphone/speech permission granted, real capture, cue playback, hardware resampling, interruption handling or background recording.
- No Apple Speech assets prepared/released or real recognition, and no Apple Intelligence inference.
- No API keys entered, provider calls or paid requests; Keychain save/remove behavior remains untested.
- No successful dictated-result review/insertion into another app, secure-field keyboard fallback, clipboard delivery, transcript playback/Retry or real background expiration. Keyboard request/cancel used Parla's own search field as the host.
- Widgets compiled, linked, embedded and their extension ran for system descriptor/preview requests. Home/Lock Screen widget placement, controls, Live Activities and App Intents were not interacted with.
- No physical iPhone, Intel Simulator execution, Release build or archive. x86_64 was compiled and linked only.

## Retained resources

The evidence directory retains logs, result bundles, screenshots and its own DerivedData (about 1 GiB); it is intentionally uncommitted. The iPhone 17 Simulator retains the installed app/extensions, added keyboard with Full Access, a test note and local settings. No model or API key was added. The device was removed from the T3 panel with `device_close(shutdown: false)`. Device-tool session/cache files are T3-managed and are not manually removed. The task-owned device log stream was stopped and all xcodebuild runs finished. No task-owned build/log process remains. T3-managed automation session: `/Users/daksh/.t3/userdata/device/agent-device/sessions/t3-2fa45aedbe89a6edecfce202`; shared tool caches were preserved. `RESOURCES.md` records app/group container locations and retained artifacts.
