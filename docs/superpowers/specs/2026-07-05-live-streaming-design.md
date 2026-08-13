# Live Streaming Dictation — Design

> **SUPERSEDED — kept as a record.** Two load-bearing parts of this spec do not
> ship. (1) Typing into the field while fn is held is hard-disabled:
> `liveTyping` is assigned `false` on both dictation entry paths
> (`Sources/Parla/main.swift:157`, `:213`) because keystrokes posted while the
> user physically holds fn merge with the modifier — fn+A opens the Dock, ⇧←
> becomes select-to-Home. The transcript lands as one insert at fn-up, after
> the modifier is released. (2) "Clipboard always ends up holding the final
> text" is false — the clipboard was removed from the insertion path entirely;
> `Inserter.insert` posts Unicode keystrokes and the pasteboard is never read
> or written during dictation. What survives is shadow streaming: the pass loop
> still runs during speech to build a confirmed prefix so fn-up only pays for
> the tail, but the field is never touched mid-utterance. Current behavior is
> documented in README, "Shadow streaming". The body below is the original
> design, unedited.

Approved by user 2026-07-05 ("text should real time stream into the textbox").

## Goal

While fn is held, text streams into the focused text field in near-real-time.
Corrections (whisper revising earlier words; LLM cleanup trimming fillers /
self-corrections) erase the already-typed wrong tail via synthetic backspaces
and retype. If no editable field has focus, nothing is typed; final text goes
to the clipboard only.

## Design

**Diff engine (ParlaCore, pure, tested).** `LiveTyper.diff(typed:new:)` →
`(erase: Int, append: String)`: longest common prefix by grapheme cluster
(backspace deletes one grapheme in AppKit text views), erase = typed suffix
length, append = new suffix.

**Typing primitives (Inserter).** Existing `typeUnicode` for appends; new
`typeBackspaces(_ n:)` posting kVK_Delete (51) down/up events. New
`focusedElementIsEditable() -> Bool` via AX: focused element role in
{AXTextField, AXTextArea, AXSearchField} or has a settable AXValue /
AXSelectedTextRange. Unknown/no element → false.

**Streaming loop (app).** On fn down: check editability once; start a
self-pacing background task — snapshot recorder samples (`AudioRecorder.
snapshot()`), transcribe full buffer (initial_prompt from dictionary), diff
against what's typed, erase+append on main thread, ~0.3s pause, repeat.
Self-pacing (next pass starts after previous ends) instead of a timer, so slow
ASR never queues. Whisper ctx is not reentrant: partial passes and the final
pass run on the same serialized task chain.

**Finalize (fn up).** Stop loop (await in-flight pass), final transcribe +
LLM cleanup. Live mode: erase all typed graphemes, paste final text via
existing clipboard+⌘V insert. Non-live: final text to clipboard only (no ⌘V).
Cleanup failure → raw transcript, same replace flow. Clipboard always ends up
holding the final text.

**HUD.** Unchanged states; streaming happens under it.

## Constraints / accepted risks

- User must not click or move the cursor mid-dictation — backspaces land at
  the cursor. Documented in README.
- Full-buffer re-transcription is O(n²) over utterance length — fine for
  short dictations (ponytail ceiling comment; window later if needed).
- AX heuristic is best-effort; unknown ⇒ clipboard-only (never type into
  non-text contexts, keystrokes could trigger shortcuts).

## Testing

Unit: diff (prefix/revision/emoji-grapheme/empty cases), snapshot under lock.
Manual: live typing, mid-word revision, cleanup trim replacing typed tail,
no-focus → clipboard only.
