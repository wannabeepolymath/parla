# Actual Hub owned read-only candidate — 2026-11-01

CURRENT RESULT — 2026-11-02: packaging corrected and statically verified; the final authorized attempt displayed/navigated successfully but failed normal bounded exit (parent SIGTERM at 60.063 s, reaped -15). Hub preview is set aside, with no Hub source integration or further launch. Accepted count remains 24/43. Earlier attempts and design text remain historical; the latest dated observations below supersede their execution labels.

The candidate subsequently passed source review, nine focused tests and a qualification build; both shipping and malformed qualification refusal controls returned 64. These are separate historical receipts in `macos-owned-hub-ui-candidate2/{review1,root-check2,root-qualification-build1,owned-ui-run1}` under the fixed scratch parent.

On 2026-11-02 the entire prepared bundle inventory matched `owned-ui-run1/plan.json` before and after its single direct launch (PID 62221). The parent observed/reaped exit 64 after 4.495 seconds without forced termination; its process group was absent. Stderr was exactly `Owned Hub admission or composition refused.` No `admission.consumed`, presentation or termination receipt appeared; no owned on-screen window was observed. Display, navigation, 45-second lifetime and normal quit therefore remain unqualified. No second launch, capture or manual signing occurred.

A fresh read-only gpt-6.1-sol high/Standard review returned CHANGES: the physical-path guard used Foundation resolution, which removes `/private` from existing macOS paths. A separate direct Foundation probe confirmed that behavior for this owned parent. Existing fabricated `canonical: true` test evidence missed the real adapter. The pending correction uses POSIX `realpath` for inspection and runtime bundle-path comparison, retaining exact fixed-path validation. A real owned-directory test exercises physical spelling, missing paths and symlink refusal. See `resume-20261102` and `macos-owned-hub-ui-candidate2/resume-investigation1` for new evidence. Tests/review of the correction and any further UI launch must be recorded separately.

The first correction test invocation exited 1 before tests: `error: emit-module command failed due to signal 11 (use -v to see invocation)`. Its diagnostic reported `_DarwinFoundation1` defined through both `/private/var/...` and `/var/...` spellings of the same module cache. The failed log is preserved at `resume-20261102/physical-path-focused`. A follow-up command uses the original `/private/var/...` scratch spelling without deleting caches. No failure is reclassified as a pass.

## Composition and admission

`PARLA_OWNED_HUB_UI` selects `OwnedHubLaunch.run()` instead of the shipping top-level entry. It never constructs AppDelegate, claims its shared flock, redirects logs, or creates its startup services. The shipping body remains intact in the other compile branch; that branch refuses `--owned-*` and `--parla-owned*` before NSApplication. Other shipping argv keeps its existing behavior.

Qualification argv must be exactly these eight tokens, with a newly selected canonical lowercase UUID `ID`:

```
<A>/owned-hub-ui-ID/ParlaOwnedHub-ID.app/Contents/MacOS/Parla
--parla-owned-hub-ui
--owned-root
<A>/owned-hub-ui-ID
--owned-run-id
ID
--owned-lifetime
45
```

Here `<A>` is the literal fixed parent in `OwnedHubGate.fixedParent`, not a configurable environment value. Before NSApplication or any composition factory, the gate checks the exact argument grammar, canonical paths, fixed-parent child, unique per-run bundle/executable/identifier, owner, types and exact modes. The proposed future parent precreates the root with only its bundle and a zero-byte `admission.once`. Root, bundle, Contents, MacOS and executable must have mode 0700; Info.plist and the marker must have mode 0600. Regular checked files must have one link. `CFBundleIdentifier` must equal `dev.parla.owned-hub-ui.ID`. The gate also refuses an alternate principal application class and declared main nib, storyboard or application-scene resources. This finite metadata refusal is not a full bundle-resource audit. The source does not implement packaging or signing.

