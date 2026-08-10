# Cost, Models & Monetization

Parla's marginal cost per user is **$0** — ASR is local, cleanup is BYOK. That fact determines everything downstream: which pricing models are available, which are structurally impossible, and which license keeps the paid-binary option open. This doc does the real arithmetic (per-dictation LLM cost, cloud ASR rates Parla avoids, local disk/RAM/compute/power), tabulates how 24 audited OSS dictation apps actually make money, and ends with the license decision Parla has to make *before* it has a second contributor.

The single most urgent finding is not financial: **Parla has no `LICENSE` file.** `ls | grep -i licen` in the repo root returns nothing and `README.md` never mentions a license. Under Berne, that is "all rights reserved" — the most restrictive possible state, and the one that makes the repo legally unusable by anyone who clones it.

---

## 1. What a Parla dictation actually costs

ASR: **$0.00**. `Sources/ParlaCore/Transcriber.swift` runs whisper.cpp v1.9.1 in-process against a local `ggml-base.en.bin`. No network call exists on the transcription path.

Cleanup: one non-streaming POST per dictation, `Sources/ParlaCore/Cleanup.swift:177` (Anthropic) or `Sources/ParlaCore/OpenAICompatClient.swift:62`. Prompt size, measured by reproducing `PromptBuilder.system` (`Cleanup.swift:41-76`) exactly:

| Component | Chars | ~Tokens |
|---|---|---|
| Base dictation system prompt (no dictionary/snippets/app) | 1,189 | ~297 |
| + app-tone sentence (`Cleanup.swift:73-76`) | 1,335 | ~334 |
| + dictionary line, per 20 terms | ~+200 | ~+50 |
| + snippets block, per snippet (`- "trigger" -> expansion\n`) | ~+40 | ~+10 |

