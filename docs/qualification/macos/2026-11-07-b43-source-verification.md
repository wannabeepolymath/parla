# B43 0.7.0 source verification — 2026-11-07

Base: `054cd2e`; lane: `lane/b43-meetings`. This is source/test evidence, not release acceptance or native hardware qualification. The proposed policy still requires final user sign-off. The existing single retained meeting slot remains; optional meeting AI cleanup/summary has no action and no provider is called.


## B43 v4 clean refusal and production-call-site coverage — 2026-11-07

Base: `68ee2d3cc1c8aa3fa4d3793125cff419ba68f2dc`; branch: `lane/b43-meetings-v4`. This section supersedes v3 for clean cold-refusal termination and aggregate/IO-proc regression coverage. B43 remains **needs qualification**; final user policy sign-off and native qualification remain open.

- `MeetingSessionOwner.shutdownReady` permits an existing concern only when the owner has no session and the store exposes clean cold-failure recovery: no ledger, all holds drained, zero descriptors, no poisoned lease or protection quarantine. All owner work must still have actually exited. The concern and damaged namespace remain available for explicit confirmed recovery. Failed live capture and uncertain closes retain their lifecycle vetoes.
- `B43MeetingCleanRefusalTests.testCleanCorruptManifestCanQuitWithoutDeletingData` imports `/tmp/parla-b43r3-review-probe.swift` (review failure: `/tmp/parla-b43r3-review-independent-red.log`). It records/saves through the injected Hub, corrupts the manifest, runs startup maintenance without opening Meetings, and requires Quit approval with zero descriptors/capture/recognition, drained holds and no quarantine. Names and write count remain unchanged; a later explicit confirmed recovery still succeeds. Against unchanged production source it compiled and failed at the Quit reply assertion: **1 method, 1 runtime failure**, exit 1 (`/tmp/b43v4-clean-baseline.log`).
- `ApplicationAudioCreationAPI` injects raw `(OSStatus, AudioObjectID)` and `(OSStatus, AudioDeviceIOProcID?)` results beneath `NativeApplicationAudioBottom.createAggregate` and `installIOProc`. Production defaults invoke the same HAL calls. `B43MeetingReleaseBlockerTests` now executes those exact production methods with error + zero/nil results; its injected bottom no longer classifies those refusals itself. The full producer → Stop/writer drain → termination reply assertions remain. Tap and possible-handle classifier controls remain covered. No native HAL call or permission API runs in the injected regressions.

### V4 fail-without-fix proof

The first fixed focused selection passed **8 methods, zero failures** (`/tmp/b43v4-fixed-first.log`): the new clean-refusal regression, all four release-blocker methods, and the existing cold-close/unknown-owned-cleanup lifecycle veto controls. Each reversal below then compiled and failed its single selected method at runtime, with zero selected methods passing. The aggregate/IO reversals change only their production call sites; the shared classifiers and test injection remain unchanged.

| Temporary reversal | Runtime result |
|---|---|
| Restore unconditional concern veto in `MeetingSessionOwner.shutdownReady` | `B43MeetingCleanRefusalTests.testCleanCorruptManifestCanQuitWithoutDeletingData`: 1/1 failed, Quit replies false |
| Restore aggregate error/zero-ID uncertainty at `NativeApplicationAudioBottom.createAggregate` | `testZeroHandleAggregateRefusalCompletesStopAndTermination`: 1/1 failed, actual producer/Stop chain cannot retire |
| Restore nil IO receipt and unconditional error uncertainty at `NativeApplicationAudioBottom.installIOProc` | `testNilHandleIOProcRefusalCompletesStopAndTermination`: 1/1 failed, actual producer/Stop chain cannot retire |

The restored-source B43/Core regression selection passed **14 methods, zero failures**, including all 111 recovery checkpoints (`/tmp/b43v4-final-regressions.log`). This is **one new method and two strengthened methods**, each independently failing without its production correction. `/tmp/b43v4-proof.py` restored exact fixed-source bytes after every reversal; `/tmp/b43v4-proof/restoration.jsonl` records SHA-256 equality, verified again before final checks. Reversal results: `/tmp/b43v4-proof/results.jsonl`; compiled runtime logs and fixed/mutated snapshots: `/tmp/b43v4-proof/{clean,aggregate,io}*`. No independent review agent was launched by this implementation sub-agent.