Filesystem metadata validation precedes evaluating bundle identity. A retained no-follow root descriptor must match the inspected root's device/inode. An exclusive descriptor-relative `admission.consumed` creation claims the attempt, including attempts whose later composition fails. Existing consumed markers or receipts make the root inventory invalid. No marker is deleted or automatically reset. The entry refuses any missing/malformed admission; a qualification build never falls back to shipping.

This is a cooperative owned-root admission protocol, not an OS sandbox, signature trust check, atomic filesystem snapshot or hostile same-UID replacement defense. Child pathname checks and Bundle metadata are not one indivisible operation. The future parent must own and keep the root stable throughout construction/run. No directory link-count/ctime invariant is assumed. The app process and linked libraries have normal OS behavior before and after its Swift entry; those are not qualified here.

## Real UI, bounded effects

The composition constructs the actual HubModel, HubWindowController and HubRootView. All existing sidebar cases remain. Content uses the real pages, with inherited disabled state and hit testing disabled; sidebar and the owned Quit menu remain outside that wrapper. Consequently this first preview also blocks content scrolling/selection. The small label explicitly says synthetic empty data and unavailable services. No ready/model/preparation success is injected. `onboardingCompleted` selects the normal full Hub layout; it does not assert a completed setup or grant permission.

The proposed narrow seventh path, HubModel.swift, is necessary because normal refresh configures RecordingStore and calls recovery projection; descriptors may prune, read WAV headers and construct AVAudioFile. Disabled actions do not suppress those automatic calls. An optional owned policy defaults to nil. For owned mode only it seeds settings before observation, makes refresh an in-memory projection, suppresses recording-change subscription and debounce saves, routes permission evidence through the injected read-only closure, and supplies explicit cancellation without a save flush. Normal defaults/bodies remain selected for existing callers.

SettingsStore has an explicit owned URL, immutable synthetic JSON DocumentIO, rejecting atomic writes, unavailable non-Security credentials, and explicit no-op ScratchpadPreferenceIO. HistoryStore reads actual empty JSON from RAM and rejects writes. RecordingStore has an explicit absent owned directory, keepAll=false, no initial valid policy, and rejecting writer/remover; automatic owned routes never configure or enumerate it. Model path is the admitted absent owned `unavailable-owned-model.bin`. The single DictionaryLearner.Store reads an explicitly absent owned proposals URL once and is captured by the page-source closures. It is not Store.shared. Its fixed absence depends on the cooperative stable-root condition above; no personal proposals are read.

The existing page-port overlay is the starting HubPages source. General's device provider is empty. An additional lazy language provider closes General → WhisperTranscriber.languages → WhisperCContext.languages → whisper_lang_* native lookup; its owned value is empty. Shipping providers stay lazy and unchanged. Dictionary appearance reads the captured store. General's two-second Combine timer still exists while that page is hosted and makes only permission-status observations. Privacy appearance routes to the owned refresh; its disappearance avoids recovery projection. Owned window focus and sidebar changes use that same refresh, and owned close/resign/root disappearance avoid shipping lifecycle projections. No inference that disabled controls suppress callbacks is used.

The declared read-only exceptions are permission/login status, AppKit/OS appearance/window bookkeeping, owned path metadata, and the existing fixed ModelCatalog existence projection. ModelCatalog is unchanged: only the three catalog paths' existence can be observed; verification/hash/install/download is not selected. Permission queries are authorizationStatus and AXIsProcessTrusted; login query is SMAppService.mainApp.status. No permission request, registration, preparation or capture owner is wired. This does not claim zero OS queries or bookkeeping.

AudioImportOwner binds the RAM SettingsStore immediately; its source/reader/job/saved-import owner remain absent. GuidedTemplateOwner is unbound, with no capture/admission/queue, false capability defaults and inert scheduling/security/suspension ports. MicrophoneTestController has nil capture, false start/permission/playback capabilities and inert scheduling. Its player factory and RecoveryPlayback factory are lazy and never invoked by automatic routes. LocalCleanupRuntime construction only stores closures and is replaced with unavailable ports. Private ShortcutLabels has a private NotificationCenter and an inert physical-key formatter snapshot. DiagnosticStore is private and empty. Credential/retry environment closures return empty dictionaries; retry factories reject. Meeting controller is nil, so the real Hub's existing unavailable state is shown. Nothing copies a view or populates a synthetic result.

