# Discard pending output

While a dictation, spoken transform, or saved-selection transform is processing,
open the native status menu and choose **Discard pending …**. The item names the
actual operation and its stage; the token stays attached through cleanup rather
than being inferred from the current recording generation. The menu shows
**Discarded — stopping work…** until that operation exits.

Stop finishes a recording. Capture Cancel drops that capture. Idle Esc dismisses
a toast. Discard pending explicitly rejects that operation's remaining output:
these actions are separate. Starting another capture does not implicitly discard
older raw text or its deliberately retained history behavior.

Discard revokes insertion and history permission synchronously, including old
callbacks and cleanup's raw fallback, before requesting cooperative native/HTTP
cancellation. The serial recognition queue still waits for actual exit. Native
abort responsiveness and network cancellation latency are not instantaneous or
qualified by the fake tests. Already posted OS events cannot be recalled. If delivery
was already attempted, feedback says so; Discard does not undo text or delete
saved history.

Main dictation discard explicitly disposes of that operation's recovery WAV and
paired corpus hypothesis, including when corpus collection is enabled. Failed
recognition's `resolve(nil)` still retains audio; it is not Discard. Audio retention
off produces no stash. Write/deletion failures remain reported by the recording
store and Recovery page; a failed delete is not claimed to have removed the file.
Disposal uses capture ownership and refuses replaced files or another operation's
lease. Secure-field refusal keeps its stronger purge policy.

History retry has its own **Cancel and discard** button, token and cancelable
request task. Re-preparing a row cancels its previous request; another request for
that row cannot start until the previous one exits. Late results cannot resurrect
the preview or be saved. Other rows continue independently.

Recovery has its own **Cancel transcription** / **Discard preview** control.
Cancellation invalidates preview/Save, releases its lease, then requests abort.
The original recovery source is retained when still available: Cancel is not
Delete. A canceled transcription must exit before another starts. Existing
successful recovery still disposes of audio by default before explicit text Save.
Unrelated dictation, history retry, playback and downloads are not canceled.

Model-free tests exercise the production reducer, serial queue, recognition passes,
finalization/transform boundary, Hub methods, owned disposal, and menu composition.
Real Whisper abort responsiveness, URLSession latency and OS dispatch remain
pending native/hardware validation.