### V4 final command results and resources

After exact source restoration, the full Meeting invocation passed **252 methods, zero failures** (273.186 seconds of test execution). Its 240-source/240-result capacity method passed in 205.445 seconds. The related selection passed **68 methods** and the B43/Core selection passed **14 methods**. These selections overlap; their counts must not be added as distinct coverage.

| Command | Result |
|---|---|
| `swift test --scratch-path .build-b43v4 --filter Meeting` | **252 passed, 0 failures**, exit 0; includes capacity, owned-real-file admission/reopen and shutdown veto controls |
| `swift test --scratch-path .build-b43v4 --filter 'SavedAudioImportStorageTests\|SavedAudioImportStoreTests\|HubHistoryExportTests'` | **68 passed, 0 failures**, exit 0 |
| `swift test --scratch-path .build-b43v4 --filter 'B43Review\|B43Meeting\|testNoHandleCreationFailuresRetireBothCaptureModes'` | **14 passed, 0 failures**, exit 0 |
| `swift build --scratch-path .build-b43v4` | exit 0 |
| `bash -n scripts/make-app.sh` | exit 0 |
| `git diff --check`; final staged `git diff --cached --check` | clean, exit 0 |

Final command logs: `/tmp/b43v4-final-{regressions,meeting,related,build,shell,diff}.log`; all command receipts, including the expected failing baseline/reversals: `/tmp/b43v4-results.jsonl`. Final documentation/staged checks are retained at `/tmp/b43v4-final-{doc-diff,staged-diff}.log`. Existing unrelated compiler warnings remain; no new source/test compiler error occurred.

`/tmp/b43v4-run.py` applied only the four fixture variables from the V2 fixture environment to a fresh canonical 0700 root, `/private/tmp/parla-b43v4-93q878d7`, with precreated 0600 journals and a 0700 `fixtures/` directory. Exact values: `/tmp/b43v4-env.json`. No historical fixture root, dependency installation, model/provider download, real capture, native permission request, browser/device, packaging/signing, push or tag was used. All code changes are confined to this worktree.

After every test/build process exited, cleanup verified recorded root/member device/inode/owner identities, descendant ownership and an empty matching open-file inventory. It removed **290** task-owned paths, found **17** already absent and preserved **0** leftovers, including removal of `.build-b43v4` and the fresh fixture root. It removed one exact test-authored `everyone deny delete` ACL from its verified fixture parent. Journals were archived first to `/tmp/b43v4-proof/fixtures/`. Ownership receipts: `/tmp/b43v4-owned-resources.json`; cleanup inventory/result: `/tmp/b43v4-cleanup-plan.json`, `/tmp/b43v4-cleanup.json`; matching open files: `/tmp/b43v4-open-files.json` (empty). Only diagnostic scripts, logs, receipts and proof snapshots under `/tmp/b43v4-*` and `/tmp/b43v4-proof/` remain. No task database, process, server, browser or device remains; no user namespace, shared cache or other checkout was cleaned.

## B43 v3 remaining release-blocker corrections — 2026-11-07

Base: `dd275b4b78d48b0bd1cee5c5bfc68f6781494628`; branch: `lane/b43-meetings-v3`. This section supersedes v2 only for the two independently reproduced remaining defects. B43 remains **needs qualification**; policy sign-off and native hardware/crash qualification remain open.

