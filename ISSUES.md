# Parla — Reported Issues Log

User-reported issues, their root causes, and current status. (2026-07-05, updated 2026-08-07)

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
- SUPERSEDED (2026-08-07): there is no mid-speech append any more, so the
  "~1 word/second cadence" above no longer describes the app. Typing into the
  field while fn is physically held merges the keystrokes with the modifier
  (fn+A opens the Dock), so `liveTyping` is assigned false on both dictation
  entry paths and never set true anywhere. What survives is shadow streaming:
  whisper still runs during speech to build the confirmed prefix, so fn-up only
  pays for the tail — but the field is untouched until release, when the whole
  transcript lands in one insert.

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
- VIOLATED, then re-established on the atomic path (3359743, 2026-08-06): the
  guarantee held for the streaming path but not for the raw→cleaned swap, which
  posted one backspace per character over seconds against a single point-in-time
  `canEraseTyped` check — a character the user physically typed during the burst
  was eaten by the remaining backspaces. The swap now prefers one atomic AX value
  write (whole field value, caret restored) with a read-back to confirm the app
  accepted it: no window to type into. A field AX can read but not set, and an
  app that accepts the write and ignores it, both fall back to the backspace
  burst under the same single `canEraseTyped` check and still end in "✓ Pasted",
  so the window remains open on that path.
- The opaque-field select-back (⇧←×N + ⌘C) is gone with the clipboard (see
  2026-07-10). Verification is AX-read-only: compare the characters immediately
  before the cursor, and refuse rather than erase when they can't be read.

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
swallowed so it can't leak or restart a session. The Hub's shortcuts card now
states the exit ("fn, Space, or Return finishes").

## 2026-08-06 — dictation audit (branch fix/dictation-bugs)
- Whisper hallucination markers were typed into the field and saved to history,
  and a long dictation could lose a stretch out of the middle. `stripNonSpeech`
  tested each space-separated token for being individually wrapped, so
  "(upbeat music)" tokenised to `(upbeat` + `music)` and matched no marker;
  separately `transcribe()` returned `""` both for a pass that found no speech
  and for a whisper error or abort, so an errored head pass froze an empty
  confirmed prefix and advanced the sample cut past audio nothing re-read. It
  now returns nil for "did not complete", and no caller commits nil.
- Mic trouble came out silent or fatal: unplugging AirPods mid-dictation left
  the pill on "Listening…" over a frozen waveform while only pre-disconnect
  audio was transcribed; choosing a specific input and switching back to
  "System Default" kept recording from the old device for the rest of the run;
  a Mac with no usable input killed the process. Nothing observed
  `AVAudioEngineConfigurationChange` (now surfaced as "⚠️ Mic disconnected");
  the AUHAL was only pointed at a device when an explicit UID resolved, and
  once pinned it stops tracking the system default (it is now always set, with
  nil resolved to the current default); and a 0 Hz input format makes
  `installTap` raise an Objective-C exception, uncatchable from Swift, so the
  format is checked first. `start()` also cleared the sample buffer outside the
  lock the audio thread appends under.
- After a refused dictation — password field, ⇧+fn with nothing selected, mic
  failure — the next Space or Return anywhere vanished, or the next Esc fired a
  phantom "✕ Cancelled". `handle()` commits `session = .push` at fn-down, before
  the delegate can refuse, and nothing rolled it back; `reset()` now does, from
  every refusal path. Same commit: ⌃⌥⌘V and ⌃⇧⌘V matched the paste-last chord,
  which tested only cmd+ctrl, so the shortcut never reached the app it belonged
  to and Parla typed the last transcript instead; and holding Return to stop
  hands-free sent whatever draft was in the composer, because autorepeats were
  passed through ahead of the state machine while macOS synthesises them
  upstream of the tap whether or not the initiating keyDown was consumed.
- On a long dictation the landed text visibly erased itself character by
  character over seconds and retyped, and in web/Electron inputs "✓ Pasted"
  could appear over a field where nothing landed. The raw→cleaned swap posted
  one backspace per character with a 5ms sleep, on the main thread that also
  runs the hotkey tap, and `LiveTyper.diff` is prefix-only — so dropping a
  leading filler or capitalising the first letter, cleanup's two commonest
  edits, set the erase count to the entire transcript, and nothing verified the
  retype landed. It now prefers one atomic AX write with read-back, with the
  keystroke burst kept only as the fallback (see §6).
  `classifyFocus` also treated copy-success on `AXSelectedTextRange` as proof of
  editability without validating the returned value, making it strictly more
  permissive than the verifier it feeds.
- Speech that read like an instruction was obeyed, and the model's answer was
  typed in place of the words spoken. The transcript went to the cleanup model
  bare, with nothing marking where data began — command mode already delimited
  its selection; dictation now does the same, open marker only so a spoken
  "</transcript>" cannot close the region early. Same commit: a one-line answer,
  summary or refusal sails under an upper length ceiling, so a floor was added
  (1/5, applied to transcripts of 80+ chars); the 15s request timeout is an idle
  timer on a non-streaming completion, so it bounded total generation and cut
  off cleanup on exactly the long dictations the streaming window exists to
  support (now 60s); and transforms no longer run their result through the
  wrapping-quote strip, which made "put this in quotes" retype the selection
  unchanged under "✓ Pasted".
