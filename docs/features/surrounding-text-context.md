# Surrounding text for cleanup

Parla can use a short passage before the caret to help cleanup with spelling,
casing and continuity. Existing document text is separate untrusted context in
the cleanup request; it is never concatenated into the dictation or used as an
instruction. The existing cleanup sanitizer, output validator and literal rules
still run once.

## Defaults and consent

- **Apple Intelligence:** on by default, including existing installations. The
  normal **Profiles → Surrounding text → Use nearby text with Apple Intelligence**
  switch saves `cleanup.localSurroundingTextEnabled`. Turning it off immediately
  closes new captures and revokes held work, including before or after a failed
  save. Only a new enable intent may reopen that draft latch. A missing preference defaults on; a present invalid preference refuses.
  Apple Intelligence remains on-device, with no endpoint, credentials, HTTP or
  fallback provider. Its ordinary language, availability and input-budget gates
  still apply.
- **Cloud and OpenAI-compatible providers (including loopback):** off by default.
  The user must choose **Review cloud context** for one saved exact app profile,
  read the provider/endpoint/model disclosure, and explicitly enable it. The UI
  states that existing text the user did not dictate will be sent with dictation.
  Consent is user settings, never inferred from Accessibility permission, local
  mode, a provider key, or another profile. Reviewing does not sample a field,
  read credentials, or contact a provider.

Cloud consent binds the saved profile, requested provider, canonical endpoint,
exact model and ordinary credential precedence. Profile/order/word/rule/style or
provider changes revoke it. Reconfirming authorizes future captures only. The raw
`surroundingTextContext` authority keeps its independent strict decoding and
compare-and-swap preservation, including unknown/malformed roots. Older reviewed
signatures pause and need review again under this contract. An invalid/old cloud
block is preserved and cannot suppress or authorize the independent local setting.
Cloud context never
uses a backup provider. A reported model mismatch rejects output after the
request may already have been sent and billed.

Only ordinary physical, non-live keyboard dictation into the same start/landing
app is eligible. Local mode supports global or saved app profiles; cloud mode
requires the same reviewed saved app profile at start and landing. Browser/site
profiles, transforms, saved presets, Shortcuts, imports, retries, guided forms,
recovery, previews and evaluation do not gain context permission. Raw, cleanup-off
and exact snippet branches bypass collection.

## Native Accessibility reader

`NativeSurroundingText.swift` supplies the production `SurroundingTextPort.native`.
It uses an operation-owned serial Dispatch worker, never synchronous AX reads on
the main actor or inside a Settings lock. The source facade exposes only focus,
PID, bundle ID, role/subrole, editability, selected range, character count, window
and exact parameterized string ranges. There is no full-value or selected-text
read, clipboard access, AX wake-up, OCR, screenshot, window search or expanding
range fallback.

The reader requires existing Accessibility trust, secure event input off, an
editable standard text field/area/search field, a collapsed selection, matching
positive PID, and a matching focused window. It refuses secure/password subroles,
known password managers, terminals, browsers, remote clients and code editors
(including their integrated terminals). Unknown/noneditable roles refuse. This
is capability-based support, not a certification of every app that exposes AX.
The named `refusedRemoteClientBundleIDs` constant explicitly refuses Apple
Screen Sharing/Remote Desktop, Microsoft Remote Desktop (stable/beta),
TeamViewer, AnyDesk, Jump Desktop, Parsec, RealVNC and Splashtop Business before
AX field access, in addition to the existing substring and category checks.

Fresh observations compare actual AX application, window and field references
with `CFEqual`, plus PID, bundle, caret, selection and document length. They run
before and after the native range read, and again at the existing cleanup
admission/response/delivery boundaries. A changed identity/caret/length or unknown
security signal refuses. No hashes or pointer addresses are used as identity.
Only operation-local numeric tokens cross into the nontext policy proof.

One exact preceding range reads **at most 512 UTF-16 units**. At most **two
following UTF-16 units** are inspected locally to establish a Unicode caret
boundary; following text never enters the provider prompt. If the leading range
starts inside an unproved grapheme, the reader discards through a proven LF or
ASCII space/tab-to-letter/digit break. An unbroken truncated window, invalid
surrogate, split caret grapheme, over-returning source or unproved boundary
refuses. Retained provider context walks complete graphemes backwards to **256
UTF-16 units and 1024 UTF-8 bytes**, whichever binds first.

