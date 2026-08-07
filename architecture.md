# Parla — Architecture

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

## Recommended architecture (phased)

### Phase 1 — local-first Mac MVP (shipped)

```
┌────────────── macOS menu-bar app ──────────────────┐
│                                                     │
│  Global hotkey (CGEventTap)  — hold to talk         │
│      │ down                                         │
│      ▼                                              │
│  AVAudioEngine mic capture (16 kHz mono PCM)        │
│      │ up                                           │
│      ▼                                              │
│  whisper.cpp (Metal, base.en by default)            │
│    initial_prompt = personal dictionary terms       │
│    shadow passes run during capture; fn-up          │
│      pays only for the unconfirmed tail             │
│      │ raw transcript                               │
│      ▼                                              │
│  Insertion: CGEvent Unicode keystrokes              │
│    no clipboard — transcripts stay in-app;          │
│    failures recoverable from local history          │
│      │ then, behind it                              │
│      ▼                                              │
│  Cleanup LLM (one API call; local or cloud)         │
│    prompt = transcript + dictionary + snippets      │
│           + active app name (from NSWorkspace)      │
│      │ polished text                                │
│      ▼                                              │
│  Swap: one atomic AX write over the typed text,     │
│    only when AX proves the text is still ours       │
└─────────────────────────────────────────────────────┘

Local state: JSON files — settings (incl. dictionary, snippets) and history —
plus a plain-text scratchpad.
Permissions: Microphone + Accessibility.
```

Latency budget: hotkey-up → text inserted in <2s. base.en does ~10s of
audio in well under 1s on M-series; the LLM call is the long pole (~0.5–1s
with a fast model), which is why the raw transcript lands first and the
polished version swaps in behind it.

**Transcribe while the user is still talking — shipped.** whisper.cpp runs
incrementally on the buffer during capture ("shadow streaming"), so at
hotkey-up only the unconfirmed tail is left to transcribe. Past ~15s of
unconfirmed audio the head is frozen at the locally quietest spot into a
confirmed prefix, so each pass stays O(tail) rather than O(whole utterance).
(For the Phase 3 cloud ASR path, also compress audio on the wire — Opus, not
raw PCM.)

What Phase 1 deliberately skips:
- live partials typed into the field — the streaming passes are shadow-only.
  Keystrokes posted while the hotkey is physically held merge with the
  modifier (fn+A opens the Dock), so the transcript lands as one insert on
  release. Re-enable only with a verified fix for the modifier merge.
- VAD — hands-free (fn+Space) shipped without it; the streaming cut point is
  a plain RMS scan for the quietest window, not real voice-activity detection
- Windows client — add after Mac UX is proven
- any backend — add in Phase 3

### Phase 2 — the product features (still no backend)

Everything below ships today except where noted.

- **Personal dictionary UI** — shipped (Hub → Dictionary; terms go into the
  whisper `initial_prompt` and the cleanup prompt). Auto-learn from the user's
  post-insertion edits (diff AX field content shortly after insert — the local
  feedback loop) is **not built**; the list is hand-edited.
- **Snippets** — shipped. Spoken cue → expansion, resolved in the LLM prompt
  (never by string replacement).
- **Command Mode / Transforms** — shipped. ⇧+fn reads the selected text via
  the AX API, applies the spoken instruction, writes back. Same pipeline,
  different prompt.
- **App-aware style** — shipped, in its cheap form: the frontmost app's name
  goes into the cleanup prompt with a tone instruction (casual for chat,
  formal for email, plain for code/terminals), and terminal/chat bundle IDs
  get newlines flattened so nothing typed spans lines. Per-app rules
  (camelCase/snake_case for IDEs) are not built.
- **History + copy fallback UI** — shipped (Hub → History with search and a
  Copy button; ⌃⌘V and the menu paste the last dictation). Re-running the
  pipeline on a stored entry — "retry" — is not built.
- **Local cleanup model option** — shipped, as the `openai-compatible`
  provider: point `cleanup.baseURL` at Ollama (or any OpenAI-compatible
  server, keyless is fine) → true zero-network mode. This is the
  differentiator cloud-only incumbents structurally can't offer: their
  transcription always leaves the device.

### Phase 3 — backend, only when multi-device/teams demand it

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

### Phase 4 — enterprise (only with a paying org waiting)

SSO/SAML, SCIM, org policy enforcement, audit logs, usage dashboards
(plain Postgres aggregates until scale forces ClickHouse), SOC 2 track.

## Eval infrastructure (start in Phase 1, tiny)

Design B is right that evals matter from day one — but day-one evals are a
script, not a pipeline:
- fixed set of ~50 recorded utterances (fillers, self-corrections, jargon,
  numbers, code terms) → run through pipeline → diff against golden outputs
- track: zero-edit rate, WER on names, latency p50/p95
- grow into a real regression suite when models/prompts start changing weekly

## Hard problems (ranked by when they bite)

1. **Insertion reliability across apps** — Phase 1, day one. Secure input
   fields, Electron apps, terminals all behave differently. Local history is
   the escape hatch when a transcript can't be landed (on by default, capped
   at 50 entries, and can be turned off — secure-field and cancelled
   dictations are never recorded either way). No clipboard involvement.
2. **Self-correction handling** ("at 5… actually 6") — prompt engineering +
   eval set; the LLM does this well if explicitly instructed.
3. **Latency feel** — Phase 1–2. Push-to-talk plus shadow streaming (shipped)
   covers it on-device; cloud streaming ASR stays a Phase 3 concern.
4. **Dictionary accuracy without retraining** — initial_prompt + LLM context
   covers most of it.
5. **Permission loss recovery** (macOS revokes AX on updates) — detect and
   re-prompt gracefully.
6. Multilingual routing, model regressions at scale, enterprise trust —
   Phase 3+.

## Build order

Steps 1–4 are shipped (no retry action, no dictionary auto-learn); 5 onward is
still ahead.

1. Mac MVP: hotkey → whisper.cpp → LLM cleanup → paste. (Phase 1)
2. Dictionary, snippets, history, retry/copy fallback. (Phase 2)
3. Explicit privacy story: local ASR always; optional local LLM = zero network.
4. Command Mode / transforms on selected text.
5. Backend + sync + billing when a second device/user needs it.
6. Teams, then enterprise, each only when demand exists.
7. Eval script from week one; grow it with the product.
