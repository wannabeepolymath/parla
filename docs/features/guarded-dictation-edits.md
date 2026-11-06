# Brief Original copy — partial B24

B24 is **PARTIAL**. This source slice provides an optional Copy Original fallback.
Guarded Undo Last Dictation and Restore Raw are **blocked on a safe mutation
contract**, with real-app qualification tracked separately under B08. There is
no field receipt, qualified native mutation adapter,
Undo button, Cmd-Z interception, automatic replacement or blind backspace.

## Opt-in and retention

`keepLastOriginalEnabled` defaults to `false`. Missing or null decodes as false;
a malformed value rejects decoding under the settings policy. A settings load
error disables retention and copying even if unrelated globals were recovered.
The Hub's Data & Privacy page explains the choice. Saving only this flag, mouse
binding changes, coalesced reverts or net-zero general edits uses passive
configuration; it does not call the general mic/model setup callback. Genuine
general preference changes retain their existing callback.

When opted in **at capture and at dispatch**, ordinary non-live `.dictation`
with keyboard delivery may retain one exact finalized ASR original in RAM.
Physical keyboard and mouse dictation share this path. This is the original
passed to the reducer, before local replacements, snippet expansion, provider
cleanup or destination shaping. It is carried directly to the actual insertion
effect and executor; it is not recovered from History, the automation result
store or a global latest-transcript property.

The slot is independent of history and usable with history off. It retains no
field text, selection, AX identity, audio, credentials or full-field snapshots.
It changes no history schema, result retrieval schema or profile policy. Its
maximum is **65,536 UTF-8 bytes (64 KiB)**; overflow refuses retention rather
than truncating. Its deadline is **30 seconds from paste dispatch**, using a
monotonic clock. Slow clipboard preparation precedes that start, while time
spent returning from the paste counts against the deadline. Reading, refreshing
and copying do not extend it. Timer closures carry only an epoch, not text.
This bounds the experiment-owned slot, not all existing ASR/session/history
copies in process memory. No secure physical zeroization is claimed.

Publication requires a real authorized insertion returning `posted = true`, a
dispatch callback, the accepted capture's operation and generation, current valid
opt-in, and a still-current epoch. This is **posted-unverified**: it establishes
neither acceptance nor insertion into an external field. Existing normal paste,
correction learning, diagnostic posting, history and final-result semantics
remain independent. Old raw text may deliberately still paste under existing
policy after a newer capture; it cannot gain new Original-copy authority.

Spoken transforms, selected-text transforms, dictated presets, result-only
automation, stored/history paste and legacy live typing do not publish a slot.
Turning on the preference after capture cannot retroactively authorize it.

## Explicit action and invalidation

The production menu and Hub show only scalar availability and the
posted-unverified label, with **Copy Original** enabled for a fresh owner.
They do not preview the transcript or put it in a tooltip or log. The same
controller rechecks valid current settings, the displayed token, epoch, deadline,
generation, revocation and nonprompt current security immediately before an
explicit clipboard write. Secure or unavailable security evidence clears the
slot and refuses the action. The production adapter uses existing current-focus
classification and secure-input/permission evidence, without opaque paste
fallback or AX wake-up. Failed role/subrole evidence refuses copy; controls
with known nonsecure roles do not need to be editable. No field value/range is
captured for this security check.
Hub activation does not itself invalidate Original: copying needs no retained
field identity. No native focus-preservation claim follows from this.

Each deliberate click may copy once until the original deadline. Copy writes
only the bounded original, never prepared/final text. It uses the app's existing
explicit clear-and-set clipboard semantics: the change count changes so an older
temporary-paste restore cannot overwrite a new user copy. It neither pastes nor
edits a field, runs a model, nor writes history. There is no keyboard shortcut.

A new accepted capture clears before capture effects, including automation and
transform captures. Any new actual insertion/edit clears, even if it cannot
publish or posting fails. Revocation, secure refusal or an already-observed
secure transition, disabled/invalid configuration, exact deadline expiry and
quit/restart clear authority. Tryout, microphone-test and shortcut-recording
entry also clear without adding recorder/model setup. A completed operation may
own a fresh slot until its deadline; revoked work cannot. Canceled timers,
delayed completions and newly enabled settings cannot revive an old slot.
The disabled path adds no experiment field/security reads, timer, retention or
copy. No observer, focus polling or clipboard polling is added; an unobserved
external security change is checked on explicit Copy rather than polled for.

