# Parla — Architecture

Phases 1 and 2 are built. This describes what exists; the original decision
record (two candidate designs and the corrections to each) is kept verbatim at
the bottom, because the reasoning still explains why the shipped thing looks
like this.

## What exists today

One SwiftPM package, no third-party dependencies, one vendored binary target
(`Frameworks/whisper.xcframework`). Four targets:

| target | what it is |
|---|---|
| `ParlaCore` | the library — pure logic plus the audio/whisper/HTTP clients |
| `Parla` | the menu-bar app: AppKit wiring, the Hub (SwiftUI), the interpreter |
| `parla-eval` | regression harness over `eval/cases` (CI runs `parla-eval verify`) |
| `parla-insert-check` | types known strings into a real app and reads the field back |

```
fn held (CGEventTap, rebindable — ⇧+fn = transform selection)
    │
    ▼
AudioRecorder — warm engine, PreRollRing prepends ≤0.45 s of pre-key audio,
                Resampler converts to 16 kHz mono once per stream
    │  during capture: shadow stream loop re-transcribes the unconfirmed
    │  window (StreamWindow) so fn-up only pays for the tail. Its text is
    │  never inserted — optional preview in Parla's own pill.
    ▼ fn-up
whisper.cpp (Metal + flash attention), initial_prompt = dictionary + confirmed tail
    │  raw transcript
    ▼
cleanup LLM POST (Anthropic, or any OpenAI-compatible /chat/completions
    incl. a keyless local server) — prompt carries dictionary, snippets and a
    fixed formatting hint selected locally from the bundle ID and browser host
    │  cleaned text
    ▼
inserted once through native paste, if the destination is still current;
otherwise saved to history. With no cleanup provider, raw text lands directly.
The temporary clipboard lease restores all original representations unless
the user has copied something new.
```

Local state is JSON in `~/Library/Application Support/Parla/`: `settings.json`,
`history.json`, `dictionary-proposals.json`, `scratchpad.txt`, `models/`,
`recordings/`. No SQLite, no server, no account. Permissions: Microphone +
Accessibility (the same grant covers the hotkey tap, the AX focus probe and the
synthetic keystrokes).

## The load-bearing split: reducer + interpreter

`Sources/ParlaCore/DictationSession.swift` (625 lines) is the whole dictation
flow as a **pure reducer**: `(State, Event) -> (State, [Effect])`. Foundation
only — no AppKit, no AVFoundation, no whisper, no networking, no clock. Effects
are **data, not closures**: `.insertText`, `.polish`, `.hud`, `.appendHistory`,
`.replaceTailIfOurs(expect:erase:append:…)`. Every branch of the landing policy,
the stale-generation rules and the transform safety ceiling is therefore a value
a test can assert on without a mic, a model or a network.

`Sources/Parla/Dictation.swift` (672 lines) is the **interpreter**, and the only
place that touches AppKit, Accessibility, whisper or HTTP.

Two rules hold it together. Both exist because violating them caused real bugs
that are on the record:

1. **Effect order is the contract.** The interpreter runs effects in the order
   they arrive and never reorders. That keeps insertion and history effects in
   order, and the warm HEAD request ahead of a
   possible 574 MB model reload. Effects that dispatch further events
   (`recorder.start()` reporting `.recorderStarted`, the focus probe reporting
   `.focusSampled`) must **append to a drain queue** rather than splice a nested
   effect list into the middle of the one currently running — see
   `DictationSession.send(_:perform:)`. Without the queue the ordering claim is
   false exactly where it matters most.
2. **The machine never queries the world.** Anything a decision needs — focus
   target, frontmost bundle ID, whether the typed text is still ours, whether
   the latched selection still matches — is sampled by the interpreter on the
   main actor in the same turn it dispatches the event, and rides along in
   `LandingProbe` / `TransformProbe`. This is why the secure-field re-check at
   landing sees where focus is *now* rather than at fn-down, and why every AX
   call stays in the shell.

