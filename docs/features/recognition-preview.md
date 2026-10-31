# Speculative HUD preview experiment (B56.1)

Off by default. A saved global `recognitionPreviewModelID` and the saved
`streamPreviewEnabled` switch must both be enabled. A nil ID or disabled switch
keeps the existing same-final-model HUD/shadow-window path. The final model still
comes from the frozen global/start-profile request; there is no profile preview
setting. The selector shows installed catalog choices and preserves unavailable
saved selections. Rendering, draft edits and preview-only saves do not acquire,
prepare, hash or download models. Failed saves cannot enable the experiment.

The experiment applies to ordinary physical keyboard/mouse/hands-free dictation
with live typing off and capture-time output mode other than selected preset.
Both roles must be owned installed catalog Whisper choices. Custom, invalid,
Apple Speech and Parakeet final requests keep their actual final engine and get a
nonfatal preview refusal. Missing, damaged, incompatible or refused previews do
not select another model. English-only previews refuse pinned non-English;
auto-language previews using those choices remain explicitly English-only.

Preview uses the same recorder: an operation-checked copied suffix under its
lock, latest 15 seconds / 240,000 Float32 samples, at least 16,000 new samples and
one second between application request starts, one awaited pass, zero queued
snapshots and at most 600 application requests per capture. After a slow pass it
reads the latest suffix. The display retains at most a 4,096-byte UTF-8 suffix;
the independently frozen dictionary prompt retains the existing 2,048-byte cap.
There is no accumulated preview transcript or previous-draft prompt.

All native work stays on the existing processTask lane. Stale resident/session
aliases are released after prior work exits and before preview construction.
Preview ownership stays capture-local. Stop revokes its publication phase,
awaits actual constructor/decode exit and destroys preview ownership. Ordinary
finalization stashes original audio before independently acquiring a fresh final
recognizer, even for equal model IDs. Final uses original full PCM and nil
StreamWindow. Preview never supplies raw/final/cleanup/history/recovery/Original
Copy/clipboard/insertion/result text or final ASR diagnostics. No fallback uses a
draft. Profile-only final ownership and existing promotion guards remain in force.

Stop, cancel, successor capture, settings drafts, safe-start revocation, secure
evidence and quit/restart invalidate old HUD authority. Secure evidence uses the
existing port without collecting field text and prevents revival for that
capture. Quit/restart revoke before existing participant drains, including when
quit is canceled. Operation cancellation still revokes before abort and never
cancels the serial barrier. B57 receives only its existing original owned PCM and
keeps its independent fresh/read-only/raw-only rules.

These application bounds do not bound native memory, native retries or GPU/OS
reclamation. Capture's existing 600-second / 9,600,000-sample limit is unchanged.
Extra model loads can increase stop-to-final latency. No speed, memory or quality
benefit is claimed. Optional engine, release and terms gates remain closed.

B56 remains PARTIAL: model-free source tests are separate from later authorized
native/human paired preview latency, final stop latency, quality, peak memory,
old/current OS, Intel/Apple Silicon, offline and real secure-field/delivery
qualification. There is no default promotion or source-approval/count credit.
