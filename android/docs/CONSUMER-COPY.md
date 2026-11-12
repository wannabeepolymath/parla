# Android consumer copy pass

Scope: Android display text, labels, and the existing layout. Stored values,
settings keys, model identifiers, package names, provider request formats, and
dictation/recovery behavior are unchanged. Human labels are applied at display
time by `DisplayLabels.kt`; API configuration still accepts real provider model
IDs and app profiles still accept package names.

## Main changes

| Screen or surface | Before | After |
| --- | --- | --- |
| Home and history | “Models / local speech setup”; “Transient recovery: RAM only…” | “Open speech models”; a brief explanation of the five-minute lifetime |
| Dictionary | “Hints: 256 UTF-8 bytes each; ASR 2048 bytes…” | “Words at the top have priority”; short-word guidance in the add dialog |
| Style / Output settings | “cleanup”, “raw”, “selectedPreset” | “Clean up speech”, “As spoken”, “Use a saved preset” |
| Style / Output settings | “standard”, “conversational”, “formal”; cramped switch | Capitalized writing styles; AI cleanup switch aligned at the row's end |
| Preset dialog | “Saved explicit transform”; “rewrite”, “translation” | “Save a preset”; “Rewrite”, “Translate” |
| Word replacements | “Exact, case-sensitive, word boundaries, longest match, one pass” | Whole-word/phrase guidance that preserves capitalization, priority, and snippet distinctions |
| Snippets | “Snippet”, “Expansion” | “Voice shortcut”, “Text to insert” |
| Settings | “base.en”, “cleanup”; “parla Bubble Size / Opacity” | Readable model/output labels; “Voice control size / opacity” |
| Models | Raw byte counts, SHA-256 hashes, native writer/checkpoint paragraphs | KB/MB/GB sizes, model/language labels, clear Pause/Resume/Discard explanations |
| Profiles and add dialog | “Exact-app profiles”, “Cleanup: inherit”, raw model IDs | “App profiles”, “AI cleanup: Use default setting”, model names and languages |
| Recovery audio | “freezes current global model… local ASR…” | On-device transcription explained plainly; retention, backup, deletion and history remain explicit |
| Data recovery | “Unreadable settings block writes and provider requests…” | Saving/AI cleanup are paused; load/edit JSON, save repair, keep original copy |
| Privacy | “Local Data Storage”, “No local history”; implementation paragraphs | “Privacy”, “Pause text history”; separate text/audio retention controls |
| API connection | Raw provider IDs, endpoint paths and request deadline | Provider names; audio/text privacy, key authorization, provider charges and retention |
| Account | Two unexplained rows | “No account needed” and the purpose of optional API cleanup |
| Voice control position | “Android reports its window bounds…” | Follow-keyboard and manual-drag behavior |
| Try it here | “Practice” navigation title and editor jargon | “Try it here” throughout; check the field before pasting an unconfirmed result |
| Feedback / issue report | Copy-only form without explanation | Explicitly says nothing is sent; copy and share the note yourself |
| Notification, bubble, insertion and errors | Internal operations and editor/writer/reader language | Short status/action text; uncertainty and recovery guidance preserved |
| Accessibility description | Window-bounds and editor-context implementation details | What the service does, sensitive-field checks, privacy, and uncertain-insertion guidance |

No permission grants, credentials, model downloads, paid requests, app-data
resets, pushes, or merges are part of this pass.

## Validation

From `android/`:

