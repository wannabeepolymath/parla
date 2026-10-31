# Brief Original copy — partial B24

B24 is **PARTIAL**. This source slice provides an optional Copy Original fallback.
Guarded Undo Last Dictation and Restore Raw are **unavailable pending native
qualification**. There is no field receipt, qualified native mutation adapter,
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
