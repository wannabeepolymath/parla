# Polish button — design

2026-07-17. Wispr-Flow-style polish: fix a selection's spelling, punctuation,
capitalization, and grammar with one click — no speaking. Command mode
without the spoken command.

Revised same day: originally hotkey-triggered (⇧+fn quick tap / ⌃⌘P); the
owner wants an explicit button and nothing automatic — polish must run only
on a deliberate click. Both hotkeys were removed.

## Trigger (button only)

Hovering the idle pill morphs it into a **✦ Polish** chip; clicking runs the
polish. The panel is non-activating, so the click never steals focus — the
front app's selection is captured at the click. On side docks the chip grows
inward (never off-screen). Any state change (dictation start, drag, toast)
hides the button; it reappears on the next hover while idle. The button lives
on the always-on idle pill, so it requires `showHudAlways` (the default).

No hotkey exists and nothing triggers polish automatically. Short ⇧+fn taps
stay discarded as accidental, exactly as before.

## Flow

Reuses the command-mode transform path with a **built-in instruction**
(`Polish.instruction` in ParlaCore): proofread only — fix spelling,
punctuation, capitalization, grammar; preserve the writer's voice, tone,
wording, meaning, language, and formatting; return unchanged text when nothing
needs fixing. The instruction rides the existing injection-hardened transform
prompt (the selection stays data, never instructions). Dictionary spellings
apply; snippets and app-tone do not. No whisper pass — polish works even with
no model downloaded.

Inherited safety, shared with transforms via an extracted
`applySelectionEdit` helper:

- password fields refuse before anything runs, and again at insert time
- the selection is re-verified before replacing; changed selection → result
  parked in history (or honestly discarded when history is off)
- stale generation → no keystrokes
- empty results and results over the 6× length ceiling are hard failures —
  nothing typed
- terminal newline flattening applies to what is typed

New in the shared helper (both polish and spoken transforms benefit):

- **no-change detection** — result identical to the selection shows
  "✓ No changes" and types nothing
- **modifier wait** — a modifier (⇧+fn's shift after a transform) may still
  be held when the LLM returns; insertion waits (~1s max, 50ms steps) for a
  clean keyboard, like paste-last does, then re-verifies and types.
  Timeout → parked in history.

## HUD

`Polishing…` while in flight → `✓ Pasted` / `✓ No changes` / `✓ Saved to
history` / error toast (`Cleanup not configured`, `Polish failed`,
`Select text first`, `No transforms in password fields`).

## Settings

None. Uses the configured cleanup provider; unconfigured cleanup fails fast
with a toast.

## Tests

CleanupTests pin the polish instruction's contract (proofread-only,
voice-preserving, routed through the transform prompt with the selection
delimited as data). The button and hover morph are AppKit UI in the app
target, outside the unit-tested core — verified by hand, like the rest of
the HUD.
