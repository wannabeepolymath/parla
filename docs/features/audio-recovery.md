# Failed audio recovery (wave 2C.4)

Data & Privacy independently controls **Keep failed audio** (default on) and
**Audio lifetime** (1–30 days, default 7). Turning it off stops new disk stashes,
including `PARLA_KEEP_RECORDINGS=1` corpus collection. Existing inactive files
remain explicitly playable, transcribable and deletable under the valid lifetime
policy. This control does not alter text history or its count limit. Deleting a
text row, count eviction and Clear history remove text only; no recording links
are inferred from timestamps.

Ordinary successful recognition deletes its audio as soon as raw text exists,
even if later delivery, cleanup or text persistence fails. Failed recognition
retains recovery audio. Secure-field resolution outranks every retention/corpus
rule and revokes active recovery use before attempting removal. Deletion is a
logical filesystem operation, not a forensic-erasure guarantee. Failed writes,
reads, expiration, removal and corpus-sidecar writes have visible, conservative
status; recovery failures do not fail ordinary dictation. The latest storage
error stays visible for the app session, and repeated identical failures do not
create refresh-notification loops.

The production store starts with **no authorized policy**. Only a valid settings
load enables stashes and expiration. Missing settings means valid defaults;
invalid/unreadable settings never authorize guessed retention or destructive
pruning. Existing files remain visible with a policy-unavailable reason. Once a
valid policy is known, later settings errors preserve that policy and show a
warning. Transcription and explicit text Save still require repaired, reloaded
current settings. Manual deletion of safely owned inactive files remains
available. Valid policy sweeps occur at launch, refresh, stash and actions. A file
expires only when its modification date is **strictly older** than the lifetime;
equality remains eligible. Modification dates preserve the existing expiration
contract and do not establish historical speech time or app context.

## Local files and ownership

The failed list shows stable local filename IDs, modification date, expiry,
bytes, header-derived duration and unavailable reasons. Listing opens audio
headers only; it does not decode all recordings. Actionable input must be a
regular, nonsymlink WAV immediately inside the injected recording directory,
PCM, nonempty, at most 128 MiB and at most 20 minutes. Missing, corrupt, unsupported,
changed or expired input cannot be used. Symlinks and other invalid leaves can
be deleted safely without following their targets; directories and outside paths
are refused. A recordings root replaced by a symlink is refused. Existing parent
aliases such as macOS `/var` are supported without splitting lease identity.
This is process-owned serialization, not an interprocess lock or a guarantee
against hostile filesystem replacement between checks.

Capture ownership is registered **before writing**, and held through ASR
resolution. A failed recognition must call `resolve(..., transcript: nil, ...)`
to end ownership; silence/no model is still a resolution. The earlier tests now
explicitly resolve their stashes before ordinary prune/clear/summary assertions.
A durable `.wav.partial` marker prevents an unfinished/failed write from being
offered as viable after a crash or unsuccessful cleanup. The marker is removed
only after a completed, validated WAV write. Clear also manages orphaned owned
hypothesis/unfinished markers. Paired `.hyp.txt` sidecars are removed with their
recording, and partial removal is reported as failure.

Active capture, transcription and playback are excluded from ordinary listings,
summary, expiration, delete and clear. Busy acquisitions/deletes report refusal;
bulk Clear reports removed/busy/failed counts and skips other ownership. Recovery
acquires an exclusive lease and checks identity, policy, expiry and format again
at action time and queued use, before model acquisition/use. Secure revocation
stops owned playback and aborts/rejects revoked transcription use before purge.

Explicit corpus mode can preserve successful audio with its existing `.hyp.txt`
marker while recovery audio remains enabled. Marked successes are excluded from
the **failed** list, but included in inactive totals and Clear. Legacy files whose
markers are missing cannot be classified perfectly. No new default retention of
successful audio is introduced.

## Explicit playback and local transcription

**Play** creates one short-lived local player; playback never starts automatically.
**Stop**, completion, decode/start failure, deleting the playing file, leaving
Privacy, closing the Hub window, deinitialization and termination stop/release it.
Delete during owned playback first stops it; another active owner's file remains
protected. Tests inject a fake player and never emit real audio.

**Transcribe locally** freezes the current **global** RecognitionRequest: exact
model path, language and vocabulary. Historical app/site context is unknown and
is disclosed; historical profile rules are not reconstructed. The request joins
AppDelegate's existing `processTask` chain, retains the same RecognitionHandle
through use, loads through the existing audio loader and uses final-recognition
minimum-audio semantics. Nonviable, silent and short audio never load a model.
An unavailable requested model gives an error with no implicit download or
wrong-model fallback. Current settings and file viability are checked again
after queue wait and before use. There is no insertion/selection access, cleanup
provider, cloud request or shared-model reentrancy.

Raw text returns to an in-memory preview before audio disposal and independently
of history storage. **Copy** is explicit. **Save raw text / Retry Save** is disk-only
and reuses the same result, ID and model metadata, without another ASR pass or
fabricated cleanup/provenance/usage fields. History off allows preview/Copy;
enabling it permits explicit Save of that same result. Settings/history load
errors do not authorize overwriting fallback state. The saved raw row can later
use the existing explicitly reviewed text retry. Unsaved previews disappear on
discard or quit. Closing the window retains text preview, but stops playback.

## Qualification

Owned-temp WAV fixtures, fake recognition clients/queue acquisition, fake players
and disk faults cover the production queue/store/Hub seams without models,
providers, audio output or insertion. Actual native rendering, playback devices,
window/page interaction, crash/relaunch observation, interruptions, secure-focus
AX flow, disk permissions and real ASR accuracy remain manual qualification.
