# parla rename

## Read-only audit before edits (2026-10-28)

No source/device mutation began until the old smoke thread was confirmed interrupted, activeRunId null, and process inspection found no continuing agent-device command (only the shared daemon). No task-owned dictionary/snippet entries had been created according to its retained activity. Existing evidence remains untouched.

Baseline paths below are relative to the complete `evidence/parla-rename/baseline-full.zip`; source line references are pre-rename. Full manifest fingerprint: `9eacce674d46ab7d23ada3e7a39812b59937c50fa2cc56e3f93af10b1ec6f1a8`. Source manifest fingerprint: `2aaafa19f9c6fb4d8a9c26513124754206b3af27cad4132abfc92ad79d5cbbc6` (83 files, 3547 text lines). The full archive includes existing evidence, releases, helper APK inputs and all non-generated files; only .git, .gradle, build directories and the snapshot itself are excluded. No reset/stash/commit.

| Surface / observed dependency | Baseline evidence and action |
|---|---|
| App identity/components | app/build.gradle.kts:6,9 namespace/applicationId; settings.gradle.kts:3 project name; AndroidManifest.xml:9,13,16 label/icon/theme/services. Rename own namespace and components; permissions unchanged. |
| Kotlin callers/types | MainActivity.kt:66–104 calls FlowApp/FlowService/FlowAccessibilityService; ReferenceDesign.kt:36 typography; all main/test/androidTest package declarations and DeviceSafetyTest.kt:99 service references. Rename declarations, file paths and actual callers together. |
| Header/drawer and mark | MainActivity.kt:120,137 loads ic_wispr_logo_text.png; :220–221 FlowLogo loads ic_bar_wispr; BubbleWindow.kt:111 loads same glyph. Replace wordmark with lowercase text using existing Figtree; create native p monogram shared across UI/bubble/launcher. Remove current copied branded assets. |
| Visible copy and accessibility | MainActivity.kt:244–267 onboarding, :320 bubble, :544–546 settings, :666–689 privacy/insertion; BubbleWindow.kt:40,82; FlowAccessibilityService.kt:187,191; WavRecorder.kt:36,41; styles.xml:5. Rename all own product mentions lowercase. |
| Notification/actions/clipboard | FlowService.kt:31 channel label, :151–157 icon/title/action, :172–176 dev.flow actions, :191 clipboard. Rename own actions and channel identity/label. |
| Private storage | Store.kt:25 flow-data.json, :118 flow-provider-key-v1. New package gets separate parla filenames/key alias. Old app data and keys untouched; no migration claimed. |
| Fixtures/logging | ApiClientTest.kt:30 synthetic prefix, :38,59 vocabulary fixture; MainActivity.kt:65 debug tag. Rename own fixture vocabulary and tag, preserving library concepts. |
| Helper | tools/reference-installer/app/build.gradle.kts:3,5 and Java package; manifest label. Rename independent helper identity only. |
| Current distribution/docs | README.md, docs/VERIFICATION.md, PLAY-PROTECT-APPEAL.md and releases manifest/SHA point at old build. Archive those exact bytes/metadata; current pointers will name parla. Prior reviews are pre-rename, no approval inherited. |

Deliberate remaining identifiers: kotlinx.coroutines.flow, MutableStateFlow/StateFlow/asStateFlow, TextOverflow and rejectsRiffOverflow are library/raw concepts. The helper's com.wispr.flowapp target and input APK filename identify the unchanged original, and its explanatory original Wispr Flow copy stays honest. Original ../wispr-flow paths, source declarations, assets.json provenance, fonts/licenses, previous screenshots/logs/review archives/hashes, quoted warning, and historical Flow APK identity remain explicitly historical/reference evidence. They are not current product branding.

This explicit product rename does not address Play Protect classification, alter API models/settings, remove permissions, or promise migration. Original app is not reinstalled. Parent owns a fresh sol-loop after implementation; no review is run here.

Final artifact: `releases/parla-android-1.0.0-debug.apk`, package `dev.parla.android`, SHA256 `5e9ded813445c37e234910183900c371447db6bb836a32e8da54263de9a8648c`, 29580710 bytes.

