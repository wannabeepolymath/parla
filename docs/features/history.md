# Local text history (wave 2C.1)

Open **History** to search original and result text, expand both versions, use
**Copy Original** / **Copy Result**, or delete one entry. Copies are explicit
clipboard actions; reviewing, saving and retrying storage never insert text.

**Data & Privacy → Saved text limit** sets a persisted count from **1 to 1,000**,
with **50** as the default. Oldest saved entries are evicted on safe load,
append, or a saved count change. Every successful mutation also satisfies the
current saved count. The cost estimate covers the saved entries
currently present, rather than claiming a fixed time window. A failed trim
keeps the saved rows and file unchanged and reports that the count policy has
not been applied. Use **Apply Saved Text Limit** to retry it. Count limits do
not silently discard unsaved results.
If settings cannot load at startup, retention waits for a valid saved policy;
fallback defaults never trim existing text. A running store keeps its last valid
policy when settings become unreadable.

Turning **Keep local history** off stops saving newly started sessions. A
session or selection operation already in flight keeps its starting permission.
Existing entries remain readable/copyable; turning history off does not erase
them. Secure-field and cancelled captures retain their existing exclusions.
An explicitly retried save of an already permitted unsaved result remains
available while new-session history is off.

## Save errors and unsaved results

History mutations use atomic writes. Saved rows are published only after a
successful write. Failed append results remain in memory with original text,
result, app, date, metrics and transform metadata intact. History shows these as
**Unsaved result — available until Parla quits**, with Copy, **Retry Save** and
**Discard**. Retry Save writes the same result and ID; it performs no recognition,
provider request, metrics collection or insertion. Repeated retry clicks cannot
create another row. Unsaved results are not crash recovery and disappear on
quit unless saved or copied.

A failed delete or clear retains saved rows and original disk bytes. Failed
clear also retains unsaved results. Retry the row Delete or Clear action
explicitly. Successful Clear removes current saved and unsaved text; new
results arriving afterward remain new results. Discard invalidates that
pending result's Retry Save address. The status menu exposes an attention link
to History for load/write errors or unsaved results; its clear label explicitly
includes unsaved results when present. The Hub and menu use one shared store.
Successful insertion stays separate from history-write success. Storage-only
HUD claims wait for the write; stale completions can surface a persistent Hub
error without taking over a newer session's HUD.

Unreadable or malformed files block writes rather than becoming a writable
empty log. Repair the file and use **Retry Load**. A file changed, deleted or
made unreadable after load also blocks cached writes until reload. Ordinary
refresh preserves unresolved mutation errors. Reload does not complete a failed
Delete, Clear or Save; retry those actions
explicitly after the read block is repaired. The byte comparison before a
write protects against observed external edits; this is a single-process store,
not an interprocess file-locking protocol.

## Identity and compatibility

Entries have UUID identities and immutable original `raw` text. Legacy arrays
without IDs migrate on successful atomic write, preserving known fields and
array order; IDs then remain stable across reopen. Identical text/date rows are
independent. Malformed IDs are load errors. When a file contains duplicate IDs,
the first occurrence keeps its ID and later occurrences receive fresh IDs in
the same migration. Failed migration leaves bytes intact and disables row
mutations until Retry Load succeeds. A conflicting incoming/pending ID is
reidentified instead of aliasing or overwriting a saved row. Exact ID+content
append is idempotent. There is no general update API in this slice; cleanup
retry will need its own request validity checks in 2C.2.

## Text and audio are independent

Delete, Clear and count eviction remove **text only**. Recording files are
managed separately under the independent recovery-audio policy (enabled with a
seven-day lifetime by default; configurable from 1–30 days). Existing text rows
have no audio association; timestamps never imply one. See
[audio recovery](audio-recovery.md) for playback, explicit local transcription,
audio enablement/lifetime controls and lease exclusions.
Eval does not create a HistoryStore or use these controls in recognition/cleanup.

## Qualification

Focused tests use owned temporary files, injected read/atomic-write failures,
fake provider/clipboard seams, real Hub actions, production save-effect handling
and real menu composition. They do not launch the app, touch the live clipboard,
load models or call providers. Native window layout, AX delivery, actual clipboard
integration, menu navigation and visible HUD timing still require native manual
qualification.

## Retry original cleanup (B06)

A saved History row offers **Review Retry Cleanup**, or **Review Selected Preset**
for an intentional transform. Review shows the immutable Original and Previous
result and freezes the chosen current global settings/environment for this
request. Provider, endpoint origin only, model (or server choice), style,
recognition language, and vocabulary/rule counts are shown. Original request
settings and app/site context are unknown; today's frontmost app is never used.
Ordinary retry always means non-translating cleanup, regardless of dictation's
current raw/preset mode. Intentional records cannot replay historical spoken
instructions or reconstruct a preset from metadata: explicitly review the current
selected preset's name, instruction and target, then apply it to Original.

**Request Ordinary Cleanup** / **Apply Selected Preset to Original** starts the
text operation. It cannot record, transcribe, load an ASR model or insert text.
Exact snippets remain locked and literal rules use the shared Pipeline semantics.
Cleanup off/unconfigured runs local rules only and says no provider ran; an
intentional preset instead refuses before constructing a provider. Configured
provider errors require a deliberate new request; there is no provider fallback
or warm request. Empty/invalid provider output is not offered as a result.

Successful output stays in memory as **Proposed result**, alongside Original and
Previous result, until quit or Discard. Copy each version explicitly. **Apply
Result** changes the existing row only after review; it preserves ID, original
text/date/app and initial metrics/operation. **Retry Save** retries the exact same
returned text with no HTTP/ASR work. Failed updates keep prior committed bytes and
never become pending new rows. Deletion, clearing, eviction, another update or an
external reload changing the file invalidates the preview's save permission.
Stale results may only be copied. Discard and superseding requests invalidate late
completions. No retry path restores missing rows or pastes into another app.

History off permits temporary preview/Copy and disables Save. Enabling history
allows explicit saving of the retained result without another request. Settings
load/save errors block new requests and saving until repaired/reloaded; existing
text and previews remain available to Copy. History read errors require Retry
Load before saving. Existing capture-latched history policy is unchanged.

Explicit saved results include safe retry provenance and operation-owned usage;
credentials, environment, headers and full endpoint URLs are never serialized.
The vocabulary/rule/intent digest and safe fields support limited comparison only:
omitted credentials and endpoint paths cannot establish exact equivalence. Legacy
original provenance remains unknown. Initial dictation metrics are preserved.
The existing cost estimate covers original dictation requests in retained rows
only and explicitly excludes all retry requests, including failed/unsaved ones.
