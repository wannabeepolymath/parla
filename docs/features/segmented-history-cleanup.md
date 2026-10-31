# Experimental saved-Original segmented cleanup

A separate saved ordinary-row action prepares a frozen review. Explicit Start
requests ordinary cleanup of the saved Original, regardless of dictation output
mode. The existing whole-text and preset actions remain the default. This is a
manual after-stop experiment, not while-recording incremental cleanup.

Prepare reads valid saved settings without credential/environment/native/network
admission. Missing, corrupt or unreadable settings refuse before pending edits
can repair the observed state. Pending settings edits block experimental review,
Start and Save until the normal save succeeds. Retry explicitly afterward;
the experiment never flushes settings or automatically starts when saving finishes.
The review binds exact Original, row version,
provider, destination, model, style, language and rules. Start authorizes access
once, then uses one provider instance for sequential independent requests.

Original is limited to 64 KiB, previous result to 128 KiB, and configured rule
text to 64 KiB/256 entries per category. Generation requires 2–16 segments with
at most 4096 UTF-8 content bytes each, preserving Character boundaries and exact
separators. Unbroken oversized tokens/graphemes refuse. Prefer whole-text review
for one segment. Whole-Original snippet locks win exactly with zero requests;
other snippet configurations refuse generation in v1. Disabled/unconfigured
cleanup applies whole-Original literal rules once with zero requests.

Network requests require an explicit compatible model and a callback-bounded,
ephemeral transport. Framed prompts are at most 16 KiB, serialized bodies 128 KiB,
received aggregate headers 16 KiB, received bodies 256 KiB before JSON, accepted
segments 16 KiB and final results 128 KiB. Retained experimental payload accounting
is capped at 1 MiB; this does not bound process RSS, Foundation pre-callback
buffers/allocations or native model memory. No redirects, discovery, automatic
application retry, alternative provider or whole-text fallback runs.

Local requests additionally preflight the whole Original (at most 8192 bytes)
and every segment with existing language, rule and prompt checks before any
generation. Readiness is checked again for each fresh native session.

One monotonic 60-second acceptance deadline starts at Start, including validation,
queue wait and setup; each call remains capped at the remaining time or 15 seconds.
Cancellation/deadline revokes acceptance but retains the operation until actual
worker/transport exit and joined teardown. An uncooperative native worker can
keep the slot and quit waiting indefinitely. Remote cancellation acknowledgement
and provider-internal retransmission behavior are not guaranteed.

Only counts are shown during work. Every segment must sanitize/validate, exact
separators must be restored, and the complete assembly must pass whole-source
guards before bounded literal replacement runs once. Any failure leaves no
saveable proposal. These guards cannot establish semantic preservation across
boundaries. Separate requests can miss self-corrections, negation, quantities,
list/email structure or other shared context, and can increase total work.

The review displays full Original, previous result and complete proposal. Copy
writes only explicitly selected text. Save reviewed result conditionally updates
the same unchanged saved row; Original and initial metadata are preserved.
Retry Save stores the identical retained result without another generation or
access resolution. Changed/deleted/read-blocked rows remain Copy-only. No
partial text export, clipboard insertion, field delivery, learning or audio
retention change is added. Diagnostics retain finite counts/categories only.

Source tests use scripted HTTP callbacks/native bottoms. They do not qualify real
providers/native readiness, semantic equivalence, quality, cost, latency, native
memory or while-recording consent. B30 remains PARTIAL; reviewed count remains 22.