| Finding | Fix and files | Regression evidence |
|---|---|---|
| P1 aggregate error + ID 0 / IO-proc error + nil permanently holds Stop/Quit | `MeetingApplicationAudioCapture.swift`: tap, aggregate and IO-proc results share a classifier. No returned handle creates no new receipt or uncertainty; known listeners/aggregate/tap retire in dependency order. Error + possible handle preserves uncertainty. The standard fake in `MeetingApplicationAudioCaptureTests.swift` now injects zero/nil results separately from its existing partial-handle failures. | `B43MeetingReleaseBlockerTests.testZeroHandleAggregateRefusalCompletesStopAndTermination` adapts the independent native probe to the production classifier; `testNilHandleIOProcRefusalCompletesStopAndTermination` covers nil IO. Both assert known-resource destruction, actual producer/writer exit, visible app-audio refusal, released admission and termination reply. The existing tap regression now uses the same configurable fake. `MeetingApplicationAudioCaptureTests.testNoHandleCreationFailuresRetireBothCaptureModes` covers all three creation steps in retained and access modes. Nonzero/nonnil error controls preserve uncertainty. |
| P2 confirmed recovery interrupted after owner/lock removal strands the slot | `MeetingSessionStore.swift` recognizes exactly a lock-only private namespace at bootstrap or confirmed recovery; `SavedAudioImportStorage.swift` adds opt-in retirement of an empty root after lock unlink. Existing no-follow descriptor/path binding, UID/mode, volume, alias/ACL, registry and lock checks precede deletion. Admission still requires a freshly created root. Ownerless payload and unsafe/unknown contents remain refused. | `B43MeetingRecoveryTests` imports/adapts the reviewer owner-removal probe, tests same-store confirmed retry and cold bootstrap, cuts all **111** checkpoints of a full payload/metadata/lock/root recovery, and proves new admission afterward. A fresh virtual process preserves filesystem identities/bytes while retiring descriptors/flocks and process-local registry state; it never resets a poisoned live lease. The trace includes **11 lock-only** and **5 empty-root** cuts. Positive lock/empty controls and unknown/ownerless payload, symlink, UID, mode, links, nonempty lock and lock-contention controls verify refusal without payload deletion. |

Reviewer inputs: `/tmp/parla-b43r2-independent.log`, `/tmp/parla-b43r2-independent-probe.swift`, `/tmp/parla-b43r2-independent-native-probe.swift`. The original native probe duplicated the native bottom and replaced aggregate creation; the regression instead calls the exact classifier now shared by HAL and injected bottoms, avoiding a stale native implementation copy. No HAL operation or permission API runs in these tests.

### V3 native create/start audit

- `AudioHardwareCreateProcessTap`: shared `recordTapCreation`; zero ID refuses with no new ownership, possible ID on error remains uncertain.
- `AudioHardwareCreateAggregateDevice`: shared `recordAggregateCreation`; zero ID now permits destruction of the known tap, possible ID on error remains uncertain.
- `AudioDeviceCreateIOProcIDWithBlock`: shared `recordIOProcCreation`; nil now creates no IO receipt, allowing listener/aggregate/tap cleanup; possible proc on error remains uncertain.
- `AudioDeviceStart`: requires the known aggregate/proc and marks `startAttempted` before calling HAL. Either return path runs `AudioDeviceStop`; stop failure preserves the dependency/uncertainty hold. Existing injected start-failure tests cover retirement.
- `AudioObjectAddPropertyListenerBlock`: receipt precedes registration; an error may still have installed the block, so registration uncertainty remains deliberate.
- `NSWorkspace` termination observer: a nonoptional observer receipt is retained immediately and removed during retirement. No status/no-handle creation pair exists.
- `CATapDescription`, `AVAudioFormat` and `AVAudioPCMBuffer` create local objects only. Optional format/buffer refusal adds no native ownership or permanent uncertainty; scratch/converter retirement uses the existing actual-body drain. No other native create/start calls exist in this file.

### V3 checks and fail-without-fix proof

All eight selected methods passed initially after fixing a test callback arity and an XCTest autoclosure catch in the first compile. Initial compile diagnostics are retained at `/tmp/b43v3-first.log`; the first green run is `/tmp/b43v3-fixed-first.log`. Six methods are new; the existing tap and invalid-manifest Hub regressions also ran. Every reversal compiled and failed at runtime, with zero selected methods passing. Source API seams were retained for the native classifiers so failure came from behavior, not compilation. Recovery restored both affected production files to the exact base revision. All original fixed-source SHA-256 values were restored before the final checks.

| Temporary reversal | Selected methods failing at runtime |
|---|---:|
| Aggregate error + no ID sets uncertainty again | 2/2 (Hub Stop/Quit and both-mode Core regression) |
| IO-proc error + nil creates a receipt/sets uncertainty again | 2/2 (Hub Stop/Quit and both-mode Core regression) |
| Tap error + no ID sets uncertainty again (existing tap guard) | 1/1 |
| Restore pre-v3 store and lease acquisition/recovery | 3/3 (all new recovery methods) |

