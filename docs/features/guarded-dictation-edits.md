# Undo Last Dictation / Restore Raw — B24

B24 ships on by default in 0.7.0. **Undo Last Dictation** and **Restore Raw
Text** appear beside **Copy Original** in the menu bar. They are enabled only
while a verified insertion receipt exists. There is no experimental toggle,
Cmd-Z interception, blind backspace, automatic replacement or keystroke fallback.
B08 still tracks real-app qualification; source tests do not qualify an editor.

## 0.7.0 accepted safety contract

macOS Accessibility has no conditional write. B24 uses the same contract as the
shipping `Inserter.replaceTypedTail`: **read immediately before writing, write
only on exact match, then verify by readback**. The previous safety stop demanded
a stronger target-side transaction than AX provides; that requirement has been
explicitly replaced by this contract.

A receipt records the target pid and bundle id, focused AX element identity,
full field values before and after insertion, selection/caret after insertion,
inserted UTF-16 range, exact raw transcript, delivered cleaned text and monotonic
timestamp. The before selection is also retained so Undo can recover text that
was selected and replaced. Ordinary non-live keyboard dictation carries its raw
ASR directly to its actual insertion effect, before replacements, snippets,
provider cleanup or destination shaping. It never reconstructs raw from History
or a global latest-transcript property.

The production adapter requires nonsecure, readable text/selection and settable
value/selection attributes. It checks the element's pid against the frontmost
app and refuses missing role/subrole security evidence. It does not prompt,
wake an AX tree or capture a secure field's value. Opaque and read-only fields
cannot acquire receipts. The snapshot is captured in the actual dispatch hook,
after clipboard preparation. Posting Command-V alone proves nothing. A bounded
one-second sequence of AX reads (a single AX call can overrun its deadline) must find the exact expected complete field
value, caret, element, pid and bundle id before publishing a receipt. There is
no receipt for failed or unverified delivery, including paste-only targets.
Clipboard data requests are not insertion evidence.

On an explicit action, Parla computes the desired text, consumes the receipt,
then re-reads the focused field immediately before its write. The app, element,
security, full UTF-16 value and selection must exactly match the receipt.
Any mismatch or expired/missing receipt refuses with:

> The text changed since Parla typed it — use Copy Original

Undo restores the complete pre-insertion value and places the caret at the
insertion point, including when dictation replaced a selection. Restore Raw
replaces only the inserted cleaned range with the exact raw ASR and puts the
caret after it. Both preserve surrounding text. One AX value assignment and one
selection assignment are followed by exact focused-field readback of both.
A failed native return or readback mismatch is **unverified**: the edit may land
later, so Parla never retries the write or falls back to keystrokes. The receipt
is consumed on success, refusal or unverified outcome; it cannot authorize a
second action. Copy Original remains independent.

### Accepted residual risk

AX reads and writes cross process boundaries. Between the final read and the
unconditional value assignment, the receiving app may process a user edit,
focus change or security transition. The small read-to-write window (including
the microsecond-scale race in a healthy target) is accepted. AX can also delay
an issued set. A successful readback cannot prove that no intervening edit was
lost. Value and selection are separate AX attributes and assignments, not a
transaction. An edit-and-revert or focus round trip returning to the exact same
snapshot is not detectable. This is snapshot equality, not revision-history
proof or an atomic compare-and-set guarantee. No observer, polling outside the
bounded insertion readback, or target-side revision API is claimed.

## Receipt lifecycle and privacy

Only one receipt lives in RAM. A new accepted dictation clears it before capture
effects, even if the new dictation later fails or delivers a result only.
Other actual insertions/edits, observed secure refusal, discard, explicit
tryout/microphone-test/shortcut-recording entry and quit also invalidate it.
Receipts expire exactly **10 minutes** after dispatch. Expiry cancels authority
and releases the full snapshots; menu refresh and actions also check the clock.
Callbacks hold scalar tokens and weak owners, never transcript/field snapshots.
A canceled callback or old-generation delivery cannot revive a cleared receipt.

Receipts are never encoded, persisted to disk, sent to a model, added to History
or included in diagnostics. History and recording preferences are unchanged.
This bounds the receipt owner's retention; it does not promise physical memory
zeroization, absence of OS swap, or removal of existing ASR/session copies.
Selected-text transforms, dictated presets, result-only automation, stored
history paste and legacy live typing do not create receipts.

## Copy Original fallback

`keepLastOriginalEnabled` now defaults to **true** (including missing/null
settings). Existing explicit false values still disable only this separate
fallback. Malformed values reject decoding; settings load failures disable
copying. The Hub retains the Copy preference and explains that it does not
disable guarded edits. The menu omits the old permanently grey “Original copy
is off” status row and hides Copy Original when explicitly disabled.

When enabled at capture and dispatch, an ordinary non-live keyboard dictation
may retain one original ASR in RAM, at most **65,536 UTF-8 bytes**, for **30 seconds
from paste dispatch**. Overflow refuses fallback retention rather than truncating;
guarded receipt provenance is independent of this copy-size bound. This works
with history off and for posted-but-unverified delivery. Publication requires
actual posting and current operation/generation/epoch authority. Reading or
copying never renews the deadline. New capture, insertion, disable, invalid
settings, revocation, security refusal, expiry and quit clear it.

Explicit Copy Original rechecks settings, token, generation, expiry and current
nonprompt security evidence before writing only the raw transcript to the
clipboard. It does not paste, edit a field, invoke a model or write History.
The existing clipboard change-count ownership prevents a pending temporary
paste restore from overwriting this explicit copy. No new keyboard shortcuts
were added: global shortcut dispatch requires separate binding/schema/UI work.

## Verification

XCTest uses the production guard and lifecycle logic with fake field read/write,
clock, scheduler and paste ports. It covers success, selection replacement,
Unicode, all identity/value/selection/security/expiry refusals, unverified paste,
delayed readback, stale callbacks/generations, readback mismatch with no second
write, next-capture clearing and menu enablement. Temporary implementation
reverts establish that all **27 new tests fail** without receipt publication/the
new menu (71 assertion failures). A separate revert of the fresh equality guard,
receipt consumption and readback-result handling fails **13 safety tests** (77
assertions). Both reverts were restored exactly. **278 focused tests pass**,
covering the new tests plus existing insertion, reducer, settings, clipboard,
vocabulary/profile and surrounding-text delivery suites. Existing reducer
expectations now assert the exact raw/session provenance on insertion effects.
`swift build` and `git diff --check` also pass. Commands use the isolated scratch
directory `/tmp/parla-b24-v2-artifacts/build`; proof scripts/logs and the private
fixture manifest are retained under `/tmp/parla-b24-v2-artifacts/`. The surrounding-
text suite requires `PARLA_TEST_FIXTURE_MANIFEST` and `PARLA_B26_FIXTURE_ROOT`;
a run without that setup refused its fixtures, and the configured rerun passed. No third-party apps,
computer use or microphone are used. Native rich-editor model/formatting,
clipboard timing and menu-focus qualification remain B08 work.
