# Parla — Backlog Implementation Progress

Tracks execution of `docs/research/FEATURES-TO-ADD.md`, the ranked backlog
derived from the architecture audit of 24 open-source dictation apps.

**Branch:** `feat/audit-implementation` (pending)
**Started:** 2026-08-11
**Last updated:** 2026-08-11

Status: `todo` · `wip` · `done` · `blocked` · `skipped`

---

## Summary

| Tier | Items | done | wip | todo | skipped |
|---|---|---|---|---|---|
| 0 | 8 | 8 | 0 | 0 | 0 |
| 1 | 14 | 14 | 0 | 0 | 0 |
| 2 | 7 | 6 | 0 | 0 | 1 |
| **all** | **29** | **28** | **0** | **0** | **1** |

Suite: **382 tests, 0 failures.** Build clean.

---

## Wave plan

Waves are ordered by dependency, not by tier. Each wave ends with
`swift build && swift test`, then one commit. Items touching the same file
are never parallelised.

| Wave | Contents | Gate |
|---|---|---|
| 1 | Tier 0 ×8 | build + test + smoke Slack/Ghostty/VS Code (item 8 only) |
| 2 | Tier 1 S-effort: 1, 2, 3, 6, 9, 12 | build + test + CI green |
| 3 | Tier 1 M-effort: 5 → 4+13, 7, 10, 11 | build + test + eval baseline |
| 4 | Tier 1 #8 `DictationSession` refactor | build + test, `main.swift` < 500 lines |
| 5 | Tier 2: 1, 2, 3, 4, 5, 6 | build + test |

**Hard sequencing constraints** (from the backlog's own analysis):
- T1#5 (WER harness) **before** T1#4 (model catalog) and T1#14 (Haiku default) — neither is honestly evaluable without it.
- T1#4 (model catalog) and T1#13 (idle unload) ship **in the same change**.
- T1#7 (warm mic) does not land without its Bluetooth exclusion.
- T1#1 (latency trace) before the rest of Tier 1 — every latency claim is unfalsifiable until it exists.
- T2#1 (HUD streaming preview) partially reverses T0#1 (shadow-stream gate); if it ships, the gate becomes "only while the HUD is visible and previews are on".

---

## Tier 0 — do these first

| # | Item | Files | Effort | Risk | Status | Commit |
|---|---|---|---|---|---|---|
| 1 | Gate shadow stream on freeze threshold | `Parla/main.swift`, `README.md` | S | low | **done** | wave 1 |
| 2 | Add `LICENSE` (AGPL root + MIT ParlaCore) | `LICENSE`, `Sources/ParlaCore/LICENSE`, `README.md` | S | none | **done** | wave 1 |
| 3 | Hoist `AVAudioConverter` out of tap callback | `ParlaCore/AudioRecorder.swift` | S | low | **done** | wave 1 |
| 4 | Detect Secure Event Input before typing | `ParlaCore/Inserter.swift` | S | low | **done** | wave 1 |
| 5 | Fence transcript + injection guards in cleanup prompt | `ParlaCore/Cleanup.swift` | S | low | **done** | wave 1 |
| 6 | Strip whisper markers per segment | `ParlaCore/Transcriber.swift` + tests | S | low | **done** | wave 1 |
| 7 | Delete `AXEnhancedUserInterface` write | `ParlaCore/Inserter.swift:97` | S | low | **done** | wave 1 |
| 8 | Chunk 20→200 units, cut inter-chunk sleep | `ParlaCore/Inserter.swift` | S | **med** | **done** | ⚠ smoke test pending |

### Wave 1 notes

- **#1** gated on `snap.count`, not `tail.count` (post-cut the tail is ~5s and
  would re-gate itself off mid-dictation), with a `liveTyping ||` short-circuit
  so re-enabling live typing doesn't silently lose the first 15s of hypothesis.
- **#3** produced a `Resampler` class holding one cached converter + one reused
  output buffer, `.noDataNow` between buffers, `flush()` at stop. A fresh or
  rebuilt converter's first buffer is short by the filter priming delay
  (~240 samples); nothing is lost — it comes out of the next call or `flush()`.
  Also added `conversionFailures()` so total conversion failure is
  distinguishable from silence.
- **#4** `focusTarget(secureInput:)` takes the flag as a defaulted parameter
  purely so tests can force the branch.