Ordinary dictionary/snippet/history/profile/template/preset arrays are empty. Profile resolution and capability/snapshot projections inspect values only. Optional editor, history-export/retry, recovery-preview, saved-import and meeting branches are not instantiated because their owners/state are absent and content actions cannot create them. Escape on Templates only cancels its absent session. ShortcutRecorder appearance does not arm a local monitor; resign/disappearance stops only a monitor it already owns. Its explicit Change action is disabled. The full shipping updater, automation, recorder, native preparation and AppDelegate startup graph is deliberately bypassed rather than claimed safe.

## Lifetime and evidence limits

A pure once-only lifetime owner arms a 45-second normal termination request at the launch callback before presentation, or accepts an earlier Quit. Time before that callback is not bounded by this scheduler; the future external parent must enforce its own overall deadline. It cancels the deadline on termination and does not send a second request. The delegate detaches hosted content to release its Combine timer/subscriptions, cancels the owned debounce without flushing, cancels owned controller work and retains/awaits any history task handles before replying to normal AppKit termination. The experimental retry owner's existing shutdown drains its retained task if present. In this selected composition no capture/recognition/provider tasks can be created automatically. Unexpected template/import/recovery work keeps termination pending instead of fabricating a drain or forcing a native exit. Executor stalls and unexpected work can prevent timely exit. Hosted-view release/cancellation is source intent, not observed SwiftUI teardown.

Descriptor-relative exclusive receipts record only `presentation-requested` and `termination-intent`, with `actualExit=unobserved`. Receipt writes can fail and are not treated as exit proof. The future external parent must require expected receipt contents and separately observe/reap the exact executable child, including a deadline policy if it fails to exit. No open-W exit-code substitution, launcher or manual codesign implementation is included.

## Future checks — unexecuted

The adjacent candidate `future-checks.json` enumerates nine exact OwnedHubLaunchTests methods and one existing shipping regression selector. The new tests exercise the real gate's factory order/refusals with finite metadata values, concrete RAM store composition and refresh observations, explicit page-provider identity, nil default policy, and lifetime cancellation/once behavior. They do not invoke NSApplication, execute permission/device/whisper factories, or assert implementation strings. Model construction resolves owned URL metadata; the Dictionary test performs its real missing-file attempt at a unique uncreated owned test URL because Store has no RAM constructor. These are model-level tests, not a no-filesystem mathematical proof or rendered callback tests. No XCTest has been run.

Separate future authority is required for an owned integration checkout, compiler/typecheck/tests, qualification build/link/package identity, and an external-parent UI launch/exit/reap observation. Source review should first challenge the seven-path effect map, gate ordering, Swift 5.9/macOS 13.3 compatibility, actor isolation, SwiftUI disabled/hit-testing/accessibility behavior, view teardown, and termination callbacks. None is claimed proven by a Python patch check. No global Package.swift or ModelCatalog edit is proposed.


## Corrected owned launch attempt — 2026-11-02

The user explicitly authorized one additional 45-second restricted read-only launch. Before that attempt every bundle inventory entry matched `resume-20261102/owned-ui-run2/plan.json`; the root contained only its prepared bundle and empty admission marker. The original plan's `authorized: false` remains historical; a separate exclusive `authorization-consumed.json` records this new grant.

The exact prepared executable was launched once as PID 78375 with PARLA_/DYLD_ environment variables removed. The parent reaped signal 6 (raw return -6) after 0.763 seconds, without forced termination; its process group was absent. dyld stderr began:

```
dyld[78375]: Library not loaded: @rpath/whisper.framework/Versions/Current/whisper
```

