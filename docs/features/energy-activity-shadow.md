# Energy/activity shadow (B17.1, partial)

One global saved switch is off by default and absent in old settings. It applies
only to future physical keyboard/mouse/hands-free ordinary dictations, with no
live typing or selected preset. Profiles, automation, commands, preview/stream
passes, history/recovery retries, tryouts, setup and B57 do not enable it.

The ordinary finalizer preserves stash → actual preparation → final recognition.
After acquiring the actual final handle, it synchronously borrows original stopped
16 kHz mono Float32 PCM before the unchanged ASR floor. It never changes PCM,
requests, windows, floors, prompts, cleanup, snippets, output, history or recording
policy. All suggestions are **NOT APPLIED**. Energy is not speech proof; accuracy,
latency and resource benefits are unqualified. No extra model or decode is used.

Revision 1 visits at most 9,600,000 samples once, in 320-sample frames (actual
partial denominator), accumulating Double mean and centered power. Empty or
oversized input abstains without a clipped-prefix scan. Nonfinite, clipped
(abs ≥ 1), out-of-scale, DC-dominated (mean² ≥ centered power), subnumeric or
inconsistent arithmetic abstains for the whole comparison. Tiny negative centered
power within 8 Double epsilons of the larger square term clamps to zero and records
a rounding flag; material negative values abstain. Only finite nonempty exact
digital zero may suggest wouldRejectProxy, never human speech absence.

One power array (≤30,000 Doubles) and 128 Int histogram bins have ≤241,024 bytes of
declared payload on 64-bit systems. This is not measured process RAM/allocation.
Bins use floor((log2(power)+48)*128/48), index-clamped 0…127, with zero in bin 0.
Exact bin boundaries enter the upper bin. Noise reference is the upper edge of
the first bin reaching ceil(frameCount/5), bounded below by 2^-48, over the whole
clip. High ≥4× reference anchors activity; low ≥2× is possible activity and extends
the first/last envelope even without its own high anchor. Hysteresis ends below
low. Isolated anchors remain; >128 runs abstains. Nonzero without a high anchor
abstains as low contrast. All internal gaps remain in one envelope.

Padding is 4,000 samples each side; an edge is suggested only when ≥8,000 samples
remain removable after padding, otherwise that side stays full. Short clips
(<6,400) never propose trimming. Suggested retained length must be ≥6,400.
Each feature/classification frame and bounded phase polls abort, permission and a
finite monotonic clock. The fixed 50 ms logical elapsed budget abstains on expiry;
it is cooperative, with no guaranteed preemption or ten-minute completion claim.
There is no retry, DSP task, worker, queue or tuning.

Start permission contains only revision, generation, operation identity and a
revocable scalar. Normal stop preserves it. Cancel/discard, a successor capture,
draft/saved invalidation, secure evidence and quit/restart revoke it permanently;
reenabling cannot revive the old capture. The existing processTask child and
actual-exit barrier own all analysis and native work, including held test bottoms.

A structured observer projects actual final provenance immediately: full pass,
owned prefix/tail assembly (including skipped/failed tail), full-floor skip,
canceled/unavailable, native outcome, selected-text presence and actual preview
branch. No text/result/native identity is retained. Pending facts stay inside the
ordinary wrapper until the existing landing/completion security adjudication,
including nil raw. Secure evidence erases them. Only current, nonrevoked,
adjudicated work publishes once on main after the awaited body returns.

The optional finite typed fact is validated and ≤2,048 UTF-8 bytes. Invalid producer
data becomes noDecision/invalidResult with no suggested ranges. Known incomplete
capture scalar evidence abstains. Diagnostics clear/prune never reinserts a record.
The existing Prepare Review freezes JSON; export remains explicit. No automatic
export, audio retention, research corpus, or speech/hallucination correctness badge
is introduced. Existing whole-export operation IDs remain unchanged.

B17 remains PARTIAL; count 22 is unchanged. Before ANY active behavior, separately
require consent and policy authorization, human-labelled paired false rejection
and hallucination evaluation with quiet onsets, short words and code-switching,
explicit attempted/analyzed/abstained/excluded and speech/non-speech denominators,
coverage and uncertainty, original-vs-candidate native quality/latency qualification,
old-OS/Intel qualification, and review of failures. Synthetic arithmetic and fake
native-bottom tests cannot establish human accuracy or counterfactual benefit.
