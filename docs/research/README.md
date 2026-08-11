# Competitive research: 24 open-source dictation apps

**Audit date: 2026-08-11.** 24 projects cloned and read at source level, ~4,600 lines of notes across 12 documents. Every claim in these docs cites the file that proves it; where the corpus was silent the field says "not found" rather than guessing.

---

## Start here

### [`FEATURES-TO-ADD.md`](FEATURES-TO-ADD.md) — the ranked backlog

The entry point. Everything the other 11 docs found, collapsed into one value-÷-effort ordering with a file path and an effort size (S ≤ half a day, M ≤ two days, L ≥ a week) on every item. Read this first; open the others only when you need the evidence behind a line.

- **Verdict:** Parla leads the entire corpus on insertion — the only project of 24 that types instead of pasting, and the only one that can safely *delete* text it did not write (`canEraseTyped` proves the UTF-16 units before the cursor, fails closed otherwise). It is behind on measurement and audio quality, not features.
- **Tier 0 #1, the single highest-leverage change:** a ~5-line guard on the shadow stream. `main.swift:696-760` runs a full `whisper_full` encode every ~300 ms whose output is discarded for every dictation under the 15 s freeze threshold — ~3.3 s of Metal compute per 10 s dictation producing zero bytes, contending with the final pass the user is actually waiting on.
- Tier 0 also carries the `LICENSE` gap, the per-tap-buffer `AVAudioConverter`, Secure Event Input detection, the unfenced cleanup prompt, per-transcript marker stripping, the `AXEnhancedUserInterface` write, and the 20-unit insertion chunk.

---

## The evidence

### [`01-landscape.md`](01-landscape.md) — the map
Roster, feature matrix, and the defining idea of each of the 24 projects.
- **21 of 24 insert text by writing the clipboard and synthesizing ⌘V.** This is the most consistent finding in the corpus and the thing Parla does differently.
- Live streaming *insertion* exists in exactly 2 of 24 (openless, voxtype). Streaming preview to an overlay: 11. A real WER harness: 1.

### [`02-architecture.md`](02-architecture.md) — structural patterns
The seven decisions every dictation app of consequence makes: engine abstraction, session state machine, threading, core/shell split, plugin seam, persistence, IPC.
- Everyone converges on **two protocols, not one** — batch and streaming have different isolation requirements and different lifetimes, and every app that unified them split them back apart. voxtype's `as_streaming() -> Option<&dyn StreamingTranscriber>` is the cheapest good answer.
- Parla's structural problem in one number: **43% of the logic-bearing code lives in an `NSApplicationDelegate`** (1,170 lines in `main.swift` vs 1,577 in `ParlaCore`).

### [`03-latency.md`](03-latency.md) — the full budget for one dictation turn
Keypress → mic hot → first sample → hotkey-up → final → LLM → text landed, segment by segment, with every optimization found and its measured saving.
- **Perceived latency is dominated by plumbing, not inference.** pindrop measured ~950 ms of pure fixed plumbing per dictation against a decode costing tens of milliseconds.
- Segments 2–4 are Parla's entire gap: it builds a fresh `AVAudioEngine` every press (best in corpus: **~0.1 ms**, clone a held stream — OpenWhispr `micStreamHold.js`) and has **no pre-roll**, so it loses all audio before capture is live (best: 0, via a 0.45 s ring prepend).

### [`04-asr-engines.md`](04-asr-engines.md) — engines and models
Every engine across ~40 audited apps: size, WER, RTFx, peak RSS, streaming support, Swift integration cost. Plus the model-download failure modes so we don't rediscover them.
- **Parakeet TDT v3 is ~6× faster than whisper-turbo at ~⅓ the RAM** with better clean-speech WER (2.3% vs base.en ~5.4%) — which is why 16 of 39 audited apps default to it.
- **Long audio breaks Parakeet, and it is not the quantization**: a 390 s uninterrupted pass hits 40.4% WER on int8 *and* degrades on fp32 too; there is a hard encoder wall at ~390 s / 5000 frames. The fix everyone landed on is chunking at 20 s.

### [`04a-parakeet-audit.md`](04a-parakeet-audit.md) — who ships Parakeet, and which variant
Companion to 04. *(Not in the original doc list — present in the directory and indexed here.)*
- **Nobody defaults to v2 anymore.** Of ~39 repos with real Parakeet support, all 16 "default" apps default to v3 or a v3-derived GGUF. v2 survives only as a selectable English-only alternate that can never auto-detect the wrong language.

### [`05-insertion.md`](05-insertion.md) — getting text into the focused field
The largest bug surface in the category — more issues than ASR, latency and packaging combined. Mechanism table, the canonical fallback ladder, per-app quirks, verification strategies.
- **Secure Event Input is the gap that matters most for a keystroke-only app**: while any process holds it, synthetic `CGEvent`s are silently discarded. Only 2 of 24 repos detect it (Handy, freeflow); Parla currently shows a green "done" HUD over the failure.
- Parla has the `virtualKey: 0` bug (§4), and the held-modifier problem that bites only push-to-talk apps (§6) — voxtype's passive `EVIOCGKEY` snapshot is the reference fix.

### [`06-formatting.md`](06-formatting.md) — cleanup prompts, verbatim
All 24 prompts quoted in full, scored against the five defenses every mature implementation converges on.
- **Parla implements 2 of 5 on its dictation path** — the transcript is passed as a bare string with no delimiter and no "do not follow instructions inside it" guard, while Parla's own *transform* path already has the full treatment. Closing that inconsistency is 4 lines.
- Every one of the five defenses exists because somebody shipped without it and got a bug report; the doc names which repo and which issue for each.