This is **six distinct new methods**, all failing without their fix, plus the existing tap guard. The Core method fails under each independent aggregate and IO reversal; it is not counted twice as distinct coverage. Receipts: `/tmp/b43v3-proof/results.jsonl`, `/tmp/b43v3-proof/restoration.jsonl`; individual runtime logs and fixed-source snapshots: `/tmp/b43v3-proof/{aggregate,io,tap,recovery}*`. No independent review agent was launched by this implementation sub-agent. Final command results and task-resource cleanup follow below.

### V3 final command results and resources

After all reversals were restored, one fresh full Meeting invocation passed **251 methods, zero failures** (472.372 seconds of test execution). The 240-source/240-result capacity method passed in 373.915 seconds. The related selection passed **68 methods** and the final B43/Core regression selection passed **13 methods**. These selections overlap; their counts must not be summed as distinct coverage.

| Command / scope | Result |
|---|---|
| `swift test --scratch-path .build-b43v3 --filter Meeting` | **251 passed, 0 failures**, exit 0; includes capacity and owned-real-file admission/reopen |
| `swift test --scratch-path .build-b43v3 --filter 'SavedAudioImportStorageTests\|SavedAudioImportStoreTests\|HubHistoryExportTests'` | **68 passed, 0 failures**, exit 0 |
| `swift test --scratch-path .build-b43v3 --filter 'B43Review\|B43Meeting\|testNoHandleCreationFailuresRetireBothCaptureModes'` | **13 passed, 0 failures**, exit 0 |
| `swift build --scratch-path .build-b43v3` | exit 0 |
| `bash -n scripts/make-app.sh` | exit 0 |
| `git diff --check`; final staged `git diff --cached --check` | clean, exit 0 |

Logs: `/tmp/b43v3-final-{meeting,related,regressions,build,shell,diff}.log`; all command receipts, including the first compile and expected failing reversals: `/tmp/b43v3-results.jsonl`. Final documentation/staged diff checks are recorded separately at `/tmp/b43v3-final-{doc-diff,staged-diff}.log`. Existing unrelated Swift compiler warnings remain; the new test compile correction is recorded above.

The runner created a new canonical 0700 fixture root, 0600 journals and 0700 `fixtures/` directory, using the same four fixture variables documented in the v2 fixture environment. The exact fresh values are recorded in `/tmp/b43v3-env.json`; `/tmp/b43v3-run.py` applied only those fixture variables. No historical fixture root, dependency install, model/provider download, real capture, native permission request, browser/device, packaging/signing, push or tag was used.

After every test/build process exited, cleanup verified recorded root/member identities, descendant ownership and an empty matching open-file inventory. It removed **290** task-owned paths, found **17** already absent and preserved **0** leftovers, including removal of `.build-b43v3` and the new fixture root. It removed one exact test-authored `everyone deny delete` ACL from its verified fixture parent before deletion. Journals were archived first to `/tmp/b43v3-proof/fixtures/`. Ownership receipts: `/tmp/b43v3-owned-resources.json`; cleanup plan/result: `/tmp/b43v3-cleanup-plan.json`, `/tmp/b43v3-cleanup.json`; matching open files: `/tmp/b43v3-open-files.json` (empty). Diagnostic scripts, logs, receipts and fixed-source proof snapshots remain under `/tmp/b43v3-*` and `/tmp/b43v3-proof/`. No task database, test process, server, browser or device remains. No user namespace, shared cache or other checkout was cleaned.

## B43 v2 release-blocker corrections — 2026-11-07

Base: `53b447ad7070b6e039b20cb9d3f64f192ac3ccb4`; branch: `lane/b43-meetings-v2`. This section supersedes the earlier source candidate for the four reproduced release blockers only. Native qualification and policy sign-off remain open; B43 is not complete.

