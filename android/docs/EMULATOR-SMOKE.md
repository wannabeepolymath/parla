> Historical build evidence. Current parla1.2.0 floating-control status is documented in [Gboard control](GBOARD-CONTROL.md); no device testing was resumed.

# parla Android emulator smoke

2026-10-28 local date. Existing T3 device `parla-test` / `emulator-5554`, Android 14, was reused. No new emulator or browser. Screens are 1080×2400 PNG; app debug metrics report content pixels 1080×2209, density420/2.625, fontScale1.0, light mode, en_US. Logs: `evidence/parla-rename/parla-visual-evidence.log`.

The previous smoke task was confirmed interrupted with no active run and no continuing device command before mutation. Its exact retained session `t3-846c513fc2f9f69de2640d75` held the device lock; closing that confirmed task-owned session released it without clearing data or shutting down the emulator. Original task screenshots remain unchanged in `evidence/emulator-smoke-20261028/`. No old task CRUD entries existed in its activity. The new `dev.parla.android` app was installed alongside the old `dev.flow.android`, preserving old private data and keys.

All device actions used `/Users/daksh/.t3/userdata/device/bin/agent-device` with `--platform android --serial emulator-5554 --config /Users/daksh/.t3/userdata/device/hosts/25bf8e1a2393f1108d37029b.json --session t3-d3815c26655e2b93a8de32d5`. `device_list` then `device_open` attached that device. `device_screenshot` supplied visual inspection. The only direct adb command read the ParlaVisualEvidence log; no adb install/control/query was used. The test driver and later action/snapshot transcript are retained under `evidence/parla-rename/`.

## Observed results

| Check | Result and evidence under evidence/parla-rename/screens/ |
|---|---|
| Launch without sign-in | PASS. Intro/permission sequence can be skipped without granting permissions; Home opens. `01-onboarding.png`, `02-permission-copy.png`, final Home captures. |
| Current identity | PASS. Lowercase parla wordmark in header/drawer; native p mark in onboarding, Android launcher and Settings. `19-launcher.png` shows the packaged adaptive icon rather than generic Android. Other installed Flow, Wispr Flow and uppercase Parla apps are unrelated preserved packages, not current UI strings. |
| Home → Dictionary → Style → Snippets | PASS. All four destinations open in that order. Home is quiet/local with zero words. Empty dictionary/snippets and populated synthetic states exercised. |
| Dictionary CRUD | PASS. Added `ParlaSmoke20261028`, edited to `ParlaSmoke20261028Edited`, deleted through row menu + confirmation. `04-dictionary-edited.png`, `05-dictionary-clean.png`; final build clean list verified. Only this task-owned word was removed. |
| Snippets CRUD | PASS. Added trigger `parlasmoke20261028` / `Synthetic parla smoke expansion.`, edited trigger to `parlasmoke20261028edited` / `Synthetic parla smoke expansion edited.`, deleted through row menu + confirmation. `07-snippet-added.png`, `08-snippet-edited.png`, `09-snippets-clean.png`; final clean list verified. |
| Style selection | PASS for open/cancel. Personal/Casual preview and Formal/Casual selection sheet visible; dismissed with Close sheet, no selection persisted. `06-style-sheet.png`. Other categories displayed; each category's full sheet was not separately exercised. |
| Drawer → Settings / Account / API | PASS. Local Account destination opens without sign-in; Settings lists parla bubble labels. API defaults remain https://api.openai.com/v1, gpt-transcribe, gpt-4.1-mini. Empty key field inspected; never entered keys, saved settings or sent requests. `10-drawer.png`, `11-settings.png`, `12-api-no-key.png`, `17-account.png`; final API screenshot retained. |
| Overlay boundary | NOT ALLOWED, left unchanged. Android's Display over other apps list shows `parla, Not allowed`. `14-overlay-boundary.png`. Idle overlay not shown, no microphone started. |
| Accessibility branding | PASS for label/description; service remains OFF. Android lists `parla text insertion`; detail describes original-editor safety/context rules using parla. `15-accessibility-list.png`, `16-accessibility-detail.png`. No enable/shortcut toggle. Compiled config settingsActivity is dev.parla.android.MainActivity. |
| Practice editor | PASS for synthetic typing and cleanup. Entered `Synthetic parla practice text, no microphone.`, captured `18-practice-synthetic.png`, cleared to original `Your words go here…` hint and returned Home. No recording or injected history/data. |
| Header alignment | Direct screenshot found the shorter text left-aligned inside the old 114dp image box. ParlaWordmark now centers its text within that existing width. Corrected Home/drawer captures retained separately; no old frame overwritten. |

No app failure occurred during these checks. agent-device deliberately reported foreground-escape errors when permission buttons opened Android Settings; screenshots and fresh snapshots confirmed the expected Settings destination. One stale ref was rejected after typing; a fresh snapshot was used. These were tooling boundaries, not app crashes. More-options targets are merged into row semantics, so their actual icon positions were tapped after inspecting the row geometry.

