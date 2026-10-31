# Manual diagnostics

In Hub → Data & Privacy → Diagnostics, choose **Prepare Review** to freeze a
locally visible JSON snapshot. **Export JSON…** opens a save panel only for that
review. Cancel writes nothing; a failed write retains the same review for retry.
Later operations are excluded. Settings, history and recording destinations,
including aliases and live outward recording links, are protected by the same
validation used for transcript exports. The writer uses an explicit atomic write.

Diagnostics are independent of History. Up to 64 recent operations, including
active operations, fit within a 128 KiB encoded snapshot. Oldest records are
pruned even when work remains active. **Clear RAM** removes the collection and
review; callbacks from cleared/pruned operations cannot restore records. Quit
clears both. Nothing automatically uploads or writes a diagnostic log. Exported
files remain until you delete them. Opening or exporting diagnostics starts no
capture, recognition or provider request.

The JSON is an allowlist: schema and numeric app/OS versions; random operation
ID and enum origin; capture/deadline/route evidence; ASR/provider/delivery outcomes;
cancellation and operation-finished flags; fixed catalog model enums; receipt and
stale-completion flags; enum reasons; bounded aggregate timing counts and numbers.
It contains no transcript, selection, field, audio, snippet, vocabulary, key,
header, environment, path, endpoint, app/site label, preset name or device label.
Unknown/custom model labels are `unavailable`, even when syntactically harmless.
Only exact supported catalog identifiers are emitted; ASR catalog labels identify
the handle's catalog-named file, not a new verification of its bytes.

Each timing uses a monotonic clock and operation-relative milliseconds. Queue
wait is distinct from acquisition. Capture setup wraps start; the first PCM time
is observed at tap entry, excluding warm pre-roll. The two-second first-PCM
deadline only observes: it does not stop or cancel recording. Capture stop records
signal/minimum-duration/conversion/device-loss evidence independently of that
deadline. Route type comes from a read of the actual input audio unit, never from
the requested device UID. Failed route reads remain unknown.

ASR spans wrap actual RecognitionClient calls. Silence/minimum duration and a
confirmed-window-only final are distinct from calls returning empty/nil. The
RecognitionClient contract cannot distinguish nil due to a backend error from
other nil results; `nilOrError` makes that limit explicit. Provider setup wraps
factory/credential acquisition. `provider` wraps the provider invocation;
`providerRequest` wraps each actual awaited HTTP request, including model discovery.
`providerRequestAttempted` is set at that boundary, independently of refusal,
failure, cancellation or invalid results. Inert provider fakes use their request
method boundary. Frozen model settings, the actual requested model, and an
explicit response model are separate; legacy usage fallbacks do not invent a
resolved response model. Cleanup includes local policy and validation; it precedes
paste in the normal pending-delivery flow. Repeated spans aggregate counts and
total elapsed time, with first start/last end and active counts. These are not
CPU times. Cancellation requested is distinct from `operationFinished`, which is
set only at the existing operation token’s finish boundary (also used for a
refused retry that never queues).

Delivery is separate from provider/text outcomes. A paste Bool records
`postedUnverified` or refusal. The existing AX tail replacement can record
`axConfirmed` only on its positive read-back branch; an issued but unverified AX
write is separate. Keyboard fallback records actual event posting. A receipt
alone cannot promote insertion; no receipt experiment is enabled. Stale, secure,
changed-destination, selection and modifier refusals remain metadata and preserve
existing output/HUD authority. Retry and recovery have independent origins and
remain preview-only. Existing History Codable, usage/cost metrics and Trace's
PARLA_TRACE gate are unchanged. History insertMs/cleanupMs remain legacy intervals;
cleanedSwapped and transform completion never prove insertion.

Model-free tests establish software wiring, privacy and ownership. Physical mic
routing, native panels, Keychain, provider latency and third-party AX/paste
acceptance remain separately unqualified.

Apple Intelligence uses finite on-device provider/model labels. `localGenerationAttempted` is observed at the session response boundary, separately from `providerRequestAttempted`, which stays false for the local adapter. Optional finite local refusal reasons contain no source, instructions, locale text, framework context or refusal explanations. Token counts/cost stay unknown. Legacy diagnostic rows decode without the optional local fields. Source tests inject the native bottom; no real generation/offline/device qualification is implied.