Two more structural points worth knowing before editing either file: the machine
is **stateless with respect to work in flight** (a new fn-down is legal in every
state and always wins; an old leg's completion finds itself stale by generation
number), and `state` is an enum carrying `Settings`, so off-main readers never
touch it — they read the `capturingGen` lock mirrored on main before every
effect.

`main.swift` is **499 lines of app wiring** (458 when the machine was extracted,
down from 1364): the delegate's stored properties, launch, permissions, model
load/unload watcher, menu-bar and main-menu construction. `StatusMenu.swift`
(209) and `ModelInstaller.swift` (94) were split out of it.

## ParlaCore, piece by piece

| file | owns |
|---|---|
| `DictationSession` | the flow reducer above |
| `AudioRecorder` | capture; `PreRollRing` (1 s ring, ≤0.45 s prepended, dropped if stale or if media was playing) and `Resampler` (one reused `AVAudioConverter`, rebuilt only on format change) live here |
| `Streaming` | `StreamWindow` — confirmed prefix + cut point, so long dictations don't re-transcribe from zero each pass |
| `Transcriber` | the whisper.cpp context |
| `ModelCatalog` | the three fetchable models, each pinned to a SHA-256 read from HuggingFace's own LFS oid; download verification, paths. Default is still `base.en` — the better models are one click away in the Hub |
| `Cleanup` | prompt building, the Anthropic client, `CleanupSanitizer`, and `PromptCache` (decides whether a `cache_control` block would actually be honoured for the model in use — an inert block is worse than none) |
| `CleanupFactory` / `OpenAICompatClient` | provider selection and key resolution per provider; any OpenAI-compatible endpoint, key optional so a local server works |
| `Pipeline` | the transcript/clean path the app **and** the eval both run, so they can't drift |
| `Inserter` | Native paste, Unicode streaming helpers, destination identity, browser context, focus classification; nothing deletes without proving what it deletes |
| `ClipboardDelivery` | Temporary pasteboard lease; preserve all representations, restore only while still owning the board |
| `LiveTyper` | the diff and swap plan behind every tail replacement |
| `TextRules` | bundle ID → `AppCategory`, terminal/chat newline flattening, the RMS silence guard |
| `History` | `history.json` plus `PipelineMetrics` (per-dictation timings and token counts, derived from the same `Trace.Stamp` vocabulary) |
| `RecordingStore` | writes the dictation's audio to disk *before* whisper and deletes it the moment it returns; secure-field audio deleted first, 7-day retention, `PARLA_KEEP_RECORDINGS=1` turns it into an eval-corpus collector |
| `DictionaryLearner` | turns a hand-correction over Parla's own output into a *proposal*; nothing is ever auto-applied (the AX observation that feeds it is in `Parla/Dictation.swift`) |
| `Trace` | env-gated (`PARLA_TRACE=1`) one-line latency budget per dictation; off is a bool test, because one stamp is taken on the audio thread |
| `Eval` | the WER normalizer and scorer — one function for both sides of every comparison |
| `Hotkey` | `HotkeyMonitor` (its own state machine) and rebindable `KeyChord` bindings, matched on the exact modifier set |
| `Settings` | JSON, tolerant decode throughout — one bad field must never reset a user's file |
| `UpdateCheck` | throttled GitHub Releases check; fails silently |

App side beyond the interpreter: `HUD` (the pill), `Hub/` (SwiftUI window —
General, Cleanup, Dictionary, Snippets, History, Privacy, plus onboarding) and
`Scratchpad`.

## Phases

### Phase 1 — local-first Mac MVP — **done**

Hotkey → whisper.cpp → cleanup LLM → keystroke insertion, all local except the
cleanup call. Of what Phase 1 said it would skip: streaming ASR was built anyway
(as a shadow stream, because it buys latency without touching the field), VAD
still does not exist (`StreamWindow.quietestCut` is a plain RMS scan, not VAD),
and there is no Windows client.

