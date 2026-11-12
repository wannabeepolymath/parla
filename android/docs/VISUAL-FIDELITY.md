# Visual fidelity to Wispr Flow Android 2.8.3 (182)

Current product: parla (`dev.parla.android`). The original wordmark/glyph are replaced by parla identity under the latest instruction; layout, fonts and unbranded assets remain reference-derived. The audit tables below describe the historical pre-rename fidelity work and its original symbols.

The target is the supplied APK, not marketing material. No exact or pixel-perfect parity is claimed. Original runtime product screens are currently blocked before authentication/onboarding by a Google Play error. All product layout changes in this revision are **source-derived**, unless a runtime comparison is explicitly listed below.

## Reference identity and preservation

- Original base: `../wispr-flow/android/com.wispr.flowapp.apk`, SHA256 `5075ec7997bde7d696e246d62ba8ac0c34046b616606a2c17219c818a0467264`.
- Read-only inputs: original base/config APKs, XAPK, recovered JADX/resources/Smali and dossier. No reference artifact was modified, re-signed, patched, or repackaged.
- Previous implementation source and successful APK preserved in `evidence/reference/prior-state/source-before.zip` and `app-debug.apk`. Prior logs and screenshots remain in `evidence/`. Previous APK SHA256: `aecc7ac88f31c6678acb53248d4f3c196812e2cb92ae5f372d2751b292437aec`.
- Prior implementation task was interrupted; its native reviews were idle and no task-owned mutating command was active in the process list. Attempted cancellation from this child was rejected because the parent owns that task; no unrelated process was terminated. Idle shared Gradle/Kotlin daemons were retained.

## Phase 1 audit, completed before UI edits

Two independent GPT investigators through the inherited `codex-snabbit` profile read the unchanged implementation and recovered declarations. Neither edited files. They were asked neutral questions, allowed no-difference results, sought disconfirming evidence, and reported strongest opposing arguments and deliberate differences. Both finished before UI input mutation. Static excerpts with original paths and line numbers are retained in `evidence/reference/declarations/`.

Paths in this table are relative to `../wispr-flow/artifacts/jadx/sources/com/wispr/`; current locations refer to the preserved pre-edit MainActivity.kt/BubbleWindow.kt.

| Audit conclusion | Verdict and evidence | Strongest argument against / deliberate difference |
|---|---|---|
| Navigation order differs | HOLDS. Current FlowApp iterates Home/Dictionary/Snippets/Style; `ui/dashboard/DashboardNavEntry.java:17` declares Home/Dictionary/Style/Snippets and `DashboardScreenKt.java:390` iterates it. | Same four destinations and bottom navigation are already correct. Replacing bottom navigation with drawer-only navigation would be unsupported. |
| Header/icons/fonts differ | HOLDS. Current FlowLogo is four Canvas strokes; original `ui/dashboard/ComposableSingletons$DashboardScreenKt.java:64` uses ic_menu and `:74` ic_wispr_logo_text; nav assets at DashboardNavEntry:17. `design/TypeKt.java:80` binds Figtree and EB Garamond. | Matching controls/concepts already exist; exact geometry needs runtime frames. Earlier brief deliberately prohibited original identity and prescribed interpreted visuals; latest instruction supersedes that. |
| Universal cream background differs | HOLDS. Original home, lists, header and navigation use Neutral100 #EEEEF0 (`HomeScreenKt.java:1674`, `DashboardScreenKt.java:351`, DictionaryScreenKt:742). | Current cream #FFFFEB and lilac #F7EBFF are genuine original Lumen/Primary300 tokens, just applied to the wrong surfaces. |
| Home hierarchy differs | HOLDS. `ui/home/HomeScreenKt.java:19913` places conditional error/education cards, insights pager, quiet empty state and grouped transcript items; current invented hero/title/stats/recent-activity hierarchy differs. | Conditional original cards are state/experiment dependent. Copy/retry/delete callbacks correspond (`:20209`). No fabricated remote stats are justified. |
| Dictionary/snippets structure differs | HOLDS. Original Search (16h/8v padding), centered empty text, FAB and 56dp swipeable rows (`ui/dictionary/DictionaryScreenKt.java:948`, `:1013`, `:1404`; snippets :1035/:1100/:1205). Empty strings in resources values/strings.xml:120/343. | Local CRUD semantics are correct; original team filters only appear with >1 available filter (:1018), so invented team tabs are unjustified. |
| Dialog labels differ | HOLDS. Original Add word/Edit word, Enter a word, Add/Save/Cancel and Add snippet, Snippet, Expansion (`res/values/strings.xml:110`, `:333`); radius16 (DictionaryScreenKt:252). | Local validation limits were deliberate backend-independent choices. |
| Style hierarchy differs | HOLDS. `ui/styles/StylesScreenKt.java:163` has Personal/Work/Email/Other, app indicator and preview card (:258); original Formal/Casual/Very Casual/Excited names in strings.xml:364. | Original category-specific behavior is not provided by the existing global API setting. Must not pretend per-app matching without an implemented data/integration path. |
| Settings/preferences differ | HOLDS. `ui/settings/SettingsScreenKt.java:116` gives #F5F5F5, white cards, radius16, GENERAL / DATA & PRIVACY and separate size/opacity pages (:228350). | Account/cloud/model-training/paid controls remain excluded; external API/local privacy are intentional differences. |
| Bubble differs | HOLDS. `design/DimenKt.java:74` and `ui/bubble/BubbleSizeKt.java:24` establish 56dp idle, 160dp PTT /230dp POPO active, 6dp gaps, radius16 idle, packaged bar icons and elevation2. | Original has additional feature-conditioned/minimized/copy/error states. Current gestures/non-focusable overlay are valid; static dimensions precede user scale. |
| Onboarding corresponds | PARTIAL. Current checklist lacks original distinct steps. Intro declarations: `ui/onboarding/composable/OnboardingEducateBubbleIntroComposableKt.java:109`, `:143`, `:179`, `:191`. | Full sequence is experiment/state dependent and OnboardingScreen body is incomplete (:252). Preserve standalone access without fabricating original auth success. |

