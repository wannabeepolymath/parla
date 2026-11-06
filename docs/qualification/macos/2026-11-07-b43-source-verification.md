# B43 0.7.0 source verification — 2026-11-07

Base: `054cd2e`; lane: `lane/b43-meetings`. This is source/test evidence, not release acceptance or native hardware qualification. The proposed policy still requires final user sign-off. The existing single retained meeting slot remains; optional meeting AI cleanup/summary has no action and no provider is called.

## Source files

| Files | Change |
|---|---|
| `Sources/Parla/MeetingHubController.swift` | Single-use consent, explicit permission flow, selected-app composition, retention maintenance and Keep |
| `Sources/Parla/MeetingSessionOwner.swift` | Two independent canonical ingresses, shared writer serialization, actual producer/writer drain, retention execution |
| `Sources/Parla/Hub/HubMeetingView.swift`, `HubMeetingModel.swift` | Application chooser, consent sheet, recording indicator, retention dates/notices derived from the policy constants, and Keep/Delete controls |
| `Sources/Parla/main.swift` | Production capture capability/backend, deliberate app discovery, startup maintenance, persistent menu-bar indicator |
| `Sources/ParlaCore/MeetingSession.swift` | Named policy durations, backward-readable retention metadata and removed-audio tombstones |
| `Sources/ParlaCore/MeetingSessionStore.swift` | Completion timestamps, Keep, durable raw unlink intent/completion, transcript preservation and deletion resumption |
| `Sources/ParlaCore/SavedAudioImportStorage.swift` | Meeting-only descriptor-based backup exclusion |
| `scripts/make-app.sh` | Audio capture usage description and meeting microphone purpose |

## New regression methods

`Tests/ParlaTests/MeetingRecordingPolicyTests.swift` covers single-use consent before permission/capture, source/page revocation, denied and late microphone permission, production dual-source ownership and actual termination drain, app refusal with microphone retirement, earlier raw-deadline rearming, and the production/no-History composition contract. The dual-source test actually transcribes saved synthetic audio and checks an ordinary History-write positive control followed by zero History change notifications and unchanged History bytes/entries for the meeting. All bottom capture/recognition services are injected. The source contract also checks that production capture is enabled and that the meeting composition/controller/recognition execution have no History sink.

`Tests/ParlaCoreTests/MeetingRecordingPolicyTests.swift` covers one nanosecond before and exactly at successful/failed raw-audio and transcript expiry, accepted-text survival and cold reopen after raw deletion, retranscription refusal for removed audio, Keep across restart, explicit Delete overriding Keep, removing Keep, actual hold fencing, transcription after 30 days while kept, backup/private-mode controls, and exact durable-intent resumption after a raw source has already been unlinked. The physical backup control changes only a newly owned empty temporary directory and checks Foundation’s excluded-from-backup resource value; it records no audio.

Existing capture tests now explicitly confirm consent through a test helper. Expiry expectations use the new transcript duration. The entered-copy transcript-expiry test first sweeps the independent earlier raw deadline, preserving its original transcript-expiry oracle.

## Fail-without-fix proof

Before reversal, all **14** new methods passed in `swift test --scratch-path .build-b43 --filter MeetingRecordingPolicy` (exit 0). Each group below temporarily reverted the corresponding source behavior with the test APIs preserved, ran only its selected methods, observed runtime XCTest failures (exit 1, successful compilation), then restored the source. There were **9** groups and **14 distinct failing methods**, with no selected method passing under its reversal. The four affected source files were restored byte-for-byte before proceeding. An additional guard preventing deadline rearm while actual transcription remains owned, and the stronger History notification oracle, are included in the final checks below.

| Reversal | Runtime methods failed |
|---|---:|
| Restore the former direct microphone-start behavior before acknowledgment | 1/1 |
| Remove the pending-consent revocation and page/owner/source rechecks | 1/1 |
| Bypass the microphone permission refusal/grant gate | 1/1 |
| Remove production microphone composition from selected-app sessions | 2/2 |
| Remove Stop’s owned deadline cancellation/join and rearm | 1/1 |
| Remove the raw-audio retention sweep | 3/3 |
| Remove persisted Keep assignment | 2/2 |
| Remove acquisition-time and native backup exclusion | 2/2 |
| Restore production captureCapability:false | 1/1 |
| Remove recognition of the exact already-unlinked raw-retention source during whole-meeting deletion | 1/1 (later reversal) |

Raw reversal logs and restoration hashes are in `/tmp/b43-mutation-proof/`; `results.json` lists the exact method names and filters. This proves test sensitivity to those source changes; it does not qualify native services.

A fifteenth regression was added during the recovery review. Before its correction, `testDeleteResumesAnAlreadyUnlinkedRawRetentionIntentOnlyForItsExactSource` compiled and failed with `nondurableIntent` (exit 1, one executed method). The whole-meeting deletion audit now honors the one exact source already covered by a durable raw-retention intent, even beyond the current two-target delete slice. Its foreign-missing-source control must still refuse bootstrap. The pre-fix output is `/tmp/b43-raw-intent-red.log`. The correction was subsequently temporarily reverted as well: the same method compiled and failed (exit 1), then the exact source bytes were restored. The restored 15-method policy run and `swift build` both passed. This makes **10 source-reversal groups / 15 distinct new methods**, all failing without their corresponding change. See `/tmp/b43-raw-reversal-result.json` and `/tmp/b43-raw-intent-reversal.log`.

