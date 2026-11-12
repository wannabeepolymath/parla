> Historical build evidence. Current parla1.2.0 floating-control status is documented in [Gboard control](GBOARD-CONTROL.md); no device testing was resumed.

# Current parla verification

Current deliverable: `releases/parla-android-1.0.0-debug.apk`, package `dev.parla.android`, label `parla`, version1.0.0(1). SHA256 `5e9ded813445c37e234910183900c371447db6bb836a32e8da54263de9a8648c`, 29,580,710 bytes. The product rename supersedes the copied original identity; original reference material and prior approval below are historical.

The required pinned-wrapper command completed successfully with the existing JDK17/SDK, offline: `:app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:compileDebugAndroidTestKotlin`. All 35 unit tests pass, zero failures/errors/skips. Lint: zero errors, 15 warnings. Android instrumentation sources compile but were not executed. The independent reference helper's renamed Java package also compiles offline; it was not installed or run. Logs and XML reports: `evidence/parla-rename/gradle-checks-release.log`, `helper-compile.log`, `reports/`, `checks-summary.json`.

Android build-tools verified the packaged manifest, accessibility settingsActivity, resources, components and debug v2 signature. Evidence: `release-apk-badging.txt`, `release-packaged-manifest.txt`, `release-packaged-accessibility.txt`, `release-packaged-resources.txt`, `release-merged-manifest.xml`, `release-apk-signature.txt` under `evidence/parla-rename/`. DEX/asset scan: `release-dex-brand-check.json`; no old own package, brand symbols, copied wordmark/glyph names or storage names remain. kotlinx.coroutines.flow/StateFlow and resource status_bar_notification_info_overflow are legitimate library concepts. Source audit/exceptions: [rename](RENAME-PARLA.md).

The existing Android14 emulator installed the new package beside Flow. Launcher icon, lowercase wordmark, navigation, local dictionary/snippets CRUD with cleanup, Style sheet dismissal, Settings/Account/API, accessibility name/description and synthetic practice typing were checked. Final release Home is left visible, with `screens/27-release-home.png`. Permission-granted overlay, microphone, notification rendering, live API, accessibility insertion and real-phone Play Protect remain untested; exact observations and version chronology: [emulator smoke](EMULATOR-SMOKE.md). No original reinstall, protection change, paid request, key entry, old-data modification or migration claim.

All pre-existing reference/evidence/input files were verified unchanged against the full baseline (250 protected files). The old APK and exact manifest/SHA metadata were moved to `releases/archive/pre-parla-20261028/` with no byte changes. `preservation-check.json` records that check. Other archives remain intact. The new product identity is not claimed to solve the historical Play Protect warning; [installation](INSTALLATION.md) and [unsubmitted appeal draft](PLAY-PROTECT-APPEAL.md).

The implementation is frozen for one fresh parent-owned sol-loop. No implementation sub-agent review, commit, push or publication occurred. All first-version/untracked source is included by `evidence/parla-rename/freeze-source.py` in the baseline/current archives and manifests, binary source.diff and diff counts. Fingerprints and counts are in `source-summary.json`; there is still no HEAD/remotes. Task resources: reused emulator, open pinned device session `t3-d3815c26655e2b93a8de32d5`, task evidence/snapshots/intermediate APKs, and shared build caches/daemons; no external server or task database. Synthetic records are removed; preserve the open device session for user access.

# Historical pre-rename verification

The approved APK includes the four fixes from sol-loop, approved in round2. All 35 unit tests pass (zero failures/errors/skips), lint has 15 warnings and zero errors, and debug assembly succeeds. Log: `evidence/reference/verification-sol-round1-fixes.log`. SHA256: `c3eea5a79a13f7100eaecf97ae4309729ed0fa5ef004c83ec9fab3c0d37c4ed1`. APK v2 signature was reverified and the built bytes matched the reviewed source artifact. Current source matched every round2 manifest entry before packaging. No current device/UI or live API verification is implied.

The earlier distributed APK is preserved under `releases/archive/`. That Flow download is now archived at `releases/archive/pre-parla-20261028/flow-android-1.0.0-debug.apk`. Play Protect installation remains unresolved; the supplied screenshot confirms the sensitive-data warning, with device details still unknown; see `INSTALLATION.md`.

## Earlier recovery checks

The implementation task's remote context compaction failed after its last UI edits. No active task-owned Gradle, REA or agent-device command remained during recovery. The current source was checked again with the pinned wrapper, existing JDK17 and Android SDK:

```sh
JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home ANDROID_HOME=/Users/daksh/Library/Android/sdk ./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug --offline --console=plain
```

- Result: BUILD SUCCESSFUL. Full log: `evidence/reference/verification-recovery.log`.
- JUnit XML: 30 tests, zero failures, zero errors, zero skipped.
- Lint XML: zero errors/fatal issues, 15 warnings. Reports remain under `app/build/reports/`.
- Historical standalone debug APK: `releases/archive/pre-parla-20261028/flow-android-1.0.0-debug.apk`; its exact historical SHA256/size remain in that archive directory’s `manifest.json` and `SHA256SUMS`.
- These checks use local/mocked inputs. No live transcription/cleanup request or end-to-end microphone dictation was performed during recovery.

The preceding device run installed an earlier revised APK and checked navigation and dictionary CRUD, with clone screenshots under `evidence/reference/clone/`. Those frames precede the final Style and BubbleWindow edits; they are not verification of the current APK. Existing instrumentation reports also predate recovery and are not counted as current device verification. The earlier Paawan workspace-routing failure prevented that device pass. The provider later recovered and completed the independent Sol review; see `SOL-LOOP.md`. Current device verification is still outstanding.

The original signed split package installed through the public PackageInstaller helper but stops at a Google Play error before onboarding. No original product-screen comparison pair exists. See `VISUAL-FIDELITY.md` for exact reference limitations.

## Retained task resources

- Existing emulator `parla-test` / `emulator-5554` was reused and preserved. Original `com.wispr.flowapp`, clone `dev.flow.android`, and task helper `dev.flow.referenceinstaller` may remain installed; application data was preserved.
- Pinned device session from the previous task: `t3-c28e8b25a1d41d4fa82a2170`, under `/Users/daksh/.t3/userdata/device/agent-device/sessions/`. No new emulator, browser, or device session was opened during recovery.
- Recovery Gradle command completed. Shared Gradle/Kotlin daemons and download caches were preserved.
- Installer source and unchanged original APK inputs remain under `tools/reference-installer/`. Prior source/APK remain under `evidence/reference/prior-state/`. Current review archive and manifest remain under `evidence/reference/review/`. Nothing was committed, pushed, or published.