- Two tests needed fixing after the fact, both my scoping error, not agent error:
  `OpenAICompatTests` asserted the pre-fence wire shape (now asserts against
  `PromptBuilder.user`), and the new resampler test asserted an exact output
  length on a priming buffer.

### ⚠ Outstanding manual verification — Tier 0 #8

Chunk size is now 200 UTF-16 units (was 20) and the inter-chunk sleep is 1ms
(was 5ms). `typeBackspaces` was deliberately left at 5ms — erasing is the
dangerous path and `ISSUES.md` §6 is about erase safety.

Unit tests cover the chunking property and the 600-char → 3-bursts regression.
They cannot cover how a real app frames the bursts. **Someone has to dictate a
long multi-line transcript into Slack, Ghostty and VS Code and confirm no
dropped characters and no `[Pasted text #N]` fan-out.** This is the one Tier 0
change with a real regression surface (`ISSUES.md` §5–7 is a history of
insertion bugs in exactly these apps), and it is the only automated-test gap in
Tier 0. Revert to `max: 20` / `usleep(5_000)` if it misbehaves — the change is
two constants.

### Not yet done from Wave 1's items

- ~~`LICENSE-COMMERCIAL.md` stub~~ — done in the closing pass. `08-cost.md:182,212`
  called for it in TypeWhisper's shape; it reserves the dual-license option while
  Parla still has sole copyright, which is the only moment it is cheap.
- No regression test for #1's gate: `stream()` lives in the app target and isn't
  importable from `ParlaCoreTests`. Needs a seam in ParlaCore to be testable —
  revisit during Tier 1 #8 (`DictationSession` extraction), which creates one.

Item 8 lands alone, after 1–7, and needs a real smoke test — `ISSUES.md` §5–7
is a history of insertion regressions in exactly the apps it touches.

## Tier 1 — high value, more work

| # | Item | Files | Effort | Risk | Status | Commit |
|---|---|---|---|---|---|---|
| 1 | Env-gated latency trace | `ParlaCore/Trace.swift` (new), `main.swift`, `AudioRecorder.swift` | S | none | **done** | wave 2 |
| 2 | Get `Settings` off the keypress path | `ParlaCore/Settings.swift`, `main.swift` | S | low | **done** | wave 2 |
| 3 | Set `params.language = "en"`; drop stale `flash_attn` | `ParlaCore/Transcriber.swift` | S | low | **done** | wave 2 |
| 4 | Model catalog + hardened download | `ParlaCore/ModelCatalog.swift` (new), `Transcriber.swift`, `main.swift`, Hub | M | med | **done** | wave 3 |
| 5 | WER harness (replaces exact-match) | `ParlaCore/Eval.swift`, `parla-eval/`, `eval/cases/` | M | low | **done** | wave 3 |
| 6 | CI — `swift build` + `swift test` | `.github/workflows/ci.yml` | S | none | **done** | wave 2 |
| 7 | Mic prepare/start split + pre-roll ring, BT excluded | `ParlaCore/AudioRecorder.swift` | M | med | **done** | wave 3 |
| 8 | Extract `DictationSession` state machine | `ParlaCore/DictationSession.swift` (new), `Parla/Dictation.swift` (new), `main.swift` | M-L | med | **done** | wave 4 |
| 9 | Process + capture lifecycle safety | `Parla/main.swift`, `ParlaCore/AudioRecorder.swift` | M | low | **done** | wave 2 |
| 10 | `AppCategory` enum replacing free-text app sentence | `ParlaCore/Cleanup.swift`, `TextRules.swift` | M | low | **done** | wave 3 |
| 11 | Deterministic snippets | `ParlaCore/Pipeline.swift`, `Cleanup.swift` | M | low | **done** | wave 3 |
| 12 | Sample frontmost app at finalize, not fn-down | `Parla/main.swift` | S | low | **done** | wave 2 |
| 13 | Idle model-unload policy | `ParlaCore/Transcriber.swift`, `main.swift` | M | med | **done** | wave 3 |
| 14 | Default `cleanupModel` to Haiku 4.5 | `ParlaCore/Settings.swift` | S | low | **done** | ⚠ unverified |

### ⚠ Tier 1 #14 shipped unverified

`cleanupModel` now defaults to `claude-haiku-4-5` (was `claude-sonnet-5`) on
cost and latency grounds. **No eval has been run against either model** — the
corpus that would settle it was built in the same wave and has never been
executed, because a full run needs a whisper model plus an API key.