## Final commands

The full `swift test --scratch-path .build-b43 --filter Meeting` invocation executed **243 methods**. The 240-chunk/240-result capacity method passed (753.424 seconds). One legacy owner method failed three assertions: the streaming drain predicate had included legacy capture producers. The source guard now requires a streaming ingress before taking that branch, preserving legacy quit revocation. The corrective Meeting invocation reruns the other 242 methods, including the failing method, without repeating that unchanged Core-only capacity test. These are staged snapshots, not a claim that one fresh 243-method invocation passed. Focused policy totals are not a full-package claim.

Two legacy bulk-setup helpers then hit their existing four-second observation limit. A separate recheck reproduced the aggregate wait timeout, while the 17-part case passed. Their seed and individual transcription actions now each use the same original four-second helper; all byte/cap/provenance/lifecycle assertions remain unchanged. The final clean Meeting selection passed all 242 methods, including both bulk cases and the quit regression. No timeout value or product deadline was increased.

| Command / scope | Result |
|---|---|
| `swift test --scratch-path .build-b43 --filter Meeting` (initial full run) | 243 executed; one method failed three assertions, subsequently corrected; capacity passed |
| Same Meeting filter, `--skip testFullVirtual240By240AndBothExtraPeaksWithoutPayloadAllocation` (final clean run) | **242 passed, 0 failures**, exit 0 |
| Unchanged Core capacity method from the full run | **1 passed**, 753.424 seconds; no repeat or fresh-all-243 claim |
| `swift test --scratch-path .build-b43 --filter 'SavedAudioImportStorageTests\|SavedAudioImportStoreTests\|HubHistoryExportTests'` | **68 passed, 0 failures**, exit 0 |
| `swift test --scratch-path .build-b43 --filter MeetingRecordingPolicy` after final reversal restoration | **15 passed, 0 failures**, exit 0 |
| `swift build --scratch-path .build-b43` after restoration | exit 0 |
| Fresh `swift build` after deriving UI retention wording from the policy constants | exit 0; `/tmp/b43-ui-build.log` |
| `bash -n scripts/make-app.sh` | exit 0 |
| `git diff --check` | clean |

Logs: `/tmp/b43-clean-meeting.log`, `/tmp/b43-clean-related.log`, `/tmp/b43-final-policy-restored.log`, `/tmp/b43-final-build-restored.log`; command receipts: `/tmp/b43-clean-results.json`. Counts overlap across selections and must not be summed as additional distinct tests. All 243 selected Meeting methods have passing evidence across the stated snapshots.

## Corrections and excluded claims

Initial compiles exposed a Swift type-checker expression, an overlapping inout access, an optional Picker binding and a throwing guard expression; all were corrected. An initial broad run was stopped after a shared parser failure: the closed-object field bound needed to admit the new retention field. The next focused run exposed per-ingress slot numbering being confused with the shared allocation total; each ingress now advances its own slots while the owner still charges the shared cap. A refusal test originally required the microphone engine to start before app refusal; that was corrected to require the microphone factory, released capture admission and a stopped engine, because safe refusal may fence before native microphone startup.

A later broad run was interrupted after confirming two stale legacy consent/message expectations, to avoid completing the expensive capacity selection twice before the corrected candidate. Those expectations were adapted; no production requirement or assertion about native qualification was relaxed.

No real microphone or app-audio capture, model initialization, live provider, app/browser/device launch, package/signing or deployment was run. No independent source-review round was requested/run by this implementation sub-agent. Native permission prompt/denial UI, process/helper/output-route coverage, callback/converter behavior, timing alignment/drift, echo, long-session gaps, installed ASR, physical crash/recovery and storage-policy acceptance remain open. Source tests do not complete B43.

## Task resources

The task used `.build-b43`, `/tmp/b43-*.log`, `/tmp/b43-proof.py`, the three `/tmp/b43-*.py` editing scripts, `/tmp/b43-mutation-proof`, and the environment/owned fixture root recorded in `/tmp/b43-test-env.json`. The fixture environment was new and private; no historical fixture, user app namespace, dependency tree or other checkout was used. Both private verification roots and all remaining receipt-owned fixture/build paths were cleaned after test-process exit, identity/ownership checks and an empty open-file inventory. The final cleanup receipt records 270 removed paths, 68 already absent paths and no preserved leftovers. One exact test-created `everyone deny delete` ACL was removed from its verified fixture parent so that cleanup could finish. The earlier interrupted root was cleaned separately. Journals were copied to `/tmp/b43-mutation-proof` before removal. No task test process, database, server, browser or device remains. The final UI-only wording change also passed a fresh isolated build, whose owned scratch root was removed (`/tmp/b43-ui-cleanup.json`). Diagnostic scripts/logs/JSON receipts under `/tmp/b43-*` and `/tmp/b43-mutation-proof` remain for review. Cleanup receipts: `/tmp/b43-final-cleanup.json`, `/tmp/b43-interrupted-cleanup.json`.