## Explicitly untested

Live transcription/cleanup, real microphone capture, foreground notification rendering/actions, automatic accessibility insertion, raw/cleaned history Copy selection, permission-granted idle bubble, original runtime parity, real-phone installation and Play Protect classification. No synthetic history was injected and no paid API, real account, protection change, root, uninstall, clear-data or original/reference-helper reinstall was performed. Unit tests cover mocked API/history behavior; device observations do not substitute for the untested flows.

## Retained resources and artifact versions

The emulator remains booted, new parla remains installed, and Home is left visible in the T3 Device panel. The current agent-device session above remains open for the user. Shared Gradle/Kotlin daemons and caches remain. No task-owned database or external server was created. Task-owned dictionary/snippet/practice text is cleaned. Existing unrelated packages, permissions, accounts and data remain untouched.

Screens 01–20 and `first-build.apk` cover the initial rename smoke. Screens 21–26 cover the centered-wordmark build; dictionary/snippet cleanup and empty API state were rechecked after updating. The final artifact adds only the notification's transparent mark resource correction; final launch and Home were checked again. All earlier captures/bytes remain labeled by this chronology. Full current artifact identity, hashes and final screen are recorded below and in releases/manifest.json. The source archive and diff are frozen for the parent's fresh sol-loop; no review was run by this implementation task.

Final artifact: `releases/parla-android-1.0.0-debug.apk`, package `dev.parla.android`, SHA256 `5e9ded813445c37e234910183900c371447db6bb836a32e8da54263de9a8648c`, 29580710 bytes.

Final release Home: `evidence/parla-rename/screens/27-release-home.png`. Final launch succeeded after install; the Home snapshot shows Show parla Bubble and Home/Dictionary/Style/Snippets. Notification mark rendering remains explicitly untested because overlay access is not allowed.


## Offline insertion and keyboard follow-up — 2026-10-28

Testing/report-only follow-up; historical sections above remain unchanged. Full report, screenshots, command transcript, XML and logs: `evidence/parla-device-insertion-20261028/REPORT.md` and `manifest.json`.

Normal Android consent enabled only parla overlay access and parla text insertion accessibility. Shortcut remains OFF; microphone/notifications were not granted. Permission-enabled idle bubble and notification checks could not proceed: `ParlaApp.startBubble` (MainActivity.kt:101) and `ParlaService.activate` (ParlaService.kt:49) require microphone permission even for idle startup. No bubble/record tap or permission bypass.

Current existing DeviceSafetyTest executed via offline Gradle on the same parla-test/emulator-5554: **6 tests, 2 passed, 4 failed, 0 errors/skips** (Gradle exit 1). Key encryption/corruption/recovery cleanup and stopped-before-start recorder tests passed. All four editor tests failed at `DeviceSafetyTest.service()` before capture/insertion/fallback, because `ParlaAccessibilityService.instance` was null despite prior Android consent and the post-test Enabled setting. Logs show the accessibility-service process started after APK replacement, then killed for instrumentation startup. Exact rebinding cause remains unconfirmed. These failures do not verify insertion, clipboard fallback, or sensitive-field protection. No source/test fixes or extra rerun.

Practice accepted task-owned synthetic text and was cleared afterward. Keyboard status reported helper IME com.callstack.agentdevice.imehelper, visible=no; screenshot `09-practice-synthetic-ime-hidden.png` does **not** establish a default visible keyboard or overlay coexistence. No clipboard read/clear: both fallback tests stopped before writes. API key empty after the guarded synthetic crypto test; no live API, actual audio capture, history injection or user-data deletion.

Release APK remains byte-identical: SHA256 `5e9ded813445c37e234910183900c371447db6bb836a32e8da54263de9a8648c`, 29580710 bytes. All 66 checked app source/build configuration files match the frozen rename implementation. Only docs and this new evidence were written. Current test APK packaged offline and installed via agent-device; normal Gradle instrumentation used leaveApksInstalledAfterRun=true and uninstallIncompatibleApks=false. Unit tests/lint were not rerun.

Completed prior task-owned session t3-d3815c26655e2b93a8de32d5 was closed to release its installation lock. Current pinned session t3-e19a47b9cdd880e7af08875e uses the same host config `/Users/daksh/.t3/userdata/device/hosts/25bf8e1a2393f1108d37029b.json`. Existing emulator remains running, Home visible (`12-final-home.png`), bubble hidden, overlay/accessibility enabled, shortcut OFF, mic/notification permissions ungranted. Task test package dev.parla.android.test remains installed; shared Gradle caches/daemons preserved, no task process running. dev.flow.android and unrelated/original/helper apps preserved. Real-phone/Play Protect, original parity, successful insertion, visible keyboard coexistence and live pipeline remain unverified.