No admission-consumed, presentation or termination receipt appeared. Application admission and UI startup were not reached; display, navigation, quit and the 45-second application lifetime remain unverified. The complete bundle inventory remained unchanged. No capture, signing, further launch or main integration occurred.

An independent read-only gpt-6.1-sol high investigation completed with exit0 and DOES-NOT-HOLD on loader sufficiency. Current LC_LOAD_DYLIB command14 requires the framework, but LC_RPATH commands66–68 do not reach Contents/Frameworks. The earlier executable additionally has command69, `@executable_path/../Frameworks`; replacing it with the fresh SwiftPM product omitted that packaging adjustment. Both framework inventories, architecture, symlink targets and IDs checked fine. The source path correction is not implicated by this pre-main loader failure. An inventory equality check alone did not validate loader sufficiency.

The qualification build had completed exit0; the prior focused path-correction command passed10 tests, and correction review round2 approved with S1 resolved/no new findings. No new tests or broad run were performed in this resumption because integration stopped at the failed launch. The drafted owned-app-audio review has no saved final verdict/result and remains unapproved.

Evidence under the fixed scratch parent: `resume-20261102/owned-ui-run2/{authorization-consumed.json,inventory-before.json,pid.json,launch-result.json,launch-stdout.txt,launch-stderr.txt,executable-load-commands.txt,prior-executable-load-commands.txt}` and `resume-20261102/loader-investigation/{prompt.txt,stdout.txt,stderr.txt,result.json}`. Retained prepared bundle root: `owned-hub-ui-9e478049-ed61-43bb-8cc3-670721e41e37`. Both failed-attempt bundles/receipts remain preserved. The reviewer process completed; no task app remains running. OS-generated crash diagnostics were not inspected or removed. No cleanup was attempted.

Per the user's stop condition, another launch requires a new explicit grant. Proposed next work is a packaging-only correction restoring the missing framework runpath, independent review and static dependency/inventory verification before any newly authorized single launch. No packaging correction has yet been applied. Main remains `2ff06f78b21213a62138cae4903df7e39b70da38`:24 complete,5 reviewed,12 implementing,2 planned out of43.


## Packaging correction and final authorized attempt — 2026-11-02

The user authorized a packaging correction and one further restricted 45-second launch, with no further launch if unsuccessful. A fresh independent gpt-6.1-sol high/Standard read-only review APPROVED the correction in one round. It traced the omission to the rebuild argv: the original qualification build supplied `-Xlinker -rpath -Xlinker @executable_path/../Frameworks`, whereas the replacement build omitted those flags. Restoring the original linker flags passed the qualification build (exit 0); no source or manual signature alteration was needed. Static `otool -l` and `otool -L` checks established the expected runpath/dependency, and the framework physically resolved inside the new bundle. Its complete inventory matched a fresh plan.

Exactly one app was launched, PID 84700, from new owned root `owned-hub-ui-a4fffad5-dbe8-4692-a616-221941fa53a8`. CGWindow observed one on-screen 920×640 window; AX pressed History, Dictionary and General successfully and observed the corresponding content. Both presentation-requested and termination-intent receipts exist. **Normal bounded exit failed**: after 60.063 seconds the parent sent SIGTERM, reaped raw exit -15, and observed the process group absent. The observation recorded `TimeoutExpired` while waiting for the exact child. Bundle inventories matched before and after; stderr was empty. No capture or manual signing occurred.

The Hub preview is set aside and not integrated. No additional launch is authorized or proposed. The passing physical-path source tests and approved packaging correction do not override the failed process-lifetime criterion. Main remains 2ff06f7, with 24 complete / 5 reviewed / 12 implementing / 2 planned out of 43.

All new preparation scripts, build/review/observer receipts, fresh plan, static checks and process result are retained under the existing fixed scratch parent at `resume-packaging-20261102/`; the new owned bundle root is retained beside it. The two previous failed attempts remain preserved. Independent termination diagnosis is recorded separately when it finishes.