```sh
ANDROID_HOME="/Users/daksh/Library/Android/sdk" \
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
./gradlew --no-daemon --console=plain :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

- Unit tests: **82 passed, 0 failures, 0 errors, 0 skipped**.
- Debug APK: assembled and installed successfully using `adb install -r`, keeping app data.
- Lint: **0 errors, 16 warnings; 0 introduced by this pass**. Findings concern unchanged
  target/dependency versions, accessibility event cases, resource folders, disk-space
  checks, KTX suggestions, and RTL gravity. The compiler also reports the existing
  swipe-to-dismiss callback deprecation. No tooling or dependencies were upgraded.
- One initial test run had 81 passing tests and one stale copy assertion at
  `quotaAndStorageFailuresAreExplicitAndSuccessfulRawSurvivesPurgeFailure`.
  Its expected “Recognition succeeded” prefix became “Transcript ready”; the
  behavior assertions were preserved. The final full run above passed.
- The worktree initially needed `ANDROID_HOME`; the installed SDK was reused.
- Final APK: [parla-consumer-copy-debug.apk](../evidence/consumer-copy/parla-consumer-copy-debug.apk),
  39,209,586 bytes. SHA-256:
  `aff8f2e5d8eff178d7a01c6233a9724508f6a70bd148e35bfe1e7688d477bd2f`.
  It is byte-identical to the final Gradle output.
- [Gradle log](../evidence/consumer-copy/gradle.log),
  [JUnit XML files](../evidence/consumer-copy/test-results),
  [lint XML](../evidence/consumer-copy/lint-results-debug.xml),
  [summary JSON](../evidence/consumer-copy/verification-summary.json).

## Emulator verification

Device tools selected local **parla-test / emulator-5554 / Android 14**.
All UI actions and screenshots used the exact agent-device launcher returned by
`device_open`. The initial device-session conflict was resolved by the owning
parent thread; no other session was reused or closed.

All requested screens were reached, including every Settings row and both ends
of the Profiles add dialog. The 34 screenshots below were visually inspected.
Dialogs were canceled, not saved. No microphone permission was granted; no key
was entered, no model was downloaded, and no provider request was made.

[Crash-buffer log](../evidence/consumer-copy/logcat-crash.txt) is empty (0 bytes).
The [filtered logcat check](../evidence/consumer-copy/logcat-check.txt) contains no
`FATAL EXCEPTION`, `Fatal signal`, or Parla crash. Final navigation returned to
Home. The task's device session is released with `agent-device close`; the emulator
is left running.

## Screenshot index

All paths are under `android/evidence/consumer-copy/screenshots/`.

| Screen | Screenshot |
| --- | --- |
| Home | [01-home.png](../evidence/consumer-copy/screenshots/01-home.png) |
| Dictionary | [02-dictionary.png](../evidence/consumer-copy/screenshots/02-dictionary.png) |
| Add word | [03-dictionary-add.png](../evidence/consumer-copy/screenshots/03-dictionary-add.png) |
| Style, top | [04-style-top.png](../evidence/consumer-copy/screenshots/04-style-top.png) |
| Style, bottom | [05-style-bottom.png](../evidence/consumer-copy/screenshots/05-style-bottom.png) |
| Rewrite preset | [06-preset-dialog.png](../evidence/consumer-copy/screenshots/06-preset-dialog.png) |
| Translate preset | [06b-translate-dialog.png](../evidence/consumer-copy/screenshots/06b-translate-dialog.png) |
| Snippets | [07-snippets.png](../evidence/consumer-copy/screenshots/07-snippets.png) |
| Add snippet | [08-snippet-add.png](../evidence/consumer-copy/screenshots/08-snippet-add.png) |
| Drawer | [09-drawer.png](../evidence/consumer-copy/screenshots/09-drawer.png) |
| Settings, top | [10-settings-top.png](../evidence/consumer-copy/screenshots/10-settings-top.png) |
| Models, top | [11-models-top.png](../evidence/consumer-copy/screenshots/11-models-top.png) |
| Models, bottom | [12-models-bottom.png](../evidence/consumer-copy/screenshots/12-models-bottom.png) |
| Settings → Output settings | [13-output-settings.png](../evidence/consumer-copy/screenshots/13-output-settings.png) |
| Profiles | [14-profiles.png](../evidence/consumer-copy/screenshots/14-profiles.png) |
| Add profile, top | [15-profile-dialog-top.png](../evidence/consumer-copy/screenshots/15-profile-dialog-top.png) |
| Add profile, bottom | [16-profile-dialog-bottom.png](../evidence/consumer-copy/screenshots/16-profile-dialog-bottom.png) |
| Recovery audio | [17-recovery-audio.png](../evidence/consumer-copy/screenshots/17-recovery-audio.png) |
| Data recovery | [18-data-recovery.png](../evidence/consumer-copy/screenshots/18-data-recovery.png) |
| Languages | [19-languages.png](../evidence/consumer-copy/screenshots/19-languages.png) |
| Voice control size | [20-voice-control-size.png](../evidence/consumer-copy/screenshots/20-voice-control-size.png) |
| Voice control opacity | [21-voice-control-opacity.png](../evidence/consumer-copy/screenshots/21-voice-control-opacity.png) |
| Voice control position | [22-voice-control-position.png](../evidence/consumer-copy/screenshots/22-voice-control-position.png) |
| Settings, bottom | [23-settings-bottom.png](../evidence/consumer-copy/screenshots/23-settings-bottom.png) |
| Privacy, top | [24-privacy-top.png](../evidence/consumer-copy/screenshots/24-privacy-top.png) |
| Privacy, bottom | [25-privacy-bottom.png](../evidence/consumer-copy/screenshots/25-privacy-bottom.png) |
| API connection, top | [26-api-top.png](../evidence/consumer-copy/screenshots/26-api-top.png) |
| API connection, bottom | [27-api-bottom.png](../evidence/consumer-copy/screenshots/27-api-bottom.png) |
| Permissions, top | [28-permissions-top.png](../evidence/consumer-copy/screenshots/28-permissions-top.png) |
| Permissions, bottom | [29-permissions-bottom.png](../evidence/consumer-copy/screenshots/29-permissions-bottom.png) |
| Try it here | [30-try-it-here.png](../evidence/consumer-copy/screenshots/30-try-it-here.png) |
| Account | [31-account.png](../evidence/consumer-copy/screenshots/31-account.png) |
| Report an issue | [32-report-an-issue.png](../evidence/consumer-copy/screenshots/32-report-an-issue.png) |
| Share feedback | [33-share-feedback.png](../evidence/consumer-copy/screenshots/33-share-feedback.png) |

A pre-update comparison of the original Output screen is retained separately as
[before-output.png](../evidence/consumer-copy/before-output.png).

## Limitations and unfinished areas left alone

- Models shows “Saved download could not be read” notices, and Recovery audio
  shows “Recovery folder could not be read.” These are observations from the
  screenshots, not a root-cause diagnosis. The underlying transfer/storage logic
  was not changed. App data and files were not repaired or deleted.
- Live dictation, the live bubble/notification, audio playback/retranscription,
  populated history retry/export, and insertion were not exercised. They would
  require permissions, recordings or model data excluded by this task. Those
  messages were reviewed in source; existing unit tests cover their policy.
- Profiles still asks for a package name and a language code; API connection asks
  for a provider model ID; Data recovery still edits JSON. Replacing those advanced
  workflows needs behavior changes beyond this copy pass.
- Existing duplicate navigation/content titles, Settings card grouping, and the
  long scrolling profile form remain. System Back from a support form returns to
  Settings, while its toolbar Back returns Home; navigation behavior was preserved.
- Impeccable context found the root PRODUCT.md lacks an Android platform section.
  This scoped native refinement followed the Android implementation and brief;
  project-wide product/design metadata was not changed.

## Resources and commits

The Gradle wrapper used the installed SDK, JDK, NDK and caches. No server or
temporary database was started. Final APK, logs, XML reports, summary, baseline
comparison and 34 screenshots remain in the repository's ignored
`android/evidence/consumer-copy/` directory. Normal build outputs remain under
`android/app/build/` and `android/app/.cxx/`; no shared caches were deleted.
The emulator remains running; the task's device session is released.

Implementation commits:
- `fe5416c` — Polish Android screen copy and display labels.
- `f973328` — Clarify Android dictation and recovery status messages.

No push or merge was performed.