Cost per dictation at the shipped default `cleanupModel = "claude-sonnet-5"` (`Sources/ParlaCore/Settings.swift:28`), Sonnet 5 list $3/$15 per MTok ([platform.claude.com pricing](https://platform.claude.com/docs/en/about-claude/pricing); promo $2/$10 through 2026-08-31):

| Dictation | In (sys+transcript) | Out | Cost @ $3/$15 | Cost @ $2/$10 |
|---|---|---|---|---|
| 20 words (a Slack reply) | 334 + 26 = 360 | ~26 | **$0.0015** | $0.0010 |
| 100 words (an email) | 334 + 130 = 464 | ~130 | **$0.0034** | $0.0023 |
| 1,000 words (a long note) | 334 + 1,300 = 1,634 | ~1,300 | **$0.0244** | $0.0163 |

Two things fall out of that table:

**The fixed prompt is a tax on short dictations.** At 20 words the 334-token system prompt is **93% of input tokens**. At 1,000 words it is 20%. Dictation is short by nature — the app is optimized for a hotkey press, not an essay.

**The tax is not cacheable at the current size.** Anthropic's minimum cacheable prompt is **1,024 tokens for Sonnet 5** and **4,096 for Haiku 4.5**; below that, `cache_control` is silently ignored ([prompt caching docs](https://platform.claude.com/docs/en/docs/build-with-claude/prompt-caching)). Parla's ~334-token prompt is under both. Cache reads are 0.1× input and 5-minute writes are 1.25×, so a **1,024-token** prompt beats a 334-token uncached one after ~4 calls inside the cache window — meaning *growing* the prompt past the threshold is cheaper than shrinking it, for anyone who dictates more than four times in five minutes. That is the opposite of the obvious optimization.

**Model swap is a 3–60× lever and it's already a one-line settings change.** All of these are reachable today through `Sources/ParlaCore/CleanupFactory.swift` with no code change:

| Model | $/MTok in | $/MTok out | 100-word dictation | vs Sonnet 5 |
|---|---|---|---|---|
| claude-sonnet-5 (Parla default) | 3.00 | 15.00 | $0.0034 | 1× |
| claude-haiku-4-5 | 1.00 | 5.00 | $0.0011 | 3.0× cheaper |
| gemini-2.5-flash | 0.30 | 2.50 | $0.00046 | 7.4× |
| gemini-2.5-flash-lite | 0.10 | 0.40 | $0.00010 | 34× |
| gpt-5-nano | 0.05 | 0.40 | $0.00007 | 47× |
| Ollama / LM Studio local | 0 | 0 | **$0.00** | ∞ |

Sonnet/Haiku prices from Anthropic's docs; Gemini and gpt-5 prices from Epicenter's committed model catalog (`apps/desktop/src-tauri/catalog/catalog.generated.json`, a pinned models.dev snapshot with `cost_input`/`cost_output` per model — `SOURCE.md`: *"Never fetched at app runtime."* 94 models, snapshot SHA256 `79627f3b5acc…`).

Epicenter's own routing note is the relevant advice: *"AVOID reasoning models (gpt-5-nano/mini, o4-mini, gemini-3.x-flash) — hidden reasoning tokens add 1–3s latency, fatal for polish"* (plan 030). Cost and latency point at different models here; cost says nano, latency says flash-lite or haiku.

**Nobody in the corpus computes this.** Every audited repo that supports BYOK cleanup has zero cost accounting: voicetypr (`no pricing math anywhere in the repo`), openless (`No token counting, no pricing math`), TypeWhisper (`no cost estimator, no pricing table`), hyprwhspr, freeflow, murmure, amical. Two exceptions worth naming: **Ghost Pepper** hardcodes USD/MTok rates in `ClaudePricing.swift` (Opus 15/75, Sonnet 3/15, Haiku 1/5, `cacheWriteMultiplier = 1.25`, `cacheReadMultiplier = 0.10`) and ships `estimateBuildCostRange(model:meetingCount:)` showing the user a range *before* they press go; **Pindrop** persists `enhancementPromptTokens`/`enhancementCompletionTokens`/`enhancementReasoningTokens` per transcription in `Pindrop/Models/PipelineMetrics.swift` — the right primitive for a cost display, which they then never built.

---

## 2. Cloud ASR — the bill Parla doesn't pay

For context on what "local by default" is worth. Per-minute list rates, searched 2026-08 ([Future AGI comparison](https://futureagi.com/blog/speech-to-text-apis-in-2026-benchmarks-pricing-developer-s-decision-guide/), [Coval benchmarks](https://www.coval.ai/blog/best-speech-to-text-providers-in-2026-independent-benchmarks-and-how-to-choose/)):

| Provider | Batch $/min | Streaming $/min | In corpus as |
|---|---|---|---|
| Groq (whisper-large-v3-turbo) | ~$0.0003–0.0007 | — | TypeWhisper, freeflow, Handy, openless |
| AssemblyAI | $0.0025 | — | TypeWhisper, openless, amical |
| ElevenLabs Scribe v2 | $0.0037 | $0.0065 | TypeWhisper, macparakeet, amical |
| Deepgram Nova-3 | $0.0043 | $0.0077 | TypeWhisper, openwhispr, amical, freeflow |
| OpenAI gpt-4o-transcribe | $0.0045 | — | TypeWhisper, freeflow, VoiceInk |
| **Parla (local base.en)** | **$0** | **$0** | — |

At Deepgram batch rates, a heavy dictator doing 30 min/day of speech costs **$3.87/yr** in ASR. That is small enough that cloud ASR is *not* a cost problem — it is a **privacy and latency** problem. This matters for tier design: metering ASR minutes, the model Epicenter chose (`TRANSCRIPTION_CREDITS_PER_MINUTE = 1`, `apps/api/worker/billing/catalog.ts`), only works when you host the ASR. Parla doesn't, so there is nothing to meter.

The one place cloud ASR bills bite is session accounting, and openless found it empirically. Issue #227 measured the same 5.224 s clip billed at **653 input audio tokens on turn 1 and 1,303 on turn 2** of the same realtime session; over 314 utterances / 40 sessions, **650,778 tokens billed vs ~87,147 fresh — 7.5× amplification**. `input_audio_buffer.clear` does not help. Fix was `realtime_conversation_history: "turn"` — delete each completed turn server-side. Irrelevant to Parla today, load-bearing if streaming cloud ASR is ever added.

---

## 3. Local cost: disk, RAM, compute

### Disk

Parla ships one model path (`Transcriber.swift:11-15`, `~/Library/Application Support/Parla/models/ggml-base.en.bin`) and one download URL (`main.swift:923`), though `scripts/download-model.sh` accepts `tiny.en` and `large-v3-turbo`. Sizes, from voicetypr's exact byte-count catalog (`src/vocalinux/utils/whispercpp_model_info.py:30-60`, `_WHISPERCPP_MODEL_SPECS`):

| Model | fp16 MB | q5_1 / q5_0 MB | q8_0 MB |
|---|---|---|---|
| tiny(.en) | 74 | 15 | 32 |
| **base(.en) ← Parla default** | **141** | **60** | 82 |
| small(.en) | 465 | 163 | 190 |
| medium | 1,463 | 568 | 823 |
| large-v3 | 2,952 | 1,170 | — |
| large-v3-turbo | 1,620 | **574** | 874 |

`base-q5_1` at **60 MB is 2.4× smaller than the `base` Parla ships and no worse**; `large-v3-turbo-q5_0` at 574 MB is 2.8× smaller than the fp16 turbo Parla's script can already fetch. Parla exposes no quantized variant at all. Every serious competitor does: voicetypr lists 29 variants, Handy's compiled-in `catalog.json` defaults small models to Q8_0 and ≥1B models to Q5_K_M with per-file SHA-256, TypeWhisper offers small at 483 MB vs quantized 216 MB.

### RAM

TypeWhisper's `benchmarks/asr/README.md` (M4 Pro 48 GB, macOS 15, uncontended) is the only committed RSS measurement in the corpus:

| Engine | Cold start | Peak RSS |
|---|---|---|
| parakeet-v3 | 0.38 s | 115–131 MB |
| whisper large-v3-turbo | 2.29 s | 274 MB |
| cohere transcribe | 73 s | **~11.6 GB** |

Parla holds one `whisper_context` for the process lifetime (`Transcriber.swift:17-26`, freed only in `deinit`) with **no idle unload**. Four corpus apps ship one: vocalinux (`src/vocalinux/model_keepalive.py`, 185 lines, default 300 s clamped 60–3600, shipped as PR #592 after issue #591 measured a resident Vulkan/CUDA context holding an Optimus dGPU out of D3cold — **battery gone in 1–1.5 hours with zero transcription**), voicetypr (`gpu_isolation = true` runs each transcription in a subprocess that exits: *"No GPU power draw between transcriptions (important for laptops)"*), hyprwhspr, epicenter (`UnloadPolicy::{Never, Immediately, AfterFiveMinutes, AfterThirtyMinutes}`, arming the timer on request *completion* via Rust field drop order). At 148 MB base.en this is a non-issue; at large-v3-turbo it is 1.6 GB resident 24/7.

### Compute — Parla's real local cost problem

`Sources/Parla/main.swift:696-760` runs a whisper pass every ~500 ms for the entire dictation. Two facts make most of it waste:

1. `self.liveTyping = false` is **hard-coded** at `main.swift:179`, so the `MainActor.run` block at `:735` returns immediately at `guard self.liveTyping else { return }`. Nothing is ever typed.
2. `confirmed` is only written inside the `tail.count > StreamWindow.threshold` branch (`main.swift:710-724`), and `StreamWindow.threshold = 15 * 16_000` (`Streaming.swift:20`). **Below 15 s of tail, `confirmed` stays `""`, `self.window` is never set (`main.swift:757-759`), and the entire loop produces nothing.**

Cost of that, using Parla's own committed measurement — *"a full 30s encode is only ~130-200ms warm with Metal + flash-attn"* (`Transcriber.swift:44-45`), and noting `audio_ctx` is deliberately left at the full 30 s window:

| Dictation | Passes (~1 per 0.5 s) | Metal compute | Useful output | Duty cycle |
|---|---|---|---|---|
| 5 s | ~10 | ~1.6 s | **none** | ~33% |
| 10 s | ~20 | ~3.3 s | **none** | ~33% |
| 60 s | ~120 | ~20 s | ~3 cuts | ~33% |

A 10-second dictation burns roughly **3.3 seconds of continuous GPU encode to produce zero bytes**, then pays a 21st pass in `finish()` for the actual transcript. This is the single largest avoidable energy cost in the app, and it is invisible because it never fails.

The corpus is unambiguous that idle/background compute is what gets a menu-bar app uninstalled: openless #491 measured 185 Hz UI event emission saturating the renderer and *crashing other apps*; VoiceInk #642/#634 measured **~713 minutes of CPU over 23 hours** at idle across three machines; vocalinux #258 *"Prolonged use appears to max out a CPU core... even when mic is off"*; TypeWhisper #290 measured Windows idle at 10–20% CPU from a 32 ms polling loop and **declined to fix it** ("fragile code"). Handy's own distilled requirement from that complaint cluster (#1279, #1792, #1872, #1371, #1408, #1005, #1775) is the one to adopt: *"measure idle CPU and post-dictation RSS as a release gate."*

### Watts and thermals

**No repo in the corpus publishes a watt figure, and neither does Parla.** Battery is only ever measured indirectly, as elapsed runtime (vocalinux #591 above) or CPU-minutes (VoiceInk #642). So the honest statement of Parla's power cost is a duty cycle, not a wattage:

| State | Parla's power-relevant work |
|---|---|
| Idle, no dictation | ~0 — no timer, no polling loop. `WaveformView` redraws only on real RMS pushes (`HUD.swift:435-462`); the CGEventTap is event-driven (`Hotkey.swift:112-133`). One `whisper_context` resident (~148 MB), not executing. |
| Recording, per second of speech | **~330 ms of Metal encode** (2 passes × ~165 ms) at ~33% GPU duty cycle, plus one `AVAudioConverter` allocated per ~85 ms tap buffer (`AudioRecorder.swift:115`) |
| Finalizing | one ~130–200 ms encode over the tail |

Parla's idle profile is genuinely good — better than most of the corpus, which is where the loud battery complaints come from. The recording profile is the problem: **~33% sustained GPU duty cycle for the entire dictation**, of which below 15 s *all* of it is discarded (above). Sustained Metal compute is the single largest power draw an Apple-silicon menu-bar app can generate short of video encode, and Parla generates it on every hotkey press.

Two things follow. First, this is a *thermal* concern only for hands-free sessions — a 5–15 s dictation cannot saturate a fanless M-series chip, but a latched `.handsFree` session (`Hotkey.swift`, fn+Space) has **no recording length cap** and `samples` grows unbounded at 64 KB/s, so a forgotten latch is an indefinite 33%-duty GPU load. Second, it is trivially measurable and nobody has measured it — the release gate is one command:

```sh
# Parla's own PID, 5 s of samples, during a dictation vs idle
sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n 5 --show-process-energy | grep -i parla
```

Until that number exists, treat §3's duty-cycle table as the budget and item 2 in the recommendations as the fix.

---

## 4. How the corpus monetizes

Twenty-four repos, four patterns. Nothing else exists.

| Repo | License | Model | Mechanics |
|---|---|---|---|
| **Beingpax/VoiceInk** | GPL-3.0 source, **paid binary** | Lifetime license | Polar (`api.polar.sh`), `trialPeriodDays = 7`, states `licensed/trial/trialExpired/unlicensed`, key in Keychain, device activate/deactivate. Enforcement is a **nag prepended to the pasted text** (`TranscriptionDelivery.deliverableText`), not a lock. `brew install --cask voiceink`. |
| **moinulmoin/voicetypr** | AGPL-3.0, paid binary | Lifetime license | `api.voicetypr.com`, `{licenseKey, deviceHash}` where deviceHash = SHA-256 of machine UUID. `OFFLINE_GRACE_PERIOD_DAYS = 90` licensed / `1` trial. Release builds **hardcode the host with no env override** — *"these endpoints carry license keys + device hashes, so an env-redirect would be a credential-exfiltration vector."* Paywall gates `preload_model` and `start_recording`. |
| **EpicenterHQ/epicenter** | apps+server AGPL-3.0-or-later, **libraries MIT** | Metered credits | `TRANSCRIPTION_CREDITS_PER_MINUTE = 1`, min 1/call. Free 50/mo + `FREE_TIER_MAX_CREDITS_PER_CALL = 2`. Pro $20/mo → 2,500 credits, $1/100 overage, 5 GB. Ultra $60 → 10,000 + rollover, $0.75/100. Max $200 → 50,000, $0.50/100. Annual $200/$600/$2,000. Credits **reserved-then-settled** so a failed call never burns them. No CLA. |
| **OpenWhispr/openwhispr** | MIT client, paid hosted cloud | Word-metered SaaS | `PAID_PLANS = {"pro","business","enterprise"}`, `/api/usage` → `{wordsUsed, wordsRemaining, plan, trialDaysLeft, entitlementSources}`. Team spaces, seats, referral dashboard, billing portal. `src/lib/upsell.ts` is a 24-line pure function. |
| **voquill/voquill** | apps+server AGPL-3.0, `enterprise/` proprietary | Stripe subs | `pro_monthly/yearly`, `team_monthly/yearly`. Free tier metered in **words/day**, enforced at `validateAvailability()` **only when transcription or post-processing is cloud** — pure-local users unmetered. |
| **altic-dev/FluidVoice** | GPLv3 core + **closed binary** | Sponsors | "Fluid Intelligence" is a proprietary local runtime linked into a GPLv3 app via `disable-library-validation`; the OSS build ships a pass-through no-op shim. *"We're keeping Fluid Intelligence private for now so we can sustainably offer the core dictation experience for free."* GPLv3 compatibility of this is, charitably, unsettled. |
| **moona3k/macparakeet** | GPL-3.0 | Sponsors (dormant plumbing) | `Sources/MacParakeetCore/Licensing/` retains a complete LemonSqueezy client + entitlement state machine, unlocked: *"the plumbing here exists so a future GPL-compatible paid distribution channel can be activated without re-implementing licensing from scratch."* |
| **cjpais/Handy** | MIT | None, on principle | *"Accessibility tooling belongs in everyone's hands, not behind a paywall."* No telemetry beyond the updater endpoint. |
| Muesli, pindrop, vibe, hyprwhspr, voxtype, amical, openless, yap, OpenSuperWhisper, freeflow, ququ, vocalinux, murmure, TypeWhisper*, parrot, ghost-pepper | MIT / Apache / AGPL | Donations only | Sponsors, Ko-fi, Tipeee, Venmo, opub.dev credits. Zero revenue evidence in any of them. |

\* TypeWhisper ships `LICENSE-COMMERCIAL.md` alongside AGPL-3.0-or-later — dual-license prepared, not exercised.

Two license-hygiene cautionaries: **digimata/parrot** and **matthartman/ghost-pepper** both display an MIT badge in their README with **no `LICENSE` file in the tree** (GitHub's API reports `license: null` for parrot). Parla is currently in that same state, minus the badge.

Direction of travel: **vocalinux migrated GPL-3.0 → AGPL-3.0** three days before its snapshot (commit `0685305`), and **voxtype** did the same. Nobody in the corpus moved the other way.

---

## 5. Which license keeps the paid-binary option

The corpus shows exactly one pattern that demonstrably supports selling a macOS dictation app while shipping source: **strong copyleft on the source, sell the signed binary + a license server.** VoiceInk (GPL-3.0) and voicetypr (AGPL-3.0) both do it, both ship on Homebrew, both put the license check in the *runtime*, not the license text. Note what that means legally: the license does not stop anyone building from source and patching out the check (voicetypr's own tracker has issue #60, users doing exactly that) — it stops a competitor **repackaging Parla as a closed product**, which is the actual threat.

Constraints specific to Parla:

- **Parla vendors whisper.cpp v1.9.1 as a binary xcframework** (`Frameworks/whisper.xcframework`, `Package.swift:8-16`). whisper.cpp is MIT, so it imposes no copyleft obligation upward. No conflict with any choice below.
- **Parla is not a network service.** AGPL §13 adds nothing functional over GPL-3.0 for a menu-bar app with no server. It is chosen anyway by voicetypr/Epicenter/voquill/vocalinux/voxtype as a stronger deterrent against SaaS repackaging.
- **Dual-licensing requires sole copyright or a CLA.** Parla has zero external contributors right now. This is the cheapest moment in the project's life to decide; Epicenter explicitly has **no CLA** and therefore cannot relicense contributions.
- **`ParlaCore` is genuinely reusable.** `Streaming.swift` (pure `StreamWindow`), `LiveTyper.swift` (pure grapheme diff), `TextRules.swift`, `Eval.swift`, `Settings.swift` have no AppKit dependency and are the kind of thing Epicenter deliberately put under MIT while keeping the app AGPL.

The recommendation is Epicenter's split, adapted:

- **`Sources/Parla/` (the app) → AGPL-3.0-or-later**, plus a `LICENSE-COMMERCIAL.md` stub in TypeWhisper's shape reserving the paid-binary right.
- **`Sources/ParlaCore/` → MIT**, so the windowing/diff/rules code is reusable and Parla accrues goodwill without giving away the product.

Reject: MIT-everything (no repo in the corpus monetizes from it), FluidVoice's closed-blob-inside-GPLv3 (its own dossier flags the compatibility as unsettled), and BSL/Commons Clause (not present anywhere in 24 repos — no ecosystem precedent).

---

## 6. Pricing implications for Parla's tiers

Parla's cost structure forecloses most of the corpus's models:

| Model | Works for Parla? | Why |
|---|---|---|
| Per-minute credits (Epicenter) | **No** | Nothing to meter — ASR is local, cleanup is the user's API key. Epicenter's `TRANSCRIPTION_CREDITS_PER_MINUTE = 1` prices *their* server cost. |
| Word-metered SaaS (OpenWhispr, voquill) | **No** | Same. voquill only meters `when transcription or post-processing mode is cloud`; Parla is neither. |
| Subscription | **Weak** | Nothing recurring is being consumed. voicetypr's README argues the counter-position and it is the correct one: *"a lifetime license keeps local models unmetered: no subscription, per-minute API fee, or cloud usage quota."* |
| **Lifetime license on the binary** (VoiceInk, voicetypr) | **Yes** | Matches a $0-marginal-cost product. Prices the *build* — signing, notarization, auto-update, support — not usage. |
| Donations (16 repos) | **Yes, at $0** | Zero evidence of revenue anywhere in the corpus. |

If a lifetime tier ships, three things from the corpus are load-bearing:

1. **Free tier must be genuinely usable, not crippled.** voicetypr gates `start_recording` behind the license and has a public issue (#15) about a 7-day offline grace blocking multi-week offline use of a product sold as *"lifetime"*. Its own fix was `OFFLINE_GRACE_PERIOD_DAYS = 90`. Do not gate the dictation path.
2. **Never enforce by corrupting output.** VoiceInk prepends `usageRestrictionMessage` to the pasted text — the transcript literally lands in the user's document with a nag in front of it. Parla's insertion path (`Sources/ParlaCore/Inserter.swift`) is AX-verified and never touches the clipboard; injecting marketing copy into it would break the one invariant the app is built around.
3. **The bill the user actually sees is their cleanup key, and Parla hides it.** A user on Sonnet 5 doing 40 dictations/day pays **~$50/yr** to Anthropic; the same user on gemini-2.5-flash-lite pays **$1.50/yr**. Parla shows neither number anywhere. That is a support burden and a churn risk in a product whose default model is the most expensive option available.

---

## What Parla should do

**1. Add `LICENSE` — AGPL-3.0-or-later for `Sources/Parla/`, MIT for `Sources/ParlaCore/`. (S)**
Repo root currently has no license file and `README.md` never mentions one, which means all rights reserved. Add `LICENSE` (AGPL-3.0-or-later), `Sources/ParlaCore/LICENSE` (MIT), a `## License` section in `README.md`, and a `LICENSE-COMMERCIAL.md` stub in TypeWhisper's shape reserving the paid-binary right. Do this before the first external PR — Epicenter has no CLA and consequently cannot ever relicense contributions.

**2. Kill the shadow-stream pass below the freeze threshold. (S)**
`Sources/Parla/main.swift:696-760` runs a full 30 s-window whisper encode every ~500 ms, and below `StreamWindow.threshold` (15 s, `Streaming.swift:20`) writes nothing — `confirmed` stays `""` and `self.window` is never set at `:757`. With `liveTyping` hard-disabled at `:179`, that is ~3.3 s of Metal compute for a 10 s dictation producing zero bytes. Gate the loop: skip the tail pass entirely until `snap.count > StreamWindow.threshold`; keep the head-cut pass. One `guard`, and it removes ~33% GPU duty cycle from every sub-15 s dictation.

**3. Default `cleanupModel` to `claude-haiku-4-5`, not `claude-sonnet-5`. (S)**
`Sources/ParlaCore/Settings.swift:28`. 3× cheaper per dictation ($0.0011 vs $0.0034 at 100 words), materially faster, and cleanup is a constrained rewrite — Epicenter's plan 030 explicitly routes polish away from large/reasoning models for latency. Keep Sonnet reachable via the existing Hub field.

**4. Surface the per-dictation token count and running cost. (S/M)**
`Sources/ParlaCore/Cleanup.swift:192-214` and `OpenAICompatClient.swift:77-121` already parse the response body; both providers return usage. Store `promptTokens`/`completionTokens` on `HistoryEntry` (`Sources/ParlaCore/History.swift:6-16`) — this is Pindrop's `PipelineMetrics.swift` primitive — and show a monthly estimate on the Hub's AI Cleanup page next to the model field, using a small hardcoded price table in Ghost Pepper's `ClaudePricing.swift` shape (with the "re-check against the pricing page each release" comment). Zero repos in the corpus do this; it is a differentiator and it prevents bill shock.

**5. Add quantized model options to `scripts/download-model.sh` and the Hub. (S)**
`base-q5_1` is **60 MB vs the 141 MB `base` Parla ships**; `large-v3-turbo-q5_0` is **574 MB vs 1,620 MB** for the turbo the script can already fetch (voicetypr `whispercpp_model_info.py:30-60`). The download URL is hardcoded once at `Sources/Parla/main.swift:923` and the path once at `Transcriber.swift:11-15`. Make both take a model id and add per-file SHA-256, which Handy's compiled-in `catalog.json` does and Parla's `installModel(from:)` (`main.swift:947-956`) — which *deletes the existing model before the move* — does not.

**6. Add an idle model-unload policy. (M)**
`Transcriber.swift:17-26` holds the whisper context for the process lifetime with no unload path. At 148 MB base.en this is fine; at large-v3-turbo (item 5) it is 1.6 GB resident 24/7 in a menu-bar app. Copy Epicenter's shape: `UnloadPolicy::{Never, AfterFiveMinutes, AfterThirtyMinutes}` armed on *completion* not on start, with reload folded into the existing `loadModel()` + warm-up at `main.swift:762-782`. vocalinux shipped `model_keepalive.py` only after issue #591 measured an idle GPU context draining a laptop battery in 1–1.5 h with zero transcription.

**7. Grow the system prompt past 1,024 tokens *only if* prompt caching is wired. (M, defer)**
Parla's ~334-token prompt (`Cleanup.swift:41-76`) is below Sonnet 5's 1,024-token cache minimum, so `cache_control` is silently ignored. If item 4's telemetry shows heavy short-dictation usage, the counter-intuitive optimization is to *add* content (few-shot examples from `docs/research/06-formatting.md`) to cross the threshold and mark it cacheable — break-even at ~4 dictations per 5-minute window, then 10× cheaper on input forever after. Do not do this speculatively; it costs latency and tokens if the usage pattern is bursty rather than sustained.

**8. Cap hands-free recording length. (S)**
The `.handsFree` latch (fn+Space, `Sources/ParlaCore/Hotkey.swift`) has no maximum duration: `AudioRecorder.samples` grows unbounded at 64 KB/s (~230 MB/hr) and the `stream()` loop holds a ~33% GPU duty cycle for the whole session. A forgotten latch is an indefinite sustained Metal load — the only thermal risk in the app, and the one case item 2's sub-threshold gate does *not* fix. Add a ceiling (10 min is generous for dictation) that auto-stops and finalizes, mirroring the abort path already wired through `shouldAbort:` at `main.swift:727-733`. Cheap insurance against the complaint class that got openless, VoiceInk, and vocalinux uninstalled.

**9. Do not build metered pricing. (S — a decision, not code)**
Parla's marginal cost is $0 and there is nothing to meter without hosting ASR. If Parla ever charges, it is a lifetime license on the signed/notarized/auto-updating binary in VoiceInk's and voicetypr's shape — and the enforcement must not touch `Sources/ParlaCore/Inserter.swift`, whose whole design (AX-verified, never-clipboard, never-delete-foreign-text) is incompatible with VoiceInk's prepend-a-nag approach.

Sources: [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing) · [Anthropic prompt caching](https://platform.claude.com/docs/en/docs/build-with-claude/prompt-caching) · [STT API pricing 2026](https://futureagi.com/blog/speech-to-text-apis-in-2026-benchmarks-pricing-developer-s-decision-guide/) · [Coval STT benchmarks](https://www.coval.ai/blog/best-speech-to-text-providers-in-2026-independent-benchmarks-and-how-to-choose/)
