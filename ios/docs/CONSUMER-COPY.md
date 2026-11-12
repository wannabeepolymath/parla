# iOS consumer copy pass

Scope: iOS labels, explanations, permission copy and recovery messages. Screens
keep their existing structure. Settings keys, stored identifiers, export format,
provider requests, dictation and retention behavior are unchanged. No file under
`Sources/ParlaCore` was edited.

## Main changes

| Screen or surface | Before | After |
| --- | --- | --- |
| Keyboard setup | “shared dictation handoff” | Full Access lets the keyboard share dictation requests and results with Parla; it cannot record or send what you type |
| Onboarding privacy | “host text”; implementation wording for retention | “surrounding text”; explicit two-minute result lifetime and deletion on next use |
| Practice | Arrow-separated app-switch sequence and sample-transcript disclaimer | Short steps for starting in Parla, returning, stopping, reviewing and inserting |
| Models | “Small (English, quantized)”; “pinned size and SHA-256” | “Small (English)”; “checked before installation” |
| Models | Apple Speech locale codes and “Release” | Language names and “Remove language” |
| Models | Detailed verification errors with IDs, bytes or hashes | Model name, installation failure and storage/download recovery guidance |
| Dictionary | Recognition and cleanup byte budgets | Short-word guidance, top-of-list priority, swipe actions and the Apple Speech exception |
| Snippets / Replacements | “trigger”, “hint”, “word edges”, “rows break ties” | Shortcut phrases, whole-word matching, capitalization and priority explained plainly |
| Cleanup | “Raw transcript”, “Local rules only”, raw model ID in summary | “As spoken”, “Basic cleanup”, provider name in summary |
| Cleanup | “Spoken language (e.g. en)” | Named language choices, with the original language codes as picker values |
| Cleanup connection | Unlabelled model ID; “Base URL” | Persistent “Model ID” and “Service address” labels with examples |
| Cleanup privacy | “Keychain”, “App Group”, “HTTPS”; no explicit billing sentence | Secure storage, what providers receive, provider charges and data policies, audio staying on device |
| Presets | “The instruction is yours; dictated text never supplies instructions” | Describe the rewrite or translation; speech is text to edit |
| Settings | “16 kHz”, “audio route changes”, “temporary delivery result” | Saved recordings for Retry, microphone changes, latest result available for two minutes |
| History | “Raw”; retained-history accounting language | “As spoken”; totals include saved dictations only |
| Export | “Export … as JSON” | “Export notes, history & settings”; contents, exclusions and sharing caution |
| Compact request banner | Long instructions clipped with the keyboard open | “Start here, then return to your app. Up to 5 minutes.”; interruption guidance remains in Settings |
| Keyboard status | “No automatic app switch or return is promised”; “field identity changed” | “Open Parla, tap Start microphone, then return to this app”; different-field recovery |
| Storage errors | App Group, signing and shared-session terminology | Connection, saved-data and app-update recovery guidance |
| Shortcuts / widgets | “foreground”, “app process”, “recording session” | “while Parla is open”, “Open a note … first”, “recording” |
| Microphone permission | “Speech is recognized …” | When the microphone is used and that audio stays on this iPhone |

`ConsumerCopy` applies iOS model, provider, language and shared-message labels at
display time. The Apple Intelligence language picker retains each original code,
including an existing custom value, without migrating settings. Editable provider
model IDs remain visible because the service requires their exact values.

The project generator carries the same microphone string as the checked-in
Info.plist so regeneration preserves it. Shared desktop strings are translated
only in iOS views; desktop source remains untouched.

## Verification

Evidence is local and git-ignored under
`ios/evidence/consumer-copy-2026-11-13/`. The exact Simulator commands follow
`README.md` and `VERIFICATION.md`, with that directory as the DerivedData and
result-bundle destination. Signing uses `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`.

- `python3 ios/Scripts/typecheck.py`: PASS, all seven stages including 26
  whisper/ggml native compilation units. All Swift checks and native syntax checks passed.
- `python3 ios/Scripts/validate_project.py`: PASS, 746 structural/resource checks.
- Ad-hoc Debug Simulator build: PASS, app, keyboard, widgets and ParlaCore,
  including arm64 and x86_64. Existing vendor integer-conversion, empty-object,
  SDK metadata, UIDeviceFamily and signed-binary strip warnings remain.
- Impeccable mechanical detector: no findings. The copy and native layout are
  checked separately in the Simulator walkthrough.

- Hosted Simulator tests: **33 passed, 0 failures**, across seven suites
  (`tests-final.log`, `tests-final.xcresult`). The final retained code matches
  that tested source; the preview-only experiment was reverted. No test
  assertions were changed.
