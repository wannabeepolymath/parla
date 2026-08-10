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
| 0 | 8 | 0 | 0 | 8 | 0 |
| 1 | 14 | 0 | 0 | 14 | 0 |
| 2 | 7 | 0 | 0 | 6 | 1 |
| **all** | **29** | **0** | **0** | **28** | **1** |

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
| 1 | Gate shadow stream on freeze threshold | `Parla/main.swift`, `README.md` | S | low | todo | |
| 2 | Add `LICENSE` (AGPL root + MIT ParlaCore) | `LICENSE`, `Sources/ParlaCore/LICENSE`, `README.md` | S | none | todo | |
| 3 | Hoist `AVAudioConverter` out of tap callback | `ParlaCore/AudioRecorder.swift` | S | low | todo | |
| 4 | Detect Secure Event Input before typing | `ParlaCore/Inserter.swift` | S | low | todo | |
| 5 | Fence transcript + injection guards in cleanup prompt | `ParlaCore/Cleanup.swift` | S | low | todo | |
| 6 | Strip whisper markers per segment | `ParlaCore/Transcriber.swift` + tests | S | low | todo | |
| 7 | Delete `AXEnhancedUserInterface` write | `ParlaCore/Inserter.swift:97` | S | low | todo | |
| 8 | Chunk 20→200 units, cut inter-chunk sleep | `ParlaCore/Inserter.swift` | S | **med** | todo | |

Item 8 lands alone, after 1–7, and needs a real smoke test — `ISSUES.md` §5–7
is a history of insertion regressions in exactly the apps it touches.

## Tier 1 — high value, more work

| # | Item | Files | Effort | Risk | Status | Commit |
|---|---|---|---|---|---|---|
| 1 | Env-gated latency trace | `Parla/main.swift`, `ParlaCore/AudioRecorder.swift` | S | none | todo | |
| 2 | Get `Settings` off the keypress path | `Parla/main.swift` | S | low | todo | |
| 3 | Set `params.language = "en"`; drop stale `flash_attn` | `ParlaCore/Transcriber.swift` | S | low | todo | |
| 4 | Model catalog + hardened download | `ParlaCore/Transcriber.swift`, `Parla/main.swift`, Hub | M | med | todo | |
| 5 | WER harness (replaces exact-match) | `ParlaCore/Eval.swift`, `parla-eval/`, `eval/cases/` | M | low | todo | |
| 6 | CI — `swift build` + `swift test` | `.github/workflows/` | S | none | todo | |
| 7 | Mic prepare/start split + pre-roll ring, BT excluded | `ParlaCore/AudioRecorder.swift` | M | med | todo | |
| 8 | Extract `DictationSession` state machine | `ParlaCore/DictationSession.swift`, `Parla/main.swift` | M-L | med | todo | |
| 9 | Process + capture lifecycle safety | `Parla/main.swift`, `ParlaCore/AudioRecorder.swift` | M | low | todo | |
| 10 | `AppCategory` enum replacing free-text app sentence | `ParlaCore/Cleanup.swift`, `TextRules.swift` | M | low | todo | |
| 11 | Deterministic snippets | `ParlaCore/Pipeline.swift`, `Cleanup.swift` | M | low | todo | |
| 12 | Sample frontmost app at finalize, not fn-down | `Parla/main.swift` | S | low | todo | |
| 13 | Idle model-unload policy | `ParlaCore/Transcriber.swift` | M | med | todo | |
| 14 | Default `cleanupModel` to Haiku 4.5 | `ParlaCore/Settings.swift` | S | low | todo | |

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
| 2026-08-11 | This tracker created. Branch + docs commit pending. |