Two corrections to the backlog found while doing it:
- The backlog claims Haiku is "~4.6× cheaper". The audit's own cost table
  (`08-cost.md:40-41`) computes **3.0×** from the rates it recorded. 3.0× is the
  defensible number; the direction of the change is unaffected.
- `README.md:143` already documented the default as `claude-haiku-4-5`, so the
  docs were ahead of the code. This makes them agree.

Blast radius beyond the literal default: `CleanupFactory.swift:87-88` substitutes
`Settings().cleanupModel` when a user's configured model is blank, so existing
installs with an empty model field silently move to Haiku. Users with an explicit
`cleanupModel` are untouched. Revert is one string.

**Before trusting this:** `swift run parla-eval --cleanup-only` against both
models and compare zero-edit rate and p90 WER.

### Eval harness — real but not yet load-bearing

`parla-eval` now scores WER (p50/p90/failure-rate) with one canonical normalizer
applied to both sides, splits ASR-only from cleanup-only so the two regressions
are distinguishable, and has a `verify` mode that re-scores committed hypotheses
offline. 23 text cases added (fillers, self-correction, lists, numbers, code,
terminal, injection, jargon, snippets).

Two honest gaps: `eval/results.json` does not exist yet, so `verify` currently
reports zero fixtures and passes vacuously — it only becomes a CI gate once
someone commits a real run. And the two `.wav` cases have no `.raw.txt`
reference, so **the ASR leg is entirely unscored**; text cases do not substitute
for recorded audio, and the silence/long-form categories where the guards live
cannot be exercised at text level at all.

### Wave 4 — what the adversarial reviews caught

Both reviewers returned `changed-behaviour`. The refactor built and passed 281
tests *before* these were found, which is the point of reviewing separately from
implementing:

1. **Off-main `session.state` read** — a real data race. `State` carries a
   `Session`, which carries `Settings`, i.e. Swift arrays and dictionaries.
   Replaced with an `OSAllocatedUnfairLock<Int>` mirroring "which generation
   holds the mic" (0 = nobody). The comment above it still claimed a "benign
   stop-flag race" from when it guarded a `Bool`; deleted.
2. **The interpreter broke its own documented contract** — `Dictation.swift`
   opens with "effect order is the contract, never reordered", then re-entered
   `send()` from inside `perform()`, so nested effect lists ran *inside* effect
   #2. That silently moved the cleanup-endpoint warm-up to after
   `recorder.start()`, a ~50ms Electron AX probe, and a possible 574MB model
   load — regressing the exact latency path it exists to serve. Now a real queue
   inside the machine; nested sends append.
3. **A test certifying a guarantee that did not exist** — `captureEnded` was
   passed the *live* generation, making the staleness check a tautology. Fixed by
   reading the gen on the tap thread as capture ends, so the guard is now real.
4. Cancel no longer serialized behind the in-flight stream pass — a late
   `.streamTyped` could resurrect a ledger that was just erased. Cancel now bumps
   `gen`, with the hazard documented at the site.

Both new invariants were mutation-checked: reverting the queue fails the
interleave test, and removing cancel's `gen += 1` fails
`testLateStreamTypedAfterCancelCannotResurrectTheLedger`. I re-ran the second
mutation independently to confirm it wasn't a vacuous test — it fails as claimed.

The implementing agent also noticed its own first interleave test was vacuous
(with today's effect lists, every dispatching effect happens to be last, so
recursion and queueing are observationally identical) and rewrote it to hang the
nested dispatch off the *first* effect.

## Tier 2 — later

| # | Item | Files | Effort | Risk | Status | Commit |
|---|---|---|---|---|---|---|
| 1 | Streaming preview in Parla's own HUD | `HUD.swift`, `Dictation.swift`, `DictationSession.swift` | M | low | **done** | wave 5 |
| 2 | Per-dictation `PipelineMetrics` on `HistoryEntry` | `ParlaCore/History.swift`, `Cleanup.swift`, `OpenAICompatClient.swift`, Hub | M | low | **done** | wave 5 |
| 3 | Rebindable hotkeys | `ParlaCore/Hotkey.swift`, `Settings.swift`, Hub | M | med | **done** | wave 5 |
| 4 | Recording persistence + recovery | `ParlaCore/RecordingStore.swift` (new), `Dictation.swift`, Hub | M | low | **done** | wave 5 |
| 5 | Automatic dictionary learning | `ParlaCore/DictionaryLearner.swift` (new), `Dictation.swift`, Hub | L | med | **done** | wave 5 |
| 6 | Onboarding flow | `Parla/Hub/Onboarding.swift` (new), `HubWindow.swift`, `main.swift` | L | low | **done** | wave 5 |
| 7 | Prompt caching | — | M | low | **skipped** | |