The reviewer fixtures from `/tmp/parla-b43r-extra-tests` were imported as `B43ReviewRetentionTests` and `B43ReviewExpiryFlowTests`. Before fixes, all four imported methods compiled and failed locally: **4 methods / 7 assertion failures**, exit 1 (`/tmp/b43v2-baseline.log`). The publication regression now follows the raw pass with whole-meeting deletion at transcript expiry, rather than expecting raw-only deletion of an expired meeting.

| Finding | Correction and source | Regression methods |
|---|---|---|
| Zero-handle tap refusal holds Stop/Quit | `MeetingApplicationAudioCapture.swift`: production and fake taps share `recordTapCreation`; error + zero ID owns no resource. Nonzero error handles remain uncertain. `HubMeetingModel.swift` explains the app-audio refusal. | `B43MeetingReleaseBlockerTests.testZeroHandleTapRefusalCompletesStopAndTermination`: fake tap → actual producer exit → Stop/writer drain → termination participant reply; nonzero-handle control stays uncertain. |
| Retention misses renamed written source | `MeetingSession.swift` shares the accepted aliases with `MeetingSessionStore.swift`; raw unlink uses the alias actually present before recording removal. Whole-meeting Delete uses the same aliases. | `B43ReviewRetentionTests.testRawSweepHandlesRenameBeforeLedgerPublication`: literal crash snapshot, virtual filesystem unlink, audio tombstone and clean cold reopen. |
| Pending raw intent prevents transcript expiry | `MeetingSessionStore.swift` checks whole-meeting expiry before resuming a raw intent; `MeetingSessionOwner.swift` prioritizes whole-meeting deletion over the raw pass. The existing single retained slot remains; no multi-meeting collection/sweep was introduced. | `B43ReviewRetentionTests.testRawIntentCanRetireAfterTranscriptExpiry`; `B43ReviewExpiryFlowTests.testStartupDeletesExpiredTranscriptWithInterruptedRawIntent` checks the actual controller maintenance path and removal of expired text. |
| Unpublished metadata permanently blocks maintenance/Delete | `MeetingSessionStore.swift` audits committed authority before discarding exactly `manifest.next`. `SavedAudioImportStorage.swift` classifies descriptor-bound private regular files without reading payload. Store/owner/controller/model/view expose confirmed recovery deletion after clean cold failure. Recovery preflights the entire namespace before unlinking, one bounded file step at a time, with metadata last and lock held. | `B43ReviewRetentionTests.testCrashPublicationDoesNotPermanentlyPreventRetention`; `testInvalidCommittedManifestAllowsOnlyExplicitBoundedOwnedDeletion`; `B43MeetingReleaseBlockerTests.testInvalidManifestOffersExplicitDeleteAllMeetingDataRecovery`. Controls reject unknown entries, symlinks, unauthorized deletion and stale confirmation; invalid committed metadata never permits automatic unlink. |

### V2 fail-without-fix proof

All seven new methods passed before reversal (`/tmp/b43v2-fixed-first.log`). Each behavior was then temporarily restored to its failing form, retaining test API seams so the selected tests compiled. Every selected method must fail at runtime; source bytes are restored after each group. Proof receipts and logs: `/tmp/b43v2-proof/results.json`, `/tmp/b43v2-proof/restoration.json`, `/tmp/b43v2-proof/*.log`.

| Temporary reversal | Required runtime failures |
|---|---:|
| Classify zero-handle tap error as uncertain again | 1/1 |
| Unlink only the ledger's pending source name | 1/1 |
| Resume raw intents before checking expiry; restore owner raw-first ordering | 2/2 |
| Refuse `manifest.next` at bootstrap again | 1/1 |
| Disable explicit unavailable-manifest deletion (API retained, throws) | 2/2 |

The first full v2 Meeting invocation ran all 245 methods: 244 passed, including the capacity method (315.378 seconds); the owned-real-file admission method failed with `io` because the runner had supplied a fixture root through macOS's `/var` symlink. `MeetingDarwinBottom.open` deliberately uses `O_NOFOLLOW`. Canonicalizing the environment paths to `/private/var/...` made that exact method pass (0.152 seconds), with no source change. The failed run and focused recheck are retained at `/tmp/b43v2-meeting-symlink-fixture.log` and `/tmp/b43v2-real-path-recheck.log`; the first command receipts are `/tmp/b43v2-initial-check-results.json`. A fresh full Meeting run uses the corrected environment. Final results and cleanup follow below.