Each AX reference receives its own positive messaging timeout immediately before
remote access, at most **100 ms** and at most the remaining absolute job/phase
budget. Focus comes from the frontmost application; the reader never changes
the process-wide timeout through a system-wide AX element. Equal-but-distinct
references do not inherit timeouts; this follows
[Apple's AX timeout contract](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).
A job has a one-second acceptance deadline; the existing one-second pre-read
phase includes proof, learning disarm, read and acceptance. The overall cleanup
budget remains 15 seconds. Deadline equality refuses. A late result cannot become
context or trigger a provider request.

Cancellation closes admission through the existing memory latch and the worker's
cancellation flag. Every native job and cancellation relay is retained through
actual return. `finishAndWaitForExit` joins the serial queue and releases retained
AX references before output authority is handed off or the pending lane exits.
An armed but unused handle is also drained. Neither a timeout nor a cancellation
acknowledgment is treated as worker exit. AX messaging timeouts bound IPC waits;
this is **not** an OS scheduling guarantee or permission to detach a stuck native
call. If an OS call ignores its timeout, the owning lane stays pending until exit.

Before read participation, unsupported metadata may follow ordinary cleanup once.
After participation, failures return raw speech with local literal rules, without
another category request or backup. The sole participated ordinary fallback is a
proved exact empty document-start prefix. An unsupported context echo instead
allows one context-free cleanup retry on the same provider/client and settings,
inside the original 15-second deadline and cancellation/authority scope. This
retry never switches to ordinary category cleanup or a backup provider.

## Data lifetime and output

Nearby text exists only in the worker/read/request lifetime. It is not Codable,
placed on a Session, stored in History, exported, cached, logged, or included in
diagnostics. Errors remain content-free. Context-assisted output is eligible only
for the independently authorized pending insertion; it cannot enter tail
replacement, History/retry/export, last-result retrieval or correction learning.
History, when independently enabled, stores raw dictation and empty owned cleanup
metrics. Explicit Original/Copy retains only the user's dictated speech under its
separate permission. Context admission and influenced insertion disarm learning.

Before context-assisted output reaches Pipeline, the ephemeral prefix rejects
any shared four-word window absent from the raw dictation. The named
`unsupportedEchoWordThreshold = 4` balances sentence-copy detection with common
short phrases. Matching uses canonical Unicode normalization, case folding, and
letter/number words separated by punctuation or whitespace. Shorter overlaps and
windows also present in raw dictation remain eligible. A rejected response never
reaches insertion or persistence; only a successful context-free retry may
continue. That retry is checked against the same prefix too. A repeated echo,
provider error or invalid retry result preserves the existing raw-text fallback.
This deterministic overlap guard does not detect paraphrases or shorter leaks.

Matching observations are not an atomic cross-process snapshot. Unobserved
away/back transitions and same-length edits can evade observation; the field can
change immediately after a proof. AX implementations can allocate more than the
logical text cap. Swift/native/provider copies are not guaranteed zeroized or
erased, and remote execution/billing cannot be forcibly stopped.

## Verification and remaining qualification

`NativeSurroundingTextTests` uses an owned synthetic AX field facade with the
production worker and reader, not a real third-party app or provider. It covers
late-return timeout and per-reference timeout application, caret/field changes,
secure input/field/password-manager/terminal/unknown-role refusal, oversized-window
trimming, mid-field Unicode boundaries, held cancellation drain, and connected
History/diagnostic/learning isolation. Its Apple Intelligence test injects a local
runtime and asserts the native context reaches only that runtime, with zero HTTP
or credential reads. `SurroundingTextDefaultsTests` covers old/fresh defaults,
saved opt-out, explicit cloud review, local global profiles, revocation and
provider-switch refusal. Existing core, connected ownership and Hub tests remain
part of the focused check.

The B26 lane verification receipt records actual pass counts and behavioral
revert failures below. No live provider calls, real third-party application reads,
model downloads, human quality comparison, packaged UI inspection, or broad
app/OS compatibility claims are authorized by those synthetic checks. Native
source implementation is supplied; those qualifications remain separate.

### 2026-11-07 lane verification receipt

The focused selector is:

```sh
swift test --scratch-path /tmp/parla-b26-build-t3-c45379f7 --filter 'NativeSurroundingTextTests|SurroundingTextDefaultsTests|SurroundingTextContextTests|SurroundingTextContextIntegrationTests|HubSurroundingTextContextTests|AppleIntelligenceCleanupTests|CleanupFailoverIntegrationTests'
swift build --scratch-path /tmp/parla-b26-build-t3-c45379f7
```

The runner supplies `PARLA_TEST_FIXTURE_MANIFEST`, `PARLA_B26_FIXTURE_ROOT`,
`PARLA_B21_FIXTURE_ROOT` and `PARLA_B21_EVIDENCE` pointing to precreated private
resources under `/var/folders/vp/_gvcxwbx3rg9cz0193_n4kr00000gn/T/parla-b26-evidence-g59ebxa0`. Every recording child is fresh, empty, manifest-owned
and retained. No audio writer or remover is used. The build directory, receipts,
manifest, synthetic B21 comparison records and empty fixture directories are
preserved for review; no database, server or browser was created.

Positive: **111 executed, 2 optional B21 elapsed checks skipped, 0 failures**.
All nine new methods run. `swift build` and `git diff --check` pass. Existing
unrelated compiler warnings remain. The UI detector reports no findings; the
packaged native UI has not been visually qualified.

Fail-without-fix proof restores pre-B26 unsupported-port/no-local-grant behavior
with compile-compatible interfaces. The run exits 1 with **all nine new methods
failing, 18 failures total**, including an expected nil-request unwrap after the
connected path falls back to ordinary cleanup. This is an assertion/behavior
failure, not a compilation failure. The runner restores original source bytes
in `finally`, verifies their SHA-256 hashes, and reruns the positive selector.
The exact reverted source hashes, failed method names, exit code and restoration
receipt are in `/var/folders/vp/_gvcxwbx3rg9cz0193_n4kr00000gn/T/parla-b26-evidence-g59ebxa0/revert-receipt.json`, with output in `revert-tests.log`.

The nine failed methods were:

- `testLocalDefaultUsesNativeContextWithoutCloudOrCredentialAccess`
- `testNativeCancellationDrainsHeldReadBeforeScopeExit`
- `testNativeCaretOrFieldChangeDuringReadRefuses`
- `testNativeContextNeverReachesHistoryDiagnosticsOrOrdinaryRequest`
- `testNativeOversizeWindowTrimsAndChecksCaretUnicodeBoundary`
- `testNativeSecurePasswordTerminalAndUnknownFieldsNeverReadText`
- `testNativeTimeoutRejectsLateReturnAndSetsEachReferenceTimeout`
- `testLocalDefaultCloudConsentAndSavedOptOut`
- `testLocalGlobalCaptureGrantCannotCrossProviderOrRevocation`

Additional targeted pre-fix runs recorded the unsaved local opt-out reopening and
invalid cloud-block suppression assertions failing before their corrections.
The implementation lane did not spawn an independent review agent. Native
app/OS coverage and genuine category-only quality comparison remain open.

### 2026-11-07 B26 context-echo and remote-client follow-up

P1 now rejects unsupported context overlap before Pipeline receives output, then
uses one context-free retry on the same client. P2 adds the explicit remote-client
bundle-ID refusal list. The three reviewer probes from
`/tmp/parla-b26-review-probes.swift` were inverted and extended in
`SurroundingTextContextRegressionTests`; the existing connected sentinel test now
requires safe retry insertion. Coverage includes both cloud serializers, local
Apple Intelligence, context-only/appended echoes, Unicode case/punctuation,
short and raw-supported overlaps, failed/invalid/repeated-echo retries, raw
History isolation, and all ten remote-client IDs through the production reader.

Focused commands (all fixture parents and files are precreated, private and owned
by this task; recording children remain empty and manifest-recorded):

```sh
B26_V2_ROOT=/var/folders/vp/_gvcxwbx3rg9cz0193_n4kr00000gn/T/parla-b26-v2-6s7x_om7
export PARLA_TEST_FIXTURE_MANIFEST="$B26_V2_ROOT/manifest.jsonl"
export PARLA_B26_FIXTURE_ROOT="$B26_V2_ROOT/b26"
export PARLA_B21_FIXTURE_ROOT="$B26_V2_ROOT/b21"
export PARLA_B21_EVIDENCE="$B26_V2_ROOT/b21-evidence.jsonl"
swift test --jobs 4 --scratch-path "$B26_V2_ROOT/build" --filter 'SurroundingText.*Tests|NativeSurroundingTextTests|PipelineTests|CleanupTests|CleanupFactoryTests|CleanupFailoverTests|AppleIntelligenceCleanupTests|LocalCleanupSettingsTests|LocalCleanupIntegrationTests|CleanupFailoverIntegrationTests|HubCleanupFailoverTests'
swift build --jobs 4 --scratch-path "$B26_V2_ROOT/build"
git diff --check
```

Positive: **224 executed, 2 optional B21 elapsed checks skipped, zero failures**.
`swift build` and `git diff --check` also pass.
Separate behavioral reverts restore the original production file for each
finding: P1 fails all three affected methods with **32 assertions**; P2 fails its
production-reader method with **21 assertions**, including Screen Sharing.
Both commands exit 1 through assertions, not compiler failures. Fixed source
bytes are restored in `finally` and SHA-256 checked. All four new/changed test
methods fail without their respective fix; positive overlap controls are grouped
with rejection controls. The focused selector is rerun after restoration.

An initial loose `SurroundingText|NativeSurroundingText|Pipeline|Cleanup` selector
also selected an unrelated ActivityShadow method requiring the absent historical
`/tmp/parla-implementation-2026-10-28` fixture parent: 266 executed, 2 skipped,
1 missing-fixture failure. Its requested feature suites passed; the named-suite
selector above avoids that unrelated fixture dependency.

Retained task resources are under `/var/folders/vp/_gvcxwbx3rg9cz0193_n4kr00000gn/T/parla-b26-v2-6s7x_om7`: build scratch, empty
fixture children/manifest, B21 evidence, baseline/revert/final logs and
`revert-receipt.json` with commands, failing methods and restoration hashes.
No server, browser, database, live provider, third-party app read or download was
used. Existing compiler warnings and the earlier qualification limits remain.