### Wave 5 notes

- **#1** extends the Tier 0 gate rather than replacing it:
  `liveTyping || preview || snap.count > threshold`. `streamPreviewEnabled`
  defaults **off**, so with previews disabled the stream loop is byte-identical
  to before and the ~33% GPU duty cycle Tier 0 #1 removed stays removed.
  Preview text emits only `.hud(.preview)` — it never reaches insertion,
  history, or the transcript.
- **#2** mirrors `Trace`'s stamp vocabulary instead of adding a second timing
  path, so the persisted metrics and the env-gated trace cannot drift. Unknown
  models are recorded as **unpriced, never $0** — a local Ollama really is free,
  but so is an unknown hosted model right up until the bill arrives.
- **#4** writes the WAV before transcription. Secure dictations are refused at
  `.focusSampled` so no file is ever written; `resolve(secure:)` covers only the
  case of focus *moving* into a password field mid-dictation, which cannot be
  known in advance. Corpus mode writes `.hyp.txt`, deliberately **not** the
  `.raw.txt` the eval reads as its ASR reference — scoring whisper against its
  own hypothesis would report 0% WER forever. A human still has to correct the
  draft into a real reference, so this feeds the ASR corpus, it does not fill it.
- **#5** proposes, never applies. Nothing in `DictionaryLearner` writes
  `Settings.dictionary`; the user confirms in the Hub. This is the right bias —
  a wrong entry is injected into both the whisper `initial_prompt` and the
  cleanup prompt, so it would corrupt every future dictation.
- One build break to fix afterwards: `HubModel.onTryoutStop`'s inner closure
  parameter was non-escaping by default, but the tryout completion outlives the
  call because transcription is async.

**Why #7 is skipped, not deferred:** the backlog's own finding is that Parla's
system prompt is ~334 tokens, below the 1,024-token cache minimum, so a
`cache_control` block today is silently inert. Crossing the threshold means
*growing* the prompt with few-shot examples, which only pays off above ~4
dictations per 5-minute window. That is unknowable until Tier 2 #2 ships usage
data. Implementing it now would be a latency and token regression justified by
nothing. Revisit after #2 has real numbers.

---

## Final review — what shipped broken

An adversarial review of the whole branch (six dimensions, every finding then
independently verified by a second agent told to refute it) raised 32 findings.
25 survived verification. **Three shipped items did not actually work**, which
is the part worth remembering: all three built, passed their tests, and were
committed.

