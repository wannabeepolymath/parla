# Cleanup, app context, and workflow evidence dossier

Audit date: 2026-10-28. Static source inspection only; no product build, dependency installation, or runtime quality/speed measurement. Fresh shallow clones, no execution of competitor code. Local Parla HEAD `6a8d771c72a335fe8fdecee2889906785eb6d050`; current working tree includes pre-existing README/Android changes. Source paths below are relative to indicated repo. Negative statements are limited to inspected source/settings/UI surfaces, not proof of every possible integration.

## Pinned sources

- VoiceInk: `1027ea3c25e329cd42e7bbe18c746224ad664f7b`, [LICENSE](https://github.com/Beingpax/VoiceInk/blob/1027ea3c25e329cd42e7bbe18c746224ad664f7b/LICENSE), GPLv3.
- TypeWhisper: `f8443dee525a640cc9671e4f75196e57d208000b`, [LICENSE](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/LICENSE), GPLv3; separate commercial license terms in LICENSE-COMMERCIAL.md. Inspection of HEAD does not establish released availability.
- Amical: `d5604ef548816d8729b1170696d315a35c00391a`, [LICENSE](https://github.com/amicalhq/amical/blob/d5604ef548816d8729b1170696d315a35c00391a/LICENSE), MIT.
- Voquill: `a5dfbe0e3a35807271293a0ef02c91902abc0104`, [LICENCE](https://github.com/voquill/voquill/blob/a5dfbe0e3a35807271293a0ef02c91902abc0104/LICENCE), AGPLv3 outside enterprise and third-party exceptions. Enterprise code has proprietary terms; none of the recommendations below depend on enterprise code.

## Opportunities and counterarguments

### C1. User-editable app/site profiles with explicit precedence — HOLDS

Mechanism: TypeWhisper matches app + website before narrower website/app/global fallbacks, and reports match kind/competing count. [WorkflowService.swift:211](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/Services/WorkflowService.swift#L211). VoiceInk modes combine app/URL triggers, model, language, prompt, context and output: [ModeConfig.swift:42](https://github.com/Beingpax/VoiceInk/blob/1027ea3c25e329cd42e7bbe18c746224ad664f7b/VoiceInk/Features/Modes/State/ModeConfig.swift#L42).

Parla: `TextRules.appCategories`, `appCategoryPrefixes`, `category` at Sources/ParlaCore/TextRules.swift:18,50,66 are static; Settings.swift:25 has no user profile collection. Existing website email/chat/prose classification is real, so “no app awareness” DOES-NOT-HOLD. Improvement: a small profile with app bundle/domain, cleanup off/style/model/language; show which rule won. Benefit: opt out of rewriting in code and use email/notes styles without globally changing settings. Effort M–L. Counterargument: fixed categories are simpler and already solve common destinations; advanced profiles can overwhelm setup. Preserve exact host parsing rather than copying VoiceInk's URL substring matching (`ModeConfig.swift:410`).

### C2. Reusable transformations and explicit output styles — HOLDS

TypeWhisper implements workflow templates for translation, email reply, notes, checklist, JSON and summary; [Workflow.swift:5](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/Models/Workflow.swift#L5). Voquill supplies verbatim/polished/chat/formal modes, [tone.utils.ts:8](https://github.com/voquill/voquill/blob/a5dfbe0e3a35807271293a0ef02c91902abc0104/apps/desktop/src/utils/tone.utils.ts#L8).

Parla: PromptBuilder.system at Cleanup.swift:28 is fixed cleanup or freeform selection transform, not named reusable workflows. Improvement: save a few transform presets and trigger manually/hotkey; add per-dictation raw/verbatim toggle. Benefit: avoid repeating “translate this” or “make checklist.” Effort M. Counterargument: selection + spoken instruction already covers arbitrary transforms; templates add discovery/convenience rather than new model capability. Keep intentional transformations distinct from ordinary cleanup's preserve-language/preserve-content contract.

### C3. Literal replacement stage distinct from vocabulary hints — HOLDS, deliberate current boundary

Amical stores replacement entries/snippets separately, applies them after formatting, sorts longest triggers first and escapes literal replacement dollars: [load-dictation-context.ts:24](https://github.com/amicalhq/amical/blob/d5604ef548816d8729b1170696d315a35c00391a/apps/desktop/src/services/transcription/load-dictation-context.ts#L24), [text-replacement.ts:23](https://github.com/amicalhq/amical/blob/d5604ef548816d8729b1170696d315a35c00391a/apps/desktop/src/utils/text-replacement.ts#L23), wiring `prepare-transcript-text.ts:205`. VoiceInk handles alternate triggers and Unicode boundaries: [WordReplacementService.swift:117](https://github.com/Beingpax/VoiceInk/blob/1027ea3c25e329cd42e7bbe18c746224ad664f7b/VoiceInk/Features/Dictionary/Workflows/WordReplacementService.swift#L117).

Parla: Settings.dictionary is [String]; Pipeline.snippetExpansion:53 deterministically expands WHOLE transcripts; embedded snippets depend on PromptBuilder at Cleanup.swift:92. This is explicitly deliberate (Pipeline.swift:43–48) because inline trigger intent is ambiguous. Improvement: separate opt-in exact replacement rules (“open AI” -> “OpenAI”), preserve existing conservative snippet default, deterministic literal processing independent of LLM/network. Effort M. Counterargument: replacement collisions can silently corrupt legitimate prose, chaining can cascade, and languages need different boundaries. Require preview and explicit replacement mode rather than enabling all embedded snippets automatically.

### C4. Bound and prioritize vocabulary injected into prompts — HOLDS

Amical caps prompt hints at 200, manual entries before learned, excluding literal replacements: [vocabulary-hints.ts:3](https://github.com/amicalhq/amical/blob/d5604ef548816d8729b1170696d315a35c00391a/apps/desktop/src/utils/vocabulary-hints.ts#L3). It explicitly labels frequency/context ranking a future improvement, so don't credit it with semantic retrieval.

Parla: PromptBuilder.system joins all dictionary words at Cleanup.swift:43 and :88, snippets at :97; Settings.swift:26 stores a plain global array. Improvement: bounded token budget, manual priority, app-specific vocabulary before considering retrieval. Benefit: large dictionaries don't dominate every cleanup request. Effort S–M. Counterargument: no local measurement establishes a large-dictionary latency/quality failure; caps can exclude the word needed. Add corpus coverage tests and visible selection policy; don't claim measured savings.

### C5. Optional surrounding-text context — PARTIAL / product decision

Amical formatter accepts before/after cursor text, includes tagged context with continuity examples: [formatter-prompt.ts:145](https://github.com/amicalhq/amical/blob/d5604ef548816d8729b1170696d315a35c00391a/apps/desktop/src/pipeline/providers/formatting/formatter-prompt.ts#L145), :158, :182, :286.

Parla: CleanupContext at Cleanup.swift:3 includes category/singleLine/selection only; normal cleanup has no surrounding document text. Selection is only command-mode source. Improvement: opt-in bounded preceding text for capitalization, pronouns, specialized terms; keep URLs local. Effort M–L. Counterargument: Parla's fixed category hint is a real privacy advantage; document context can expose unrelated secrets and increase injection surface. No default document capture recommended. Need sensitive-field exclusions, consent and explicit cloud/local disclosure.

### C6. Per-mode context controls, optional on-device OCR vocabulary — PARTIAL / later

VoiceInk stores independent clipboard/selected/screen flags (`ModeConfig.swift:56`) and captures snapshots plus screen-name vocabulary preparation: [RecordingContextSnapshot.swift:40](https://github.com/Beingpax/VoiceInk/blob/1027ea3c25e329cd42e7bbe18c746224ad664f7b/VoiceInk/Features/Recording/Context/RecordingContextSnapshot.swift#L40). TypeWhisper targets front window and OCRs with Vision: [ScreenContextService.swift:13](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/Services/ScreenContextService.swift#L13).

Parla: no clipboard/screen text in CleanupContext. Improvement: if user asks for contextual assistance, add explicit per-profile controls with “local vocabulary only” mode first. Benefit: names in current work recognized without maintaining global dictionary. Effort L. Counterargument: screen permission and capture broaden product scope substantially; unclear net quality. VoiceInk capture service reads clipboard/selection unconditionally when invoked; this finding alone does not prove capture is gated end-to-end. Do not copy that privacy behavior.

### C7. Ordered cleanup-provider fallback with a single deadline — HOLDS

TypeWhisper candidates use global ordered list unless explicit provider overrides it: [PromptProcessingService.swift:510](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/Services/PromptProcessingService.swift#L510), execute attempts :618 and cancellation treatment :761.

Parla: makeCleanupClient at CleanupFactory.swift:62 returns exactly one provider; Pipeline.clean:118 falls back safely to raw. Improvement: optional primary/local backup chain, never cross to an unconsented provider; bounded total wait. Effort M. Benefit: polished output through transient provider failure. Counterargument: raw fallback is often better UX than serial extra latency; multicloud fallback changes data exposure and cost. This is resilience enhancement, not missing failure recovery.

### C8. Safe Undo Last Dictation / Restore Raw — HOLDS for dedicated action, reuse existing primitives

TypeWhisper snapshots same app/field, caret, complete value, freshness, and verifies mutation: [DictationUndoService.swift:5](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/Services/DictationUndoService.swift#L5), :22, :121.

Parla: HistoryEntry stores raw and cleaned at History.swift:28; Inserter has verified deletion primitives and command mode selection transforms, but inspected Settings/hotkey/menu/current Pipeline surfaces do not expose dedicated post-completion undo/raw restore. Improvement: user-triggered restore only when field/text/caret identity can be proven; otherwise copy raw from history. Effort M–L. Counterargument: native app Undo may already work and opaque web fields cannot be proven; never blindly backspace after clipboard delivery. Reuse safe primitives rather than promise universal support.

### C9. History retry/reprocess without redictating — HOLDS within inspected UI

Amical reloads dictation context and retranscribes prior history audio in [retranscribe-history-item.ts:49](https://github.com/amicalhq/amical/blob/d5604ef548816d8729b1170696d315a35c00391a/apps/desktop/src/services/transcription/retranscribe-history-item.ts#L49). Parla stores raw/cleaned history (History.swift:28) and recording store, Hub History is search/copy/clear. Improvement: first add “retry cleanup with current model” on raw text; only later add ASR retry with explicit retained audio linkage. Effort S–M for cleanup, L for audio lifecycle/ID linkage. Benefit: recover after network errors/model upgrade. Counterargument: reprocessing now may use changed vocabulary or provider; show original/result diff and save as a revision, never overwrite app text automatically.

### C10. File/batch transcription and subtitle exports — HOLDS as adjacent product expansion

TypeWhisper has pending/failed batch processing and per-file transcription: [FileTranscriptionViewModel.swift:398](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/ViewModels/FileTranscriptionViewModel.swift#L398), subtitle exports :643. Parla's parla-eval accepts WAV files for evaluation but no inspected Hub feature supports user batch/media transcription. Benefit: voice memos/interviews reuse ASR engine. Effort L: media decode, queue/cancellation, timestamp schema, long audio. Counterargument: this is a separate workflow from fast cross-app dictation; don't displace delivery/cleanup qualification to chase it.

### C11. Segmented cleanup for long dictations — PARTIAL / needs benchmark

TypeWhisper supports incremental stable segment processing and whole-text fallback, [WorkflowSegmentedPostProcessing.swift:455](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/Services/WorkflowSegmentedPostProcessing.swift#L455); limits segmentation to cleanup/translation, excluding restructuring templates [Workflow.swift:115](https://github.com/TypeWhisper/typewhisper-mac/blob/f8443dee525a640cc9671e4f75196e57d208000b/TypeWhisper/Models/Workflow.swift#L115).

Parla: shadow ASR streaming exists; Pipeline.clean:64 performs one cleanup call after full transcript. Improvement: consider early sentence cleanup with immutable segments and end-to-end deadline only for literal cleanup. Effort L. Counterargument: cross-segment self-corrections, snippets, lists and email structure need full context; more requests increase cost, and static source establishes no speedup. Benchmark real long-form corpus before adoption.

### C12. Linguistically careful filler preservation and regression fixtures — PARTIAL

Amical has concrete examples retaining meaningful “So”, “But”, “Let's” and questions and explicit no-answer rules: [formatter-prompt.ts:113](https://github.com/amicalhq/amical/blob/d5604ef548816d8729b1170696d315a35c00391a/apps/desktop/src/pipeline/providers/formatting/formatter-prompt.ts#L113), :221.

Parla: Cleanup.swift:68 says remove filler “like, you know, sort of”; eval already has filler cases and injection cases, so “no cleanup evals” DOES-NOT-HOLD. Improvement: add minimal-pair fixtures where “like”, “you know” and “sort of” carry literal meaning, questions stay questions, technical names/spelling unchanged. Effort S. Counterargument: longer prompts are not automatically better and Parla already says preserve meaning; use eval outcomes to justify prompt changes rather than copy competitor wording wholesale.

## Things checked that were already fine

- Injection framing and no-answer cleanup are implemented (`Cleanup.swift:49–64,161–169`), including no closing delimiter; August missing-delimiter claim is stale.
- Email body/subject distinction and browser host classification exist (`Cleanup.swift:104,136`, `TextRules.swift:66`).
- Command mode already transforms selected text (`Cleanup.swift:33,167`); workflows mostly improve repeatability/discovery.
- Whole-transcript snippets are already deterministic and bypass network (`Pipeline.swift:43–70`); inline LLM handling is deliberate ambiguity control.
- Raw fallback and empty/degenerate/truncated output guards exist (`Pipeline.swift:76–127`).
- Dictionary correction suggestions already exist and require explicit confirmation (`DictionaryLearner.swift:3–15,59–109`); “automatic learning missing” is false. Its single-word and wordlike scope is intentional false-negative bias.
- Context privacy is stronger than screen-aware competitors by default: category only, URLs local (`Cleanup.swift:6–8`, `TextRules.swift:68–69`).
- OpenAI-compatible local servers already work (`CleanupFactory.swift:67–81`); integrated local-LLM provider should be described as setup improvement, not first local cleanup support.
- History already preserves raw and clean variants (`History.swift:28–40`) and is local with a 50-entry cap; no claim of missing recovery storage.

No final recommendation here asserts measured ASR accuracy, latency, cost reduction, or universal application compatibility. Tests were located but not executed. All four cloned repositories remain in /tmp/wisper-competitive-2026-10-28 for root consolidation; no task-created server/database/browser.