- A dictation could fire its whole transcript as keystrokes into a web page or a
  file list — where single letters are shortcuts — or withhold it from the field
  the user was looking at. Focus was resolved at fn-down and acted on at fn-up
  with only the secure case re-checked, but the tap sees no mouse events so
  clicking never cancels a dictation, and hands-free exists precisely so the
  user can move around while speaking; `finish()` now branches on focus read at
  insert time. Same commit: a second dictation waited out the previous one's
  cleanup network call, because the await sat on the same serialized chain as
  whisper (detached — the generation guard and AX verification already make a
  late swap safe); a fast re-press revived the previous dictation's stream loop
  against the new dictation's freshly-cleared buffer, splicing its words into
  the old confirmed prefix, because `stream()` gated on the shared `isRecording`
  flag rather than the generation it started in; ⌃⌘V and the menu's Paste Last
  were the only insertion path with no secure-field check; and a broken custom
  `whisperModelPath` made the one-click download a no-op loop, since the
  download installs to the default path that `loadModel` never re-read.
- Pressing Esc during "Transcribing…" or "✓ · polishing…" hid the pill, which
  reads as a successful cancel — it isn't, and the unwanted transcript typed
  itself in moments later, followed by the cleaned swap. `dismiss()` settled any
  visible non-idle pill; it now dismisses only a finished-state toast, which is
  what its own comment always claimed it did.
- Leave Parla running untouched for a long while — a screen lock, a sleep — and
  fn stops working until the app is relaunched. The only path that re-enables a
  disabled tap lives inside the tap callback, so reaching it requires macOS to
  still be delivering events there, and nothing else in the process ever checked
  the tap's state — so any disable that doesn't arrive as a delivered
  notification is permanent. A 5s liveness poll now re-enables a disabled tap
  and recreates one whose mach port has gone invalid, and Parla opts out of App
  Nap: a throttled run loop makes the callback miss its deadline, which is how
  macOS decides to disable a tap for being slow in the first place.

## 2026-08-11 changes
- All 29 items of the open-source audit backlog (`docs/research/FEATURES-TO-ADD.md`)
  are implemented on `feat/audit-implementation`, followed by four adversarial
  review rounds — 63 findings, 49 confirmed and fixed, 14 refuted. Per-item detail
  lives in `progress.md`; the findings and their verdicts in
  `docs/research/11-review-findings.md`. Not repeated here.
- What touches this log directly: hotkeys are now rebindable (retiring the old
  "configurable shortcuts" next step); secure event input is detected before
  typing and refuses the dictation
  instead of typing into a void; the typing chunk went 20 → 200 UTF-16 units with
  a 1ms inter-chunk sleep (erase still 5ms — issue 6 is the erase path).
- Both "needs a human" items were since closed: `parla-insert-check` verified
  TextEdit, Ghostty, Slack and Cursor at 20/20 cases, and the Haiku-vs-Sonnet
  A/B ran via `claude -p` (inconclusive — Haiku stays; see progress.md).

## 2026-07-10 changes
- Clipboard removed entirely (supersedes the clipboard HUD states and
  clipboard-fallback mentions in issues 3 and 5–7 and in the improvements
  below): Inserter types via CGEvent Unicode
  keystrokes; every unverifiable delivery goes to local history instead of the
  pasteboard; password fields are refused at fn-down with a toast. The only
  remaining pasteboard write is the Hub's explicit Copy button.
- Hotkeys moved from NSEvent global monitors to a CGEventTap (same
  Accessibility permission) so chords can be swallowed instead of leaking into
  the front app; tap creation retries until the permission is granted.
- New shortcuts: fn+Space hands-free (latch while holding fn, fn stops, pop +
  "Hands-free…" pill on latch), Esc cancels dictation / dismisses the HUD
  toast, ⌃⌘V pastes the last transcript, ⌃⌘S opens the Scratchpad. All listed
  in the Hub's shortcuts card.
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
- Papercuts: HUD now shows on the screen you're actually dictating into; Launch at Login toggle; `liveStreamingEnabled` setting to disable mid-stream retyping.
- Command mode: hold ⇧+fn with text selected, speak an edit instruction, release — the selection is transformed and pasted over itself, with a hard failure (nothing pasted) on any error and a clipboard fallback if the selection changed underneath it.

## Next steps
1. Real-world testing of the instant-finalize + swap flow across more apps (Electron chat apps, browser text areas) — `swift run parla-insert-check [bundleID]` now automates the read-back half and has verified TextEdit, Ghostty, Slack and Cursor (20/20 cases). The swap was also rewritten on 2026-08-06 into a single AX value write with read-back, so the open question is which further apps accept that write and which silently ignore it and fall back to keystrokes.
2. Exercise command mode (⇧+fn) in daily use: verify transform quality, that a selection changed underneath is caught (`selectionStillMatches` is probed before anything is written) rather than overwritten, and that failures never leak the spoken instruction.
3. Verify the failure-visibility paths for real: a genuinely corrupt settings.json, a revoked permission, and a from-scratch model download. More open than it was, not less — the download path was rewritten since (staged temp file, size + SHA-256 verification, restore on failure) and first run now goes through the onboarding flow instead of the menu.
4. Route no-focus dictations into the Scratchpad instead of history-only — completes the clipboard-removal story. Still unbuilt: `Inserter.FocusTarget.none` is history-only, and nothing on the dictation path opens the Scratchpad.
5. Dogfood the 2026-08-06/07 fix set on a real build. Those fixes are runtime behaviour against WindowServer, Core Audio and other apps' AX trees, and nothing in the test suite covers them end-to-end: tap survival across a screen lock, a mic disconnected mid-dictation, the atomic swap in Electron/web fields, and Esc during "Transcribing…".
