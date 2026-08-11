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
| 2 | 7 | 0 | 0 | 6 | 1 |
| **all** | **29** | **22** | **0** | **6** | **1** |

Suite: **284 tests, 0 failures.** Build clean.

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

- `LICENSE-COMMERCIAL.md` stub (reserves the paid-binary right) — called for by
  `08-cost.md` #1, was outside the agent's file scope. Do before the first
  external PR.
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
| 1 | Streaming preview in Parla's own HUD | `Parla/main.swift`, `HUD.swift` | M | low | todo | |
| 2 | Per-dictation `PipelineMetrics` on `HistoryEntry` | `ParlaCore/History.swift`, `Cleanup.swift`, `OpenAICompatClient.swift` | M | low | todo | |
| 3 | Rebindable hotkeys | `ParlaCore/Hotkey.swift`, Hub | M | med | todo | |
| 4 | Recording persistence + recovery | `ParlaCore/AudioRecorder.swift`, `History.swift` | M | low | todo | |
| 5 | Automatic dictionary learning | `ParlaCore/Inserter.swift`, new tracker | L | med | todo | |
| 6 | Onboarding flow | `Parla/Hub/` | L | low | todo | |
| 7 | Prompt caching | — | M | low | **skipped** | |

**Why #7 is skipped, not deferred:** the backlog's own finding is that Parla's
system prompt is ~334 tokens, below the 1,024-token cache minimum, so a
`cache_control` block today is silently inert. Crossing the threshold means
*growing* the prompt with few-shot examples, which only pays off above ~4
dictations per 5-minute window. That is unknowable until Tier 2 #2 ships usage
data. Implementing it now would be a latency and token regression justified by
nothing. Revisit after #2 has real numbers.

---

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
