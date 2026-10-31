# Open-source competitor code research — 28 October 2026

The strongest near-term improvements are consistent foreground HUD ownership, configurable app/site cleanup profiles, bounded vocabulary, optional exact replacements, desktop cleanup retry, and a quality gate that measures paragraph structure. Broader language support on Android and real app/device qualification come next. Alternative speech engines deserve a controlled comparison; source adoption elsewhere is insufficient reason to change Parla's defaults.

This research inspected **33 pinned competitor repository trees**, compared them with current Parla source, and produced **57 deduplicated backlog entries**. This is deep, targeted source research across the product stack, not an exhaustive audit of every file or every open-source competitor. Recommendations distinguish observed implementation, deliberate product boundaries, experiments, and separate product bets. No accuracy, speed, cost-saving, or universal app-compatibility claim was established by this work.

The [web expansion](05-web-expansion.md) adds 13 inspected trees, nine entries and five detailed evidence documents. It distinguishes new-to-this-audit projects from new launches and discloses derivative provenance.

## Read the results

| Document | Purpose |
|---|---|
| [Web expansion and new findings](05-web-expansion.md) | Additional competitors, B49–B57, screening and independent refutations |
| [Ranked backlog](BACKLOG.md) | 57 opportunities, ordering, effort, dependencies, acceptance checks and source pointers |
| [App/platform support](APP-SUPPORT.md) | Current code policy versus unverified runtime support; concrete qualification targets |
| [Current baseline](01-current-baseline.md) | Independent audit, counterevidence and features already implemented |
| [Cleanup and context](02-cleanup-context.md) | Profiles, replacements, vocabulary, workflows, privacy boundaries and provider resilience |
| [Delivery and platforms](03-delivery-platforms.md) | Paste restoration, Linux backends, Android recognition integrations and audio sharing |
| [Speech and workflows](04-speech-workflows.md) | Speech engines, VAD, models, recovery, exports, automation and mobile architecture |
| [Sources and method](SOURCES.md) | Full revision pins, licenses, inspected areas, exclusions and research limitations |
| [Source manifest](sources.json) | Machine-readable repository, revision and commit-date inventory |

First corrective action from the expansion: **B49**. Older empty/error completion effects can hide or replace a newer recording HUD; independent source checks confirmed the narrow presentation path. State/menu ownership remains protected. **B50** would deliberately extend cancellation to pending work. See the [evidence](10-cancellation-and-feedback.md); no fix or runtime reproduction was performed.

## Recommended starting sequence

1. **Make quality comparisons trustworthy:** add paragraph-sensitive model-result checks and meaningful human speech references. Keep existing WER and case/punctuation comparisons. These are prerequisites for changing model or prompt defaults.
2. **Improve daily cleanup:** small app/site profiles with visible precedence, a vocabulary token budget, opt-in literal replacements, and minimal-pair fixtures for meaningful fillers, numbers and identifiers.
3. **Improve recoverability and portability:** copy original/retry cleanup from desktop history, a usable failed-audio recovery view, credential-free vocabulary import/export, and macOS Keychain migration.
4. **Qualify broader use:** test real target apps and physical Android devices; add Android multilingual model choices and standard recognition entry points. Qualify the current Linux milestone before broadening its backends.
5. **Run bounded experiments:** one alternate ASR family, padded speech detection, and receipt-aware clipboard restoration. Promote only with measured benefit and no loss of safety or compatibility.

These are ordered work packages, not a proposal to implement every row simultaneously. Effort estimates exclude physical-device qualification and are rough engineering sizes. The backlog separates foundation, daily workflow, experiments, platform initiatives and larger expansion bets.

## Concrete examples of improvements

- A user could disable cleanup in an IDE, retain ordinary cleanup in Slack, and use an email style on a particular web domain without changing global settings. Existing app categories already handle common destinations; profiles add user control.
- A failed provider request could be retried from the stored raw transcript without speaking again. Android already offers retry/original actions; this is primarily desktop parity.
- An explicit replacement could consistently render “open AI” as “OpenAI” without asking an LLM. Existing whole-utterance snippets remain conservative; inline replacement would be a separate opt-in feature.
- An Android app using the standard recognition activity or service could invoke Parla directly. That does not imply every keyboard microphone button can use it.
- A paragraph-only regression could fail a formatting check while retaining the same WER. Today all-whitespace normalization makes that regression invisible to zero-edit and WER, although existing unit tests protect formatting policy and delivery.

## Existing strengths to preserve

Parla already has guarded cleanup prompts, raw fallback and output checks, selected-text command mode, deterministic whole-utterance snippets, dictionary correction suggestions, local-server cleanup, native clipboard paste with complete snapshot/ownership-aware restoration, secure-input refusal, destination identity checks, optional warm mic/pre-roll, model verification and idle unload, multilingual desktop decoding, bounded local history and crash-audio recovery. The Android working tree already contains a voice IME, floating microphone, safe insertion, cleanup styles, encrypted endpoint-scoped credentials and pending-output recovery.

The August research and its original backlog were useful leads, but several “missing feature” descriptions are stale. See the baseline and each dossier's checked-fine list before creating implementation tickets. Unknown apps are not categorically blocked from paste: **classification, delivery mechanism and runtime qualification are separate facts**.

## Boundaries and verification

Baseline: commit `6a8d771c72a335fe8fdecee2889906785eb6d050` plus the pre-existing README and Android working tree. Research changed documentation only. No app/competitor builds, model downloads, dependency installations, provider requests, runtime benchmarks or target-app/device tests were performed. Three independent source audits covered current baseline, cleanup/context, and delivery/platforms; the narrow formatting conclusion was checked against disconfirming tests and compare behavior.

Competitor HEAD code can include unfinished/debug-gated features. Handy's paste receipt mechanism is explicitly an experimental spike; meeting/AEC/diarization code is not evidence of released qualification. Context capture, provider failover and retained audio require explicit product choices, not automatic adoption of competitor defaults.

Source checkouts and the navigation graph remain under `/tmp/wisper-competitive-2026-10-28/`; the additional source trees and audit notes are under `/tmp/wisper-competitive-expansion-2026-10-28/`. Their location is temporary; the durable evidence and revision pins are in this directory. No task-created server, browser session or database remains running.
