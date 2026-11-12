> Historical build evidence. Current parla1.2.0 floating-control status is documented in [Gboard control](GBOARD-CONTROL.md); no device testing was resumed.

# Sol-loop ledger

Current parla rename: APPROVED in one fresh round with Paawan GPT-6.1 Sol on high effort. No findings or declined items; usage was not exposed; nothing committed or pushed. Source inventory grew from 83 files/3547 lines to 86 files/3636 lines; diff 45 files, +235/−146 including renames and documentation. The reviewer confirmed every frozen source hash and the release APK. See `evidence/parla-rename/sol-loop-ledger.json` and `docs/RENAME-PARLA.md`. Approval covers rename correctness; it does not establish live dictation, real-phone Play Protect acceptance or original runtime fidelity.

Historical pre-rename status: APPROVED after 2 rounds. The approval below applies only to the preserved Flow build. Round1 returned CHANGES; round2 resolved S1–S4 with no new findings. Default budget: 3 rounds. Reviewer: Paawan (`codex-snabbit`), `gpt-6.1-sol`, high reasoning effort. No commit or push. Usage was not exposed.

The earlier provider workspace-routing failure prevented review from starting. A later capability probe succeeded and the requested provider completed round1. No alternate provider or model was substituted. Round1 task: `node:delegated-task:command%3Amcp%3A55ff09c6-bc49-4616-a7b3-2f4df918e724%3Adelegate-task%3Awispr-sol-round1-install-20261028`.

| ID | Severity | Outcome and evidence |
|---|---|---|
| S1 | should | Fixed: gpt-transcribe uses multipart languages[]; other models keep language, auto omits both. Official OpenAI speech-to-text guide confirmed. Mock transport tests cover each case. |
| S2 | should | Fixed: capture immutable form values at click; key and endpoint update execute in one synchronous IO block, eliminating the cancellation boundary between writes. A latch-controlled test cancels during key storage and verifies the matching endpoint still updates; failed key storage leaves it unchanged. UI cancellation propagates. This addresses UI cancellation, not an atomic transaction across process death. |
| S3 | should | Fixed: failed Retry preserves the current saved cleaned text and updates its warning. Successful cleanup replaces text. Two domain tests cover both outcomes. |
| S4 | should | Fixed: HistoryCard selects displayedText once and uses it for both rendering and Copy. Static callback path verified; current UI device test remains unperformed. |

No findings declined. The installation investigation found no established code-level cause; see INSTALLATION.md. Current checks: 35 tests pass, lint has no errors, debug assembly succeeds; evidence/reference/verification-sol-round1-fixes.log. The approved APK is retained under releases; the previous distributed APK is preserved under releases/archive.

Round1 source: 78 files, 3402 text lines, fingerprint `79e1ce4434f45c001866b48bec86c6c354af157a272cf07bfa5fa40a7efc0f27`. Round2 reviewed 83 files and 3530 text lines: 12 files changed, 144 insertions and 16 deletions against round1 (including documentation); text inventory grew by 128 lines. Round2 fingerprint: `966aec108670fc4f4af9c9ce3e17d37c26b2cba4905851e9a111480396955b5f`. Round2 task: `node:delegated-task:command%3Amcp%3A55ff09c6-bc49-4616-a7b3-2f4df918e724%3Adelegate-task%3Awispr-sol-round2-fixes-20261028`. Round2 inputs and diff statistics are recorded under evidence/reference/review. Final handoff changes only documentation and artifact metadata; approved behavior is unchanged. One fresh read-only reviewer per round; no scoped mutations during review. Later rounds check changed code and open IDs only.

## Review scope and baseline

Review the complete first-version Android app and helper source, including untracked files. This repository has no HEAD and no remote; there is no meaningful committed base SHA or base-to-HEAD diff. Do not invent one or omit untracked source. `evidence/reference/review/source-manifest.json` and `source.zip` freeze the current review inputs, with individual SHA256 hashes, line counts for text files, and a combined fingerprint. Changes since a round must be compared against that round's manifest and source archive. Original APK bytes in the installer are excluded from the source archive; their separate input hashes remain in `evidence/reference/installer-inputs.json`.

Intent: reconstruct the supplied original APK's recoverable visible behavior while retaining a working independent BYOK dictation app. Audit source fidelity against `docs/VISUAL-FIDELITY.md` and the read-only original dossier. Original private AI, authentication, cloud sync, billing and telemetry are excluded. Runtime product-screen parity is unverified because the genuine signed original stops at a Google Play error. Do not treat missing runtime evidence as approval or claim exact parity.

Covering checks: `docs/VERIFICATION.md`. Review severity and stable finding IDs follow the skill. Ledger columns when findings exist: ID, severity, disposition, evidence, usage if exposed. Diff growth and round-specific fingerprints must be recorded after any behavior fix.