| Finding | Why the tests missed it |
|---|---|
| **`AudioRecorder.prepare()` had no call site** — the warm engine and pre-roll ring (Tier 1 #7, the biggest latency item) never ran. `warm` was never true, so the engine was torn down after every dictation, `PreRollRing` was always empty, `mediaPlaying()` never ran, `scheduleRebuild()` was unreachable. | The unit tests tested the ring and the transport gate as pure logic. Nothing tested that anything *called* them. |
| **The cleanup prompt got no app context at all** — `Pipeline.clean`, the only production caller, never passed a `bundleID`, so `category` was permanently `.unknown` and `toneHint` always nil. The branch *lost* a hint `main` had. | `CleanupTests` tested `PromptBuilder` directly and stayed green throughout. The new test goes through `Pipeline.clean` for exactly this reason. |
| **Warp was never classified as a terminal** — table key `dev.warp.Warp`, real bundle ID `dev.warp.Warp-Stable`. Dictated newlines submit as shell commands. | `TextRulesTests` asserted against the non-existent ID, so it passed while the real app was unprotected. |

Plus two that were live-path defects rather than dead code:

- **`canEraseTyped` ignored selection length** (`focusedFieldState` threw
  `range.length` away), so it could not tell a bare caret from the start of a
  live selection — and the first `Delete` eats the whole selection. That is the
  ISSUES.md #6 invariant (*never delete text Parla did not write*) failing on
  the cleaned-swap path, which runs on every dictation. Now refuses whenever a
  selection is live, and the decision is a pure function with six tests.
- **The hands-free latch was unreachable in command mode** and leaked a Space
  keystroke into the front app: Tier 2 #3 routed it through exact modifier
  matching, but command mode means shift is held by definition. Hands-free now
  matches as a superset (it only fires while the trigger is physically held, so
  it cannot steal a chord); idle chords stay exact.

Also fixed: an onboarding tryout that leaked an open mic and a permanently
suspended hotkey tap (`onDisappear` cannot fire when
`isReleasedWhenClosed = false`), a `Metrics` singleton clobbered by the next
fn-down while a polish was in flight, an unconsumed `StreamWindow` splicing into
a later dictation, an unreachable secure-deletion guard on the one path that
retains the WAV, and six tests that passed whether or not the code was correct.

### Round 2 — reviewing the fixes caught two majors the fixes created

Fixes are unreviewed code. Reviewing commit `de20782` itself raised 12 findings,
11 confirmed:

- **The warm-engine fix reintroduced the exact bug its own guard was added to
  prevent.** Wiring `prepare()` latches `warm = true` at launch *before* any
  permission check, and the TCC guard lives inside `warmUp()`, so it gates only
  the warm build — `start()`'s cold path builds regardless. With `warm` true,
  `stop()` never tears down, so a unit built before the mic grant is kept alive
  forever delivering zeros, and a later grant never reaches it. Reachable by
  skipping the onboarding permission page. Fixed with a `builtAuthorized` flag
  read at build time, so an unauthorized engine is always handed back at `stop()`.
- **The hands-free chord fix was too broad — my error.** I passed the first
  reviewer's "match as a superset" suggestion through without questioning its
  scope. The only extra modifier command mode needs is `.shift`; `isSuperset`
  tolerates all of them, so `fn+⌘+Space` got swallowed (Spotlight stopped
  opening, and the dictation silently latched into hands-free). In `.idle` it
  was worse: macOS auto-decorates arrows/Home/End with the fn bit, so idle
  chords could match a synthetic fn. And the commit **deleted
  `testExtraModifierDoesNotLatchHandsFree`**, which existed to assert exactly
  the behaviour being broken. Now: shift-only tolerance, and only while a
  session is live; idle stays exact; the deleted test is restored.

Also fixed: the metrics parking mis-attributed buckets into a permanent
off-by-one; `finish()`'s no-model early return kept a stashed WAV without
consulting the secure signal; the pasteboard-invariant test attributed writes to
the nearest preceding `func`, so an unsanctioned write beside `copy()` would
pass; and five user-facing strings — including `NSMicrophoneUsageDescription`,
which is what the macOS permission dialog shows — still claimed the mic is only
open while a key is held. The warm mic is the point of the feature, so the copy
was fixed, not the behaviour. The README now also states plainly that the orange
mic indicator stays lit while Parla runs.

Seven findings were correctly **refuted** by the verifier — including a claimed
`stripNonSpeech` over-deletion and a claimed duplicate download path.

### Round 3 — the matcher was patched twice and wrong twice

Findings by round: **25 → 11 → 9**. The useful signal is not the count, it is
that the same two subsystems kept reappearing. By round 3 `AudioRecorder` came
back **fully refuted** (all four audio findings died in verification) — the warm
engine is dry. `Hotkey` produced three more majors, so it was rebuilt as a whole
rather than patched a third time.

- **The hands-free STOP matcher had never been fixed.** Round 2 fixed the
  *latch* and left its sibling two lines below alone: no `modifiers` term at
  all, under a comment claiming "bare this time: the trigger has been released,
  so no chord can match". A verifier swept all 32 modifier sets from the latched
  state: **64 swallowed, 0 passed through** — ⌘Space, ⌃Space, ⇧Return and
  ⌘Return destroyed at the tap. Pre-existing, and correctly reclassified by the
  reviewer as an incomplete fix rather than a new regression.
- **Two majors from one root cause:** `CGEventFlags` has no left/right
  distinction, so either key of a modifier pair sets the bit while `handle()`
  only sees the keycode it is bound to. Pressing the twin of a rebound trigger
  left the session stuck in `.push`, and the idle latch swallowed keystrokes
  with no edge forever.
- **Hand-written arrow/Home/End/Page/F-key chords in settings.json could never
  match**, because macOS decorates those keycodes with a synthetic fn bit the
  hand-written spelling does not carry.

The rebuild was mutation-tested per fix by extracting the pure matcher into a
standalone harness: reverting fix 1 → 116 failing assertions, 2 → 3, 3 → 1,
4 → 1, 5 → 4. The missing latched-state modifier sweep is now a test.

### The copy fix from round 2 was itself wrong

I reported last round that fixing the copy rather than the warm-mic behaviour
was the right trade. The trade was right; my execution was not — the rewrite
replaced one false claim with three:

- "idle audio ... never written to disk" was **false**: the 0.45 s pre-roll is
  prepended to the capture and written by `RecordingStore` like the rest of it.
  That is exactly the sentence a privacy-conscious reader would rely on.
- "keeps the mic open from launch" is untrue for Bluetooth, which is
  deliberately excluded (holding one open forces 16 kHz call quality and halves
  headset battery).
- "transcribes only while you hold" contradicts the shipped hands-free latch —
  including in `NSMicrophoneUsageDescription`, the one string macOS shows in the
  permission dialog.

All three now state what the code actually does, with the retention window, the
deletion point and the eval-corpus opt-in named explicitly.

### Round 4 — dry

6 raised, 4 confirmed, **all nits**. The rebuilt matcher produced exactly one
finding — a pre-existing Esc nit — and the AudioRecorder dimension was not
re-raised at all. That is the stopping condition.

Closed: the onboarding still promised *"Nothing you say leaves it"*, which cloud
cleanup contradicts (the transcript text does leave the Mac — the app says so
correctly in the README and on the Privacy page, just not here); the README's
7-day retention promise was true only at the next dictation, so the Data &
Privacy page now prunes on appear rather than listing files it simultaneously
claims are deleted; and the metrics park was created for dictations that were
owed nothing, which with history *off* handed each row the previous dictation's
numbers forever. That last fix is mutation-checked — reverting it fails the new
test with 3 assertions.

Left deliberately: **Esc stays modifier-blind.** It swallows ⌘⌥Esc once
mid-dictation, but "Esc always cancels" is a rule `problem()` enforces, an abort
you have to press bare is not an abort, the session is `.idle` immediately after
so the second press goes through, and the naive fix breaks an existing test. The
trade is now written at the branch instead of being implicit.

One refutation worth recording: a reviewer claimed this tracker misdescribed
⇧Return as un-swallowed. Refuted — the sentence describes the *bug* (pre-fix,
all 32 modifier sets were swallowed, ⇧Return included), and ⇧Return stays
swallowed by design because it produces whitespace.

## Log

| When | What |
|---|---|
| 2026-08-11 | Audit complete — 64 agents, 0 errors. 13 docs written to `docs/research/`. |
| 2026-08-11 | All 8 Tier 0 claims verified against source; every `file:line` reference accurate. |
| 2026-08-11 | This tracker created. Branch `feat/audit-implementation`, docs committed (8e4f58e). |
| 2026-08-11 | Wave 1: Tier 0 #1–#7 landed. 6 agents on disjoint files, 0 conflicts. 173/173 pass. |
| 2026-08-11 | Tier 0 #8 landed alone (chunk 20→200). 174/174 pass. Manual smoke test still outstanding. |
| 2026-08-11 | Wave 2: Tier 1 #1, #2, #3, #6, #9, #12 landed. 190/190 pass. |
| 2026-08-11 | Wave 3: Tier 1 #4, #5, #7, #10, #11, #13, #14 landed. 240/240 pass. Model catalog hashes + sizes verified against Hugging Face. |
| 2026-08-11 | Wave 4: Tier 1 #8 `DictationSession` extracted. main.swift 1364 → 458 lines. Two adversarial reviews found 5 defects; all fixed. 284/284 pass. **Tier 1 complete.** |
| 2026-08-11 | Wave 5: Tier 2 #1–#6 landed. 356/356 pass. **All 28 implementable items done; #7 skipped by the audit's own reasoning.** |
| 2026-08-11 | Closing pass: `LICENSE-COMMERCIAL.md` added. |
| 2026-08-11 | Review round 1 (whole branch): 32 raised, **25 confirmed / 7 refuted**. All fixed. 367/367 pass. |
| 2026-08-11 | Review round 2 (the fix commit itself): 12 raised, **11 confirmed / 1 refuted** — the fixes had introduced 2 majors. All fixed. 373/373 pass. |
| 2026-08-11 | Review round 3 (twice-wrong subsystems): 13 raised, **9 confirmed / 4 refuted**. AudioRecorder came back fully refuted — dry. Hotkey rebuilt wholesale. 381/381 pass. |
| 2026-08-11 | Review round 4: 6 raised, **4 confirmed / 2 refuted — all nits, zero majors, zero minors.** Dry. 382/382 pass. |