### Phase 2 — product features — **done**

Dictionary UI with learned proposals; snippets resolved in the prompt; command
mode (⇧+fn transforms the selection); app-aware tone by bundle ID; history with
paste-last and a scratchpad as a safe landing place; and a cleanup provider that
points at any OpenAI-compatible server, which is the zero-network path.

### Phase 3 (backend, sync, teams) — **untouched**

Nothing in this repo talks to a Parla server, because there is no Parla server.
The only network calls are the cleanup provider, the model download from
HuggingFace, and the GitHub Releases check. No accounts, no sync, no billing,
no cloud ASR route. The design sketch below stands as a plan, not a description.

### Phase 4 (enterprise) — **untouched**

No SSO, no SCIM, no org policy, no audit logs.

## Eval infrastructure — exists, with numbers

`parla-eval` scores two legs separately (`--asr-only`, `--cleanup-only`), both
sides normalized by the same `Eval.werTokens`, and reports zero-edit rate,
corpus WER, p50/p90 and failure rate (WER > 20 %). CI runs `parla-eval verify`,
which re-scores the committed `eval/results.json` offline and gates on **drift**
— same bytes in, different score out — rather than on an absolute threshold a
known-bad baseline would peg red forever.

Baseline (`eval/results.json`):

| leg | n | zero-edit | corpus WER | p50 | p90 | fail >20 % |
|---|---|---|---|---|---|---|
| asr (`base.en`, synthetic `say(1)` audio) | 7 | 2/7 | 4.3 % | 0.0 % | 21.4 % | 1 |
| cleanup (gpt-oss-120b via Groq) | 32 | 12/32 | 9.5 % | 0.0 % | 37.5 % | 8 |

Read those with the caveats that come with them: the ASR cases are synthetic
speech (no disfluency, no room tone, one speaker), so the ASR number is far
better than reality and is a regression signal only — **no recorded human audio
corpus exists yet**. `injection`, `lists` and `snippets` score 0 % WER, which is
the prompt fencing, the list formatting and the deterministic snippet path
working against real inputs. Zero-edit at 37.5 % against `product.md`'s 90 %
north star is the honest gap. Measured cleanup latency in the same file: p50
≈0.8 s, p95 7.4 s.

## Hard problems, re-ranked against reality

1. **Insertion reliability across apps** — still first, but no longer eyeballed:
   `parla-insert-check <bundle-id>` focuses a real app's text field, types known
   strings and reads them back. It reports SKIP, not PASS, for apps with no AX
   text value, and it carries a hard watchdog because an unresponsive target
   once hung it for ten minutes. It needs Accessibility and a running app, so it
   is a local command, not a CI job. Every transcript is still in local history
   as the escape hatch. Native paste uses a clipboard lease with conditional restoration.
2. **Nothing landing safely** — the case the original list didn't have a name
   for. No focus, a field that no longer provably ends with our text, focus
   moved into a password field mid-dictation: each has an explicit path in the
   reducer that parks the text in history and says so in the pill, and each is
   tested. With `historyEnabled` off, the pill says the text was discarded
   rather than implying it was saved.
3. **Self-correction handling** — prompt-side, and now measured: three
   `self-correction` cases, 1/3 zero-edit. Not solved, but visible.
4. **Latency feel** — shadow streaming plus the pre-roll ring covers the capture
   side; the cleanup POST is the long pole (p95 7.4 s in the historical baseline
   above). Delivery now waits for formatting and inserts once, avoiding unreliable
   raw-to-cleaned replacement in opaque editors at the cost of waiting for cleanup.
5. **Dictionary accuracy without retraining** — `initial_prompt` + LLM context,
   plus learned proposals the user approves. `base.en` still mangles
   "Kubernetes" in the eval; that finding is left in the baseline on purpose.