## Implemented and verified source map

Current paths are `app/src/main/java/dev/parla/android/` and equivalent test/androidTest paths. MainActivity.kt:57–104 contains ParlaColors/ParlaApp/ParlaService and exact accessibility component detection; :120,137 use ParlaWordmark, defined at :220 with Figtree and centered lowercase text. ParlaLogo at :225 uses ic_parla_mark, also called by BubbleWindow.kt:111. Manifest:9 points icon and roundIcon at the adaptive mipmap, :13/:16 declare ParlaService/ParlaAccessibilityService. The launcher foreground has the native monogram; no raster wordmark is packaged. Theme.Parla and the accessibility description are in res/values/styles.xml; settingsActivity is dev.parla.android.MainActivity in res/xml/accessibility_service.xml:10.

ParlaService.kt:32 names the parla notification channel, :151 uses the transparent mark, :152/:157 rename notification title/stop action, :172–177 define dev.parla actions and parla_dictation channel. Both clipboard paths and BubbleWindow accessibility descriptions name parla. Store.kt:25 and :118 use parla-data.json / parla-provider-key-v1. API models/settings and all app permission declarations retain their behavior. No old app keys/files were accessed or migrated.

tools/reference-installer uses dev.parla.referenceinstaller and lowercase parla reference installer label; compile passed. Its original com.wispr.flowapp target and input APK filenames remain unchanged; it was not installed/run. rootProject.name is parla for the app and parla-reference-installer for the helper.

All 35 meaningful existing tests pass; lint zero errors/15 warnings, assembly and androidTest source compilation pass offline. A source and packaged DEX/resource scan found no old current product branding; retained matches are exactly library concepts or the explicit original-reference helper/evidence/history exceptions listed above. Notification/clipboard runtime behavior is untested without microphone/API work; labels/callers were checked statically. The current APK's v2 debug signature and merged/packaged component names were verified using the installed Android tools.

Two narrow rename corrections followed direct evidence: the first Home screenshot showed the shorter text left aligned in the old image width, so ParlaWordmark uses TextAlign.Center; the notification icon caller pointed to an opaque background-filled app vector, so it now uses the transparent shared mark and the unused vector was removed. Each resulting build/check log and intermediate APK is retained; no historical evidence was overwritten.

## Reproduction and review handoff

No HEAD exists and all project source is untracked. Run `python3 evidence/parla-rename/freeze-source.py` from Android to select the same source scope, write current-source.zip/manifest, reconstruct baseline/source and current/source, and generate binary `source.diff`, `diff-stat.txt`, `diff-numstat.txt`, and `source-summary.json`. All source, resources, build scripts, wrapper, licenses, docs and helper code are included; helper original APK inputs remain separately preserved in the full baseline. The diff is a Git no-index snapshot comparison including untracked files. From Android, extract baseline-source.zip into a clean `evidence/parla-rename/reproduction-check/source` and run `git apply -p3 --directory=evidence/parla-rename/reproduction-check/source evidence/parla-rename/source.diff`; this reconstructs current/source including renames, binary deletion and new untracked files (verify resulting hashes against current-source-manifest.json). Frozen paths are relative to Android; do not apply over unrelated work.

The full baseline snapshot includes all pre-existing non-generated files. `preservation-check.json` verifies every protected historical evidence/reference/helper-input file unchanged and all moved old deliverable bytes/metadata identical. `SHA256SUMS` under evidence/parla-rename fingerprints retained evidence including archives, APKs, logs and screens. The final source fingerprint and before/after file/line counts are deliberately stored in source-summary.json to avoid a self-referencing source manifest. Parent owns the next fresh sol-loop; after this handoff no scoped mutations remain active.

## Sol-loop result

Approved in one fresh round by Paawan GPT-6.1 Sol on high effort; no findings, no further source edits. All 86 files matched the frozen current manifest and the diff reproduced byte for byte. No commit or push; usage not exposed. Final ledger: `evidence/parla-rename/sol-loop-ledger.json`. Post-review changes only record approval in documentation and release metadata; the APK and approved behavior remain unchanged.