## Later work and release prerequisites

Full-field receipts and proven mutations are later work. Enabling Undo/Restore
requires a separately qualified, narrowly bounded native field capability with
positive same-field identity, coherent full text and UTF-16 selection, freshness,
observed target changes, exact accepted-paste evidence and a demonstrated single
mutation restoring both text and desired selection, followed by exact readback.
Generic cross-process AX read/check/set is not a transaction and cannot by itself
establish atomic prevention of concurrent external edits. An empty capability
allowlist would not qualify support.

Opaque, rich, terminal/remote and unqualified editors remain outside native
mutation support. Qualification must document app/OS/version/field behavior,
selection replacement, Unicode, concurrent edits, focus changes, delayed native
operations, security/permission loss and target model/formatting consistency.
Source tests with fake poster, security, clipboard, clock and scheduler establish
application authority and provenance only. They do not qualify native paste
acceptance, AX mutation, clipboard timing or Hub/menu focus behavior. No native
qualification or B19 build/sign/extraction permission is implied by this slice.

## 0.7.0 safety stop (B24, 2026-11-07)

The default-on implementation was stopped under the task's explicit safety-stop
condition. This is unfinished source work, not a B08 qualification-only gate.
No Undo/Restore Raw action, shortcut, full-field retention or new default was
added. The existing optional Copy Original behavior and menu remain unchanged.

The requested contract includes *no edits since insertion*, not merely equality
at the instant of a read. The existing production primitives cannot prove that
contract or condition a mutation on it:

- `Inserter.postPaste` posts Command-V events. Its successful return means
  dispatch, not acceptance by a particular field. `ClipboardDelivery.paste`
  records `posted` after the callback; a pasteboard data request is not field
  insertion evidence.
- `Inserter.fieldState(of:)` reads `AXValue` and `AXSelectedTextRange` separately.
  `Inserter.Destination` retains field/app identity, but no target revision or
  edit history. Identical values after an edit-and-revert or focus round trip
  cannot establish that no intervening change happened.
- `Inserter.replaceTypedTail` checks a previously read value, then sends an
  unconditional `AXUIElementSetAttributeValue`, then reads back. Its “atomic
  write” comment describes one value assignment, not an atomic conditional
  read/check/write. Selection restoration is another write. Its own comments
  acknowledge that a target can apply an issued AX set later.
- `CorrectionWatcher` receives AX notifications through a run loop and delays
  attachment after paste. It is a learning observer, not a synchronous target
  revision barrier or an insertion receipt; it cannot authorize these actions.
- The installed SDK's `AXUIElementSetAttributeValue(element, attribute, value)`
  accepts no expected old value/revision. `AXUIElementCopyMultipleAttributeValues`
  supplies a read API, not a conditional write. Neither provides the missing
  target-side compare-and-replace operation.

A concrete unsafe ordering is: Parla verifies the receipt's full value and
selection; the receiving app processes an edit (or changes focus/security);
Parla's unconditional AX assignment applies a value computed from the old
snapshot. The assignment can discard that edit. A subsequent exact readback can
match Parla's requested value while the user's edit has already been lost.
Adding another read, an observer, a shorter deadline or a main-thread lock in
Parla does not serialize the receiving process. A fake field with an atomic
compare-and-replace method would test a stronger capability than this production
AX path implements.

Unblocking the strict contract requires a supported target capability that
checks field identity, security, focus/edit revision and expected value/selection
at the point of mutation, with confirmed insertion provenance. No such external
adapter is present in this checkout. A best-effort snapshot/check/set product
would require an explicit change to the safety contract; it must not be shipped
as the requested proven guard. B08 remains responsible for real-app qualification
of an eventual adapter; it does not supply this missing source capability.


Verification for this stop: `swift test --scratch-path
/tmp/parla-b24-safety-CDanac/build --filter OriginalCopyTests` passed all 28
existing tests, including existing menu enablement checks. `swift build
--scratch-path /tmp/parla-b24-safety-CDanac/build` passed; `git diff --check`
passed. These validate the unchanged fallback and compilation only. No new
receipt/guard tests or temporary-revert proof were produced because no guarded
action was implemented. No third-party app, computer use or microphone was used.
Logs are retained in `/tmp/parla-b24-safety-CDanac/`; its isolated build directory
was removed after both commands exited. No dependencies were installed.