- Final build after that revert: PASS (`build-release-copy.log`). Both Python
  verification scripts were rerun successfully.
- Final crash check: **0 new Parla crash reports, 0 crash signatures** in the
  task log. All observed app and keyboard launches/navigation remained usable.
- **43 screenshots plus one baseline** are indexed in
  [SCREENSHOTS.md](../evidence/consumer-copy-2026-11-13/SCREENSHOTS.md).

## Simulator walkthrough

Local iPhone 17, iOS 26.5, device
`50C01478-E2B8-4C5F-A9E8-05862F140B2B`. The device was selected through T3
`device_list` / `device_open`. Every launch, tap, gesture, settings visit and
screenshot used the exact bound `agent-device` command returned by `device_open`.
`simctl` was used only for installation and streaming logs; `xcodebuild test`
also installed and ran the app.

Revisited all four onboarding pages, Home/history, menu, Scratchpad and its
editor, Dictionary, Snippets and its editor, Models, Settings, Language, all
three cleanup provider forms, named Apple Intelligence language choices, rewrite
and translation preset forms, Replacements and its editor, audio settings,
history/privacy/help, retention confirmation, feedback sharing, local data,
delete confirmation and export sharing. Confirmations were dismissed, and no
share destination was selected. Retention remains Keep, cleanup remains off,
and the provider was restored to Anthropic. The existing note remains intact.

The keyboard was checked in typing and voice modes, then requested and cancelled
a dictation without starting the microphone. Hiding and reopening it also worked.
The iPhone keyboard list and Parla's existing Full Access setting were inspected;
Full Access was already enabled and was not changed. Microphone permission
remained **Not allowed**. No speech permission was granted, API key entered,
provider call made, or model/language download started.

The first compact request-banner capture showed clipped instructions while the
keyboard was open. Shortening the sentence fixed it; the final capture shows the
whole sentence and five-minute limit. Audio interruption guidance remains in
Settings. No layout change was needed.

Device automation sometimes supplied stale or keyboard-relative accessibility
coordinates, missed list-cell taps, or could not scroll the nested onboarding
container. Fresh snapshots and visible screenshot coordinates were used per the
tool's guidance. The feedback share sheet did not dismiss through the attempted
taps/drags; relaunching Parla returned to Home without selecting a destination.
These observations do not establish an app defect. No navigation or gesture
behavior was changed as part of this copy pass.

## Boundaries preserved

- Provider addresses and model IDs remain editable because users must enter exact
  values from their provider. They now have persistent plain labels and examples.
- Exports remain the same JSON payload, including original settings keys and
  stored values. Translating those keys inside the payload would change its data
  format. Only the action label and explanation changed. The system share preview
  is unchanged to preserve the existing Copy and sharing actions. A custom preview
  title was not retained because it removed Copy in the Simulator. Keys and audio
  remain excluded; export sharing is still an explicit user action.
- Model catalog IDs, file sizes, hashes, download verification, request formats,
  byte limits, retention policies, credential operations and all storage schemas
  are unchanged. Shared desktop source and test assertions are unchanged.
- Real recording/transcription, populated transcript detail/retry/playback,
  successful keyboard result insertion, Apple Speech preparation, Apple
  Intelligence inference, credential operations and paid provider requests were
  not exercised because they require permissions, audio, downloads or credentials
  excluded by the brief. Their copy was reviewed in source. Apple Speech's model
  section is unavailable on this Simulator. Widget/shortcut descriptions compile;
  recording widgets, Live Activities and shortcut execution were not activated.
- The root PRODUCT.md has no platform section and describes desktop behavior.
  This pass followed the iOS implementation and brief; product/design metadata
  was not changed. The copy review was performed within this implementation
  sub-agent, without spawning further agents.

## Retained task resources

The ignored evidence directory contains screenshots, build/typecheck/validation
logs, test result bundles, crash checks and task-owned DerivedData. Typecheck's
normal outputs remain in `ios/evidence/implementation/`; no dependencies were
installed and no shared caches were copied or deleted. No server or temporary
database was created. The app/extensions, existing note, keyboard and local
settings remain installed on the Simulator. No data reset was performed.

The task's log stream is stopped after verification. The device is removed from
this thread's panel using `device_close(shutdown: false)` and left running.
T3-managed session files remain under
`/Users/daksh/.t3/userdata/device/agent-device/sessions/t3-74cca89878da33236d046090`;
its remote diagnostics are under `/Users/daksh/.agent-device/remote-diagnostics/`.
No other session was closed or cleaned up. No push or merge was performed.