### V2 final command results and resources

After restoring every reversal and canonicalizing the fixture paths, one fresh full Meeting invocation passed all **245 methods** with zero failures (379.187 seconds). Its capacity method passed in 269.662 seconds. The related selection passed **68 methods**, and the explicit seven-method regression selection passed again. Counts overlap and must not be summed as distinct coverage.

| Command / scope | Result |
|---|---|
| `swift test --scratch-path .build-b43v2 --filter Meeting` | **245 passed, 0 failures**, exit 0; includes capacity and owned real-file positive |
| `swift test --scratch-path .build-b43v2 --filter 'SavedAudioImportStorageTests\|SavedAudioImportStoreTests\|HubHistoryExportTests'` | **68 passed, 0 failures**, exit 0 |
| `swift test --scratch-path .build-b43v2 --filter 'B43Review\|B43Meeting'` after restoration | **7 passed, 0 failures**, exit 0 |
| `swift build --scratch-path .build-b43v2` | exit 0 |
| `bash -n scripts/make-app.sh` | exit 0 |
| `git diff --check` | clean, including final documentation/staged changes |

Final logs are `/tmp/b43v2-final-{regressions,meeting,related,build,shell,diff}.log`; command receipts are `/tmp/b43v2-final-results.json`. All five compiled reversal groups failed their selected methods: **7 distinct selected methods, all failing at runtime**, with exact source restoration hashes in `/tmp/b43v2-proof/restoration.json`. No independent review round was run by this implementation sub-agent.

Task resources were `.build-b43v2`, the new fixture root recorded in `/tmp/b43v2-env.json`, and the exact external UUID fixture directories journaled by the tests. After all test processes exited, cleanup checked recorded device/inode/owner identities, descendant ownership and the open-file inventory. It removed **293** receipt-owned paths (including scratch and fixture roots), observed **32** already absent paths, and preserved **0** leftovers. One exact test-authored `everyone deny delete` ACL was removed from its verified `wave7e1-storage-*` fixture parent. Journals were copied to `/tmp/b43v2-proof/fixtures/` first. Cleanup receipt: `/tmp/b43v2-cleanup.json`; root identities: `/tmp/b43v2-owned-resources.json`. Only diagnostic scripts, logs, JSON receipts and proof snapshots under `/tmp/b43v2-*` and `/tmp/b43v2-proof/` remain for review. No task database, test process, server, browser or device remains. No user namespace, shared cache, dependency tree or other checkout was cleaned.

### V2 fixture environment

The test runner uses a fresh 0700 owned root (canonical absolute path; no symlink ancestors) recorded in `/tmp/b43v2-env.json`; its `meeting-fixtures.jsonl` and `general-fixtures.jsonl` files are precreated 0600, and its `fixtures/` directory is 0700. The environment keys are `PARLA_MEETING_OWNED_RUN_ROOT`, `PARLA_MEETING_FIXTURE_MANIFEST` (exactly `$PARLA_MEETING_OWNED_RUN_ROOT/meeting-fixtures.jsonl`), `PARLA_TEST_FIXTURE_MANIFEST`, and `TMPDIR` (the new root's `fixtures/`). Foundation's temporary-directory helpers can still create UUID fixtures in the system temp directory; their exact identities and paths are journaled for cleanup. No historical fixture root is reused. `/tmp/b43v2-run.py LOG COMMAND...` loads only those fixture variables and records the command's output/exit code.

Commands: `swift test --scratch-path .build-b43v2 --filter Meeting`; `swift test --scratch-path .build-b43v2 --filter 'SavedAudioImportStorageTests|SavedAudioImportStoreTests|HubHistoryExportTests'`; `swift test --scratch-path .build-b43v2 --filter 'B43Review|B43Meeting'`; `swift build --scratch-path .build-b43v2`; `bash -n scripts/make-app.sh`; `git diff --check`. All capture, conversion and recognition in new tests are injected. No real capture, provider, download, browser/device launch, signing, push or tag is authorized or performed.

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
