# Parla — Reported Issues Log

User-reported issues, their root causes, and current status. (2026-07-05, updated 2026-07-10)

## 1. "I am not able to use the app. I wrote the key in .env" — FIXED
The app never reads `.env`, and GUI apps don't inherit shell env vars.
Groq key + provider block written into `~/Library/Application Support/Parla/settings.json`.
Verified live: Groq answers with our exact request shape; eval passes 2/2.

## 2. Move hotkey from Right Option to fn/Globe — FIXED
HotkeyMonitor now watches keyCode 63 + `.function` flag. Confirmed firing
(fn down/up in logs from real keypresses).

## 3. "There should be some UI when I use the app" — FIXED
Floating HUD pill: Listening… + live waveform (driven by real mic RMS levels,
no mock), Cleaning…, ✓ Pasted / ✓ In clipboard / error states. Confirmed on
screen.

## 4. Permissions repeatedly "not working" after every fix — FIXED (root cause)
`make-app.sh` signed ad-hoc → new code hash every rebuild → macOS silently
invalidated Mic/Accessibility grants each time we shipped anything.
Now signs with a stable designated requirement (`identifier "com.parla.app"`);
verified identical across rebuilds. Grants survive rebuilds from now on.

## 5. Text not streaming in real time into the focused textbox — FIXED
- Works: streaming appends in real time (~1 word/second cadence, verified in
  logs and on screen in user's session 20:47).
- Root causes found and fixed along the way: focus detection said "none" in
  Electron/web apps (added app-level AX fallback + accessibility wake-up
  flags); whisper `[BLANK_AUDIO]` hallucination markers were typed as text
  (now stripped).
- RESOLVED by the instant-finalize rework (2026-07-08): fn-up now lands the
  raw transcript immediately through the same verified paths used for
  streaming — AX-verified erase+retype, select-back-and-verify for AX-opaque
  fields, or clipboard fallback only when neither can be proven safe. The
  cleaned version then swaps in behind it with its own verification, so a
  chat box that used to stop updating mid-stream now always ends with either
  the raw or cleaned text landed and verified in the box, or a distinct HUD
  state ("✓ cleaned in clipboard") when it genuinely couldn't be proven safe
  to touch the field again.

## 6. "It removed text that it didn't write" — FIXED (with a trade-off)
Blind backspace counts could eat pre-existing text when the app dropped a
synthetic keystroke or autocorrected. Now every erase is verified first:
- AX path: read the field's text+cursor, erase only if the tail exactly
  matches what Parla typed.
- Opaque fields: select-back (⇧←×N) + ⌘C + compare; replacement types over
  the verified selection only.
- If neither verifies: never delete — append-only streaming, final to
  clipboard.
Guarantee now: Parla cannot delete text it didn't write.

## 7. "Now it only writes to the clipboard" — ROOT CAUSE FOUND, PATCHED
Reproduced from `/tmp/parla-stderr5.log`: live append worked, but finalization
logged `finish path: unverified, clipboard only` even though `focus=1`. Root
cause: Parla enabled live streaming for fields that merely looked editable via
AX, but whose text/cursor could not be read back for safe final replacement.
That created a bad state: draft text had already streamed into the box, cleanup
could not verify what to replace, and the safety fallback copied to clipboard.
Patch: live streaming now starts only when final replacement is AX-verifiable;
opaque focused text boxes skip streaming and use the final focused paste path.
Clipboard-only is reserved for no focused element.

## 8. "No option to leave hands-free mode and get the output" — FIXED
Hands-free (fn+Space) could only be stopped by a second fn+Space, which
depended on the Space keyDown carrying the fn modifier flag — and nothing in
the UI documented the exit, so Esc (cancel, output discarded) looked like the
only way out. Fix: any fn press during hands-free stops and transcribes, via
the same flagsChanged detection push-to-talk uses; the stop-chord's Space is
swallowed so it can't leak or restart a session. Tray menu and Hub now state
the exit ("fn 🌐 stops").

## 2026-08-11 changes
- All 29 items of the open-source audit backlog (`docs/research/FEATURES-TO-ADD.md`)
  are implemented on `feat/audit-implementation`, followed by four adversarial
  review rounds — 63 findings, 49 confirmed and fixed, 14 refuted. Per-item detail
  lives in `progress.md`; the findings and their verdicts in
  `docs/research/11-review-findings.md`. Not repeated here.
- What touches this log directly: hotkeys are now rebindable (retires next step 5
  below); secure event input is detected before typing and refuses the dictation
  instead of typing into a void; the typing chunk went 20 → 200 UTF-16 units with
  a 1ms inter-chunk sleep (erase still 5ms — issue 6 is the erase path).
- Two things still need a human, both recorded below: a GUI session for
  `parla-insert-check`, and an Anthropic key for the Haiku-vs-Sonnet cleanup A/B.

## 2026-07-10 changes
- Clipboard removed entirely (supersedes the clipboard-fallback mentions in
  issues 5–7 and the improvements below): Inserter types via CGEvent Unicode
  keystrokes; every unverifiable delivery goes to local history instead of the
  pasteboard; password fields are refused at fn-down with a toast. The only
  remaining pasteboard write is the Hub's explicit Copy button.
- Hotkeys moved from NSEvent global monitors to a CGEventTap (same
  Accessibility permission) so chords can be swallowed instead of leaking into
  the front app; tap creation retries until the permission is granted.
- New shortcuts: fn+Space hands-free (latch while holding fn, fn stops, pop +
  "Hands-free…" pill on latch), Esc cancels dictation / dismisses the HUD
  toast, ⌃⌘V pastes the last transcript, ⌃⌘S opens the Scratchpad. All listed
  in the Hub shortcuts card and tray menu.
- Scratchpad: persistent plain-text window (Application
  Support/Parla/scratchpad.txt, debounced saves) — a safe landing place to
  dictate into now that the clipboard is gone.
- Input microphone picker (tray menu + Hub); HUD edge-snapping dock with
  size presets; app icon everywhere.

## 2026-07-08 improvements
- whisper.cpp upgraded to v1.9.1 (vendored xcframework), restoring Metal GPU transcription; `make-app.sh` bundles `whisper.framework` into the app.
- Instant finalize: fn-up lands the raw transcript immediately through the verified paths, then the LLM-cleaned version swaps in behind it via a diff; new HUD states for each outcome (Transcribing…, ✓ · polishing…, ✓ Pasted, ✓ In clipboard, ✓ cleaned in clipboard, ✓ raw (cleanup failed), ✕ Cancelled).
- Streaming windowed past ~15s: a confirmed prefix is frozen at the nearest quiet point so re-transcription passes stay O(tail), not O(whole recording).
- Hotkey ergonomics: taps under 200ms discard silently, any real keypress while fn is held cancels and undoes streamed text, and start/finish/cancel get distinct system sounds.
- Safety guards: password fields go on-device-transcript-to-clipboard-only (never pasted, never sent to cleanup); terminal apps get newline runs flattened so multi-line text can't execute per line; sub-0.4s or silent audio is skipped instead of transcribed (whisper hallucination guard).
- Failure visibility: broken settings.json is surfaced in the menu instead of being silently reset; menu shows live Mic/Accessibility permission status with click-to-fix; missing model gets a one-click base.en download with progress in the status item.
- Local dictation history: last 50 dictations (raw + cleaned + app) saved to history.json; menu gains Paste Last Dictation, a Recent submenu, and Clear History.
- Papercuts: HUD now shows on the screen you're actually dictating into; Launch at Login toggle; `liveStreamingEnabled` setting to disable mid-stream retyping; opt-in `restoreClipboard` to put the prior clipboard back after a verified in-field landing.
- Command mode: hold ⇧+fn with text selected, speak an edit instruction, release — the selection is transformed and pasted over itself, with a hard failure (nothing pasted) on any error and a clipboard fallback if the selection changed underneath it.

## Next steps
1. Real-world testing of the instant-finalize + swap flow across more apps (Electron chat apps, terminals, browser text areas) — confirm the raw-then-cleaned handoff feels instant and the swap lands correctly, not just in logs. Half of this is now automated: `swift run parla-insert-check [bundleID]` types five known payloads into a real app and reads each one back over AX. It has never produced a verdict — run from a background shell the focused element stays the terminal, so every case correctly SKIPs. It needs one GUI session (TextEdit, Ghostty, Slack) with someone at the machine.
2. Exercise command mode (⇧+fn) in daily use: verify transform quality, that a selection changed underneath is caught (`selectionStillMatches` is probed before anything is written) rather than overwritten, and that failures never leak the spoken instruction.
3. Verify the failure-visibility paths for real: a genuinely corrupt settings.json, a revoked permission, and a from-scratch model download. More open than it was, not less — the download path was rewritten since (staged temp file, size + SHA-256 verification, restore on failure) and first run now goes through the onboarding flow instead of the menu.
4. Route no-focus dictations into the Scratchpad instead of history-only — completes the clipboard-removal story. Still unbuilt: `Inserter.FocusTarget.none` is history-only, and nothing on the dictation path opens the Scratchpad.
5. Run the cleanup eval against both Haiku 4.5 and Sonnet before trusting the new default. `cleanupModel` now defaults to `claude-haiku-4-5` on cost and latency grounds with no eval behind it, and blank-model installs move to Haiku with it. Needs an Anthropic key; revert is one string.
