# Lane 06 — Linux hardware qualification checklist (human)

Wave 1 · Risk: Low (documentation only) · Depends on: nothing

## Goal

`linux/VERIFY.md` says the Linux milestone has never run on Linux. Turn it into a checklist a
person can execute and sign, with a place to record results, so lanes 09 and 11 land on a
qualified baseline instead of on unverified code. This lane writes no code and claims no result.

## Files owned

- `linux/VERIFY.md`

## Current document

Eight ordered sections (clipboard, clipboard lifetime, notifications, cleanup failure, build,
hotkey, microphone, model) plus "Known and accepted". Prose only; no pass/fail record, no
environment record, no capture-rate or callback-size observation.

## Design

Restructure, keep every existing check and its reasoning, add what later lanes need.

1. **Run record** at the top (empty table to fill): date, tester, distro and version, compositor,
   audio server and version (PipeWire / PulseAudio / plain ALSA), microphone model and connection,
   `parlad` commit, model file and its sha256, notifier.
2. **Each existing section becomes a checkbox item** with: exact command(s), expected observation,
   a `Result:` line (pass / fail / not run) and a `Notes:` line. Do not pre-tick anything.
3. **New baseline items** (observations only, needed by lanes 09 and 11):
   - [ ] Device default configuration: record sample rate, channel count and sample format the
         daemon opened (add nothing to the code here; if the daemon does not log it, record
         `pw-top` / `pactl list sources` output and note that lane 11 adds a startup log line).
   - [ ] Duration fidelity: dictate a timed 10.0 s clip; record the daemon's
         `transcribing N.Ns of audio`. Record the difference. (Callback-local resampling can
         shorten it; this is the "before" number for lane 11.)
   - [ ] Two quick dictations: dictate A, and start B before A's notification appears. Record which
         text is on the clipboard at the end and whether both notifications appeared. ("Before"
         for lane 09.)
   - [ ] Cancel after release: release the key, then immediately `parlactl cancel`. Record whether
         the text still reaches the clipboard. ("Before" for lane 09.)
   - [ ] Multilingual model: with a multilingual ggml model configured, speak a non-English
         sentence. Record the output. ("Before" for lane 09's language setting.)
4. **Placeholders** for the "after" checks that lanes 09 and 11 append (headings only, marked
   "added by lane 09 / lane 11").
5. **Sign-off block**: who ran it, on which run record, which items failed, and whether lanes 09 and
   11 may proceed.
6. Keep "Known and accepted" as is.

## Acceptance criteria

- Every check from the current file is still present, as a checkbox with command, expectation and
  a blank result line.
- No item is ticked and no result is filled in.
- The five new baseline items exist with the exact observation to record.
- Markdown renders (no broken lists or tables).

## Checks to run

- Read-through only. No commands.

## Out of scope

- Any code change, including logging. Running the checklist. Automating it.

## Needs a human

- [ ] A person with a wlroots Linux machine runs the checklist once on `main` **before** lanes 09
      and 11 are merged, fills in the run record, and signs off.
- [ ] Ideally repeat on a second audio stack (PipeWire and PulseAudio) and one USB microphone.

If no Linux hardware is available, lanes 09 and 11 can still be implemented and unit-tested, but
they must be reported as unqualified and should not be released.