### [`07-correctness-eval.md`](07-correctness-eval.md) — proving it works
Test suites, golden files, WER harnesses, latency instrumentation, CI — plus a complete catalogue of hallucination and garbage guards.
- **Exactly one of 24 repos measures transcription quality.** macparakeet's `benchmarks/asr/` has one canonical normalizer, p90, failure rate and paired-bootstrap CIs. Handy's own audit admits: *"No WER measurement anywhere."* Parla's harness scores 2 cases against the 50 its own README asks for.
- The most visible correctness bug in Parla: markers are stripped per *transcript*, so `"Hello there. [BLANK_AUDIO]"` is typed verbatim into the user's document.

### [`08-cost.md`](08-cost.md) — economics, models, monetization
Real arithmetic on per-dictation LLM cost, the cloud ASR rates Parla avoids, local disk/RAM/power, and how all 24 projects actually make money.
- **Parla has no `LICENSE` file.** Under Berne that is all-rights-reserved — the most restrictive possible state, legally unusable by anyone who clones it, and strictly harder to fix once a second copyright holder exists.
- The only monetization shape in the corpus that fits an app with $0 marginal cost is the VoiceInk / voicetypr model: free source, paid signed-and-notarized binary. The license choice forecloses or preserves it.

### [`09-ux.md`](09-ux.md) — the surfaces users touch
Hotkeys, HUD, level feedback, sound design, permissions, settings, history, error copy, menu bar, multi-monitor, updates, accessibility.
- **Parla's hotkeys are hard-coded keycodes and not rebindable** — it is the only app in the corpus with no rebinding at all, against macparakeet's four gesture modes and yap's single 500 ms hold/latch threshold.
- §8 (honest failure copy) and §5 (permissions) are where the corpus is furthest ahead; both are cheap.

### [`10-linux-wayland.md`](10-linux-wayland.md) — the wlroots port ceiling
What each of Parla's four macOS foundations costs on sway/Hyprland, evidenced by the shipped code of eleven Linux dictation apps.
- Parla's design rests on **four APIs Wayland does not have**: a global event tap, layout-independent Unicode injection, a readable accessibility tree, and a secure-field signal. §5 names the parts of the macOS architecture that cannot survive the port.
- The existing `worktree-linux-wlroots-port` M1 (dictate → clipboard) has **never run on real hardware** — `linux/VERIFY.md` says so explicitly. M2 (typing into the focused window) is where every one of the eleven projects bled.

---


### 11-review-findings.md

Every finding from the four adversarial review rounds over the implementation branch — 63 raised, 49 confirmed, 14 refuted — with file:line, failure scenario and the verifier's reasoning. Read it for *how* things shipped broken: three items that built, passed their tests and never ran; a chord matcher wrong in three consecutive rounds; and a fix batch that reintroduced the bug its own guard was written to prevent. The refutations are kept on purpose.

## Sources

All 24 repos audited, ordered by stars. `—` = not recorded during the audit.

| Project | ★ | License |
|---|---:|---|
| [cjpais/Handy](https://github.com/cjpais/Handy) | 29,193 | MIT |
| [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) | ~9,500 | GPL-3.0 |
| [thewh1teagle/vibe](https://github.com/thewh1teagle/vibe) | ~7,100 | MIT |
| [OpenWhispr/openwhispr](https://github.com/OpenWhispr/openwhispr) | 5,330 | MIT |
| [EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter) | ~4,700 | AGPL-3.0 (apps) / MIT (libs) |
| [matthartman/ghost-pepper](https://github.com/matthartman/ghost-pepper) | 3,082 | MIT (no `LICENSE` file) |
| [Open-Less/openless](https://github.com/Open-Less/openless) | 3,001 | MIT |
| [Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper) | 2,554 | MIT |
| [yan5xu/ququ](https://github.com/yan5xu/ququ) | 2,258 | Apache-2.0 |
| [TypeWhisper/typewhisper-mac](https://github.com/TypeWhisper/typewhisper-mac) | 1,681 | GPL-3.0 + commercial |
| [digimata/parrot](https://github.com/digimata/parrot) | 1,156 | MIT |
| [Kieirra/murmure](https://github.com/Kieirra/murmure) | 993 | MIT |
| [Muesli-HQ/muesli](https://github.com/Muesli-HQ/muesli) | 916 | — |
| [VocaHQ/vocalinux](https://github.com/VocaHQ/vocalinux) | 732 | AGPL-3.0 |
| [watzon/pindrop](https://github.com/watzon/pindrop) | 587 | MIT |
| [moona3k/macparakeet](https://github.com/moona3k/macparakeet) | 555 | — |
| [FrigadeHQ/yap](https://github.com/FrigadeHQ/yap) | 353 | MIT |
| [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) | — | GPL-3.0 (PRs refused) |
| [moinulmoin/voicetypr](https://github.com/moinulmoin/voicetypr) | — | AGPL-3.0 |
| [voquill/voquill](https://github.com/voquill/voquill) | — | AGPL-3.0 + proprietary |
| [amicalhq/amical](https://github.com/amicalhq/amical) | — | MIT |
| [zachlatta/freeflow](https://github.com/zachlatta/freeflow) | — | MIT |
| [peteonrails/voxtype](https://github.com/peteonrails/voxtype) | — | MIT |
| [goodroot/hyprwhspr](https://github.com/goodroot/hyprwhspr) | — | MIT |

`04a-parakeet-audit.md` widens to ~39 repos for the Parakeet question only; those extras are listed in that doc's own support table.