Things independently checked that were fine: Kotlin/Compose, the four primary labels and bottom-navigation architecture, existing Android permission operations, local CRUD/history actions, draggable non-focusable overlay, tap/hold semantics, and the genuine Lumen/Primary300 color tokens. Excluded private backend/auth/payment behavior remains deliberate.

## Fresh morluto/rea evidence

REA 6.8.0 CLI was executed with Bun, JDK17 and pinned headless JADX0.7.1 on the **exact absolute original APK path**. Complete Evidence JSON is retained in `evidence/reference/rea/`. The package call records the verified digest and 2.8.3/182. `dashboard-class.json` inventories exact names and overload indices before method selection. `dashboard-initializer.json` selects `<clinit>` overload0; REA explicitly falls back to Smali for the static initializer. `dashboard-references.json` traces getEntries overload0 into the shell. Further screen inventories and focused methods are indexed in `rea/index.json` when complete.

Evidence IDs so far: package `ev_47ffef74c7e84c3b85f672da61dd35fd8787f26df317653ed0bfa929ee8d3059`; navigation inventory `ev_cd319436aa40e8e6b47a5877050ed63087ee57d9a1e0677b988e2d3905688f92`; initializer `ev_0c54382c8da8f53c111c13db6ac2d42ea0f3311c9aa11fdabde0e3913cca3d98`; references `ev_45c9dad98e6568adca8c3e3c29968306d166f6bed3261bcb98943d45bacf6c43`.

Limitations: static declarations/decompilation are not execution or screenshots; DEX signatures/overload indices are local to this provider/artifact; incoming references do not prove dynamic/reflection completeness; recovered bulk Compose bodies may be incomplete. Full decompilation and Smali were reused for bulk queries rather than repeatedly decompiling huge bodies. APK package/signature/resource evidence never establishes runtime pixels.

## Original runtime installation boundary

Pinned agent-device0.21.31 install help and implementation expose a single local APK/AAB, no split-install operation. The unchanged base-only failure from the earlier task was not repeated. `tools/reference-installer` uses Android's **public PackageInstaller multi-APK session** with `USER_ACTION_REQUIRED`, bundling byte-identical base/arm64/density/en/ja inputs. Input hashes are in `evidence/reference/installer-inputs.json`; normal unknown-source consent and Android installation confirmation were driven through the returned pinned agent-device launcher. Original and clone have separate packages.

Installation succeeded. Launching `com.wispr.flowapp` displays **“Something went wrong”**, then **“Check that Google Play is enabled on your device and that you're using an up-to-date version before opening the app. If the problem persists try reinstalling the app.”** Capture: `evidence/reference/original/launch-boundary.png` (1080×2400). This is a genuine original launch/error frame, **not an original dashboard reference**. `installer-status.png` is Android's install confirmation over the helper, not a Wispr product screen. No licensing/Integrity bypass, root, account, audio capture, paid action or emulator protection change was attempted.

## Required runtime references / limits

No valid original/revised product-screen pair exists, so no product pixel diff/overlay or pixel-perfect verdict is possible. Needed: original dashboard empty/history/education states; drawer; dictionary and snippet empty/search/populated/add/edit/delete states; each Style category and selection sheet; settings/languages/account; size/opacity; every onboarding step; bubble idle/minimized/hold/toggle/recording/processing/error/copy, at the same resolution, density, theme and font scale. Account/auth/paid/cloud-only actions are excluded from functional replication. Conditional variants need explicit original state/experiment information.