Independent termination investigation finished exit 0, DOES-NOT-HOLD on bounded auto-termination. The probable explanation is a main-queue scheduling deadlock: the main-dispatch deadline synchronously enters NSApp.terminate, while the delegate returns terminateLater and queues a MainActor drain to issue the final reply. AppKit modal waiting may prevent recursive main-dispatch servicing. This is an inference, not a proven stack diagnosis: intent is written before terminate, and no delegate-entry/drain-entry marker or stack was captured. The separate deliberate readiness-refusal branch can also hold termination indefinitely, but the selected idle owners argue against that branch here. Tests cover lifetime request-once and idle-owner policy, not the actual AppKit termination loop. Full review and checked-and-fine evidence: `resume-packaging-20261102/termination-review/{stdout.txt,result.json}`. No source fix or further runtime check was made; the candidate remains set aside.

## Separate synthetic owned-app-audio source review — 2026-11-02

The previously unfinished fixture review completed with CHANGES. S1 identified precharge slots 0/1 conflicting with the production 1/2 contract; S2 identified a trace-drain/start-flag sampling race that could publish native-start before the supervisor required start:return. Root independently verified both by symbol. The original candidate1 is preserved; a new artifact-only candidate2 corrects those two points. A fresh read-only gpt-6.1-sol high/Standard round2 APPROVED, resolving S1/S2 with no new changed-code findings.

All 11 production MeetingAudioIngressTests passed, zero failures. Artifact controls passed 12 frozen vectors, a positive decoder case, four rejection cases and label-only cleanup rejection. The regenerated nine-file patch passed forward/reverse byte proof. Its first proof invocation failed with FileNotFoundError for the omitted `absence-before.json`; after copying the unchanged historical baseline record from candidate1, the follow-up passed. This remains a historical base record, not a fresh checkout absence assertion.

Candidate2 is retained at fixed scratch `macos-meeting-owned-app-audio-qualification-candidate2/`, with patch, exact mirrors, source pins, byte proof and review ledger. Reviews/check logs are under `resume-packaging-20261102/`. No fixture Swift compile/link, packaging, dormant host or native capture run occurred; no grant was issued. B43 remains incomplete and policy-blocked. The fixture and its visibility amendment were not installed into any checkout or main.


## Subsequent independent backlog correction

After setting the Hub preview aside, fresh finite reviews and focused checks were completed for B25/B26/B52/B53/B54 without acceptance promotion. B54 retains its user-deferred layout/hardware block. B19 then exposed an acknowledged-Start cancellation gap, independently confirmed and reproduced before correction: three tests with eight failed assertions. A minimal session-ID-guarded settlement correction passed all44 AutomationTests and a fresh second-round approval. The ordinary W broad snapshot executed2,134 tests,12 skipped,zero failures, with two real-model tests and the unchanged previously observed virtual-capacity test explicitly excluded. Source/test hashes stayed exact. This separate B19 correction and documentation reconciliation are eligible for main integration; Hub and audio-fixture source remain excluded. These later source checks do not change this document's failed Hub lifetime result.


## Final audio artifact binding reconciliation — 2026-11-02

Candidate2's copied supervisor and grant template still named candidate1. A fresh neutral independent investigation confirmed that its self-path/manifest gate could not admit candidate2 itself. A pure import/binding assertion reproduced the failure: `AssertionError: candidate source binding mismatch`. Candidate3 preserves candidates1/2 and changes only the two executable source bindings; the original slot/trace fixes remain byte-identical. Binding,12-vector/decoder controls and regenerated nine-file patch proof pass. Fresh source-review round3 APPROVED, S1/S2 remain resolved and S3 is resolved, no new findings. Current artifact: fixed scratch macos-meeting-owned-app-audio-qualification-candidate3/.

This supersedes candidate2 as the current artifact, while preserving its historical review receipts. There is still no fixture compilation, native admission, capture or runtime grant. Source is not integrated into main. The Hub remains set aside after its failed bounded exit; no additional launch occurred. See the2026-11-02 backlog source-recheck note for final item phases and remaining source gaps.