6. **Permission loss recovery** — the Hub reads `AXIsProcessTrusted()` and the
   app prompts at launch. Whether a mid-session revocation recovers gracefully
   is unverified.
7. Multilingual routing, model regressions at scale, enterprise trust — still
   Phase 3+, still hypothetical.

---

# Original decision record

Kept as written, before anything was built. Everything above supersedes it as a
description of the code; nothing below has been revised to match.

Two designs were on the table. Both reviewed; verdict and merged plan below.

## The two candidate designs

**A. Local-first (my original proposal)** — everything on-device: hotkey →
mic → whisper.cpp → LLM cleanup call → paste. No backend.

**B. Full cloud platform (your findings)** — streaming gateway, ASR router,
GPU fleet, personalization engine, sync, teams, SSO/SCIM, analytics — an
incumbent-scale production platform.

## Review verdict

Neither is wrong; they're different *stages*. Building B first is the classic
mistake — it's ~10 services and months of infra before the first word is
dictated. Building only A caps you at a single-user tool.

**Corrections to design B (your mermaid flow):**

1. **Personalization placement.** You had ASR → LLM → Personalization Engine →
   insertion. Wrong order: dictionary terms, snippets, style, and app context
   must be *inputs to the LLM prompt*, not a post-pass. A post-pass doing
   string replacement re-breaks grammar the LLM just fixed ("Kubernetes" vs
   "kubernetes" mid-sentence, snippet expansion inside a formatted list).
   Correct flow: **context builder → (transcript + context) → LLM → insertion**.
2. **ASR router is premature.** Routing "by language, accent, latency, load,
   model version" is a v3 concern. Whisper-family models are multilingual;
   one model + one fallback vendor covers v1–v2.
3. **Kafka/ClickHouse/K8s GPU pools** are listed as core; they're not needed
   until you have paying teams. Postgres + one inference box goes a long way.
4. Otherwise design B is correct as the *end state* — the service breakdown,
   data model, and hard-problems list are right, and "the hard part is
   insertion, not recording" is exactly right.

**Corrections to design A (mine):**

1. "No backend at all" is only true if cleanup is also local. If v1 calls a
   cloud LLM, the transcript (though not the audio) still leaves the device.
   Be explicit about it in the UI.
2. Local ASR quality: whisper.cpp `large-v3-turbo` on Apple Silicon is fast
   and good, but fine-tuned cloud models will beat it on names/jargon.
   The personal dictionary compensates — inject dictionary terms as a Whisper
   `initial_prompt` AND into the LLM cleanup prompt.
3. Push-to-talk means no VAD needed for v1 (the hotkey IS the voice-activity
   signal). VAD only matters for hands-free/toggle mode later.

## Phase 3 as planned — backend, only when multi-device/teams demand it

Add services in dependency order, not all at once:

```
Client ──TLS──► API gateway (auth, rate limit)
                  │
                  ├─► Sync service ── Postgres
                  │     dictionary, snippets, settings, history(opt-in)
                  │
                  ├─► Cloud ASR (optional per-user route)
                  │     GPU box w/ faster-whisper; vendor fallback
                  │     streaming (WebSocket) once latency matters
                  │
                  ├─► Cleanup LLM proxy (server-held API keys,
                  │     zero-retention vendor agreements)
                  │
                  └─► Billing (Stripe) · Teams (shared dict/snippets)
```

- Postgres for accounts/settings/dictionary; Redis for sessions; object
  storage only if users opt into history. Audio ephemeral by default —
  zero-retention is the *default*, not a toggle (beats incumbent posture).
- Privacy Mode enforced at the request layer (gateway strips
  retention/training flags), org-enforceable for enterprise.

## Phase 4 as planned — enterprise (only with a paying org waiting)

SSO/SAML, SCIM, org policy enforcement, audit logs, usage dashboards
(plain Postgres aggregates until scale forces ClickHouse), SOC 2 track.
