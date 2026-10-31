# Offline corpus admission and human protocol

This is a reviewable plan and exact offline interchange contract, not a consent
form, recruitment request, grant of permission, collection result or completed
human qualification. No real participant/audio/reference sample is supplied.

```
parla-eval corpus-check MANIFEST [--results SAVED_RUN [--against OTHER_RUN]]
```

All three paths are **read inputs**. This command has no `--out`, writes nothing,
discovers nothing and invokes no model/cleanup/settings/credentials. Unknown,
duplicate, mixed mode flags and extra/missing arguments refuse with exit 2.
Exit 0 admits declared bindings, including bad hypotheses or fully recorded
operational failures; it is never a quality pass. Legacy flat arrays are accepted
only by legacy modes. Manifest-only success measures no model quality.

No producer is added: an independently authorized external/manual generator must
emit every exact field/terminal row below. Its engine/configuration identities,
routes, timings, consent and human review are attestations, not independently
verified facts. Never relabel a legacy file as a qualified run. Do not use test
bytes/declarations as evidence of real speech, consent, references or quality.

## Exact v1 schema (all listed keys required; no others; nullable only where stated)

JSON UTF8, no BOM, duplicate decoded keys refused, maximum container nesting 32. Integer fields must be lexical nonnegative decimal integers (no exponent/fraction/bool); times Unix UTC seconds <=253402300799. IDs: 1..64 ASCII alphanumeric, hyphen or underscore. SHA256: 64 lowercase hex. Arrays of identifiers/enums have no duplicates. Texts bounded before scorer tokenization. All extension/enum spellings below are case-sensitive.

Manifest: `{version:1, corpusID:ID, revision:ID, purpose:human-qualification|nonhuman-regression, protocolRevision:ID, snapshotAt:time, cohorts:[Cohort], speakers:[Speaker], consents:[Consent], cases:[Case]}`.
Cohort: `{id:ID, dimension:language|accent|microphone|noise|length|other}`. Labels are pseudonymous defined vocabulary, no free description. Unknown can be an explicitly defined ID.
Speaker: `{id:ID, identityGroup:ID, identityKnown:true, aliasesReconciled:true, cohorts:[ID]}`. identityGroup reconciles aliases; distinct-speaker reports count groups, not aliases. All declared speaker identities must be used. All aliases in one group have identical cohorts and remain in one split.
Consent: `{id:ID, revision:ID, speakerIDs:[ID], attester:ID, effectiveAt:time, reviewedAt:time, retentionUntil:time, status:active|pending|unknown|withdrawn|revoked, withdrawalEffectiveAt:time|null, uses:[binding-check|reference-review|asr|cleanup], destinations:[local|provider|external-command], accessPolicyRevision:ID, withdrawalPolicyRevision:ID}`. Only active/null-withdrawal declarations admit human cases. effectiveAt <= reviewedAt <= snapshotAt <= now < retentionUntil; each selected use/destination must be covered for every case speaker. Binding check/reference review/local always selected; run schedules select asr and/or cleanup and cleanup transport destination. No automatic permission inference. Unused/unknown consent bindings refuse.
Case: `{id:ID, provenance:human-speech|human-no-speech|tts|synthetic-signal|authored|unknown, takeID:ID, familyID:ID, parentIDs:[ID], lineageComplete:true, speakersComplete:true, speakerIDs:[ID], consentIDs:[ID], split:development|holdout, repetitionGroup:ID, cohorts:[ID], audio:Audio, verbatim:Reference, cleaned:Reference}`.
Audio: `{path:relative.wav, sha256:SHA, bytes:integer}` (positive). Reference: `{path:relative.txt, sha256:SHA, revision:ID, review:reviewed|unresolved, reviewer:ID, reviewedAt:time, audioSHA256:SHA, takeID:ID, draftOrigin:independent-human|hypothesis-assisted|script|authored}`. Hash whole file; body uses unchanged known category/app/bundle header semantics. Human verbatim requires independent-human or separately reviewed hypothesis-assisted; cleaned may be authored editorial target, but not script. Human speech references must have nonempty scorer tokens, human-no-speech both bodies must have zero scorer tokens AND empty normalized bodies. Nonhuman regression cannot contain human provenance or claim human quality; unknown provenance refused. All references must be reviewed, audio/take bound, and reviewed no later than snapshot. Human cases require nonempty complete speakers and consent coverage. No speech inference/decoding.

One selected variant per take; unique audio digest and payload path identity; no path alias across roles/cases. Speaker identityGroup, family, parent ancestry identifiers and take relationships cannot cross splits. Shared parent IDs must have same family; any parent that names a selected case must have same family, with acyclic selected ancestry. Different speakers may read identical text; repetitionGroup overlaps reported independently, never a content-heldout claim. Families can contain independent takes in one split. Complete ancestry/alias declarations remain curator attestations.

Saved run: `{version:1, runID:ID, manifestSHA256:SHA, manifestRevision:ID, route:asr-only|reference-cleanup|asr-pipeline, engines:[Engine], rows:[Row]}`. Engine: `{leg:asr|cleanup, id:ID, revision:ID, configRevision:ID, transport:local|provider|external-command}`. Exact route legs: asr-only=[asr], reference-cleanup=[cleanup], asr-pipeline=[asr,cleanup]; ASR transport local. All declared cases scheduled on every route leg; one terminal row per case/leg.
Row: `{caseID:ID, leg:asr|cleanup, audioSHA256:SHA, referenceSHA256:SHA, referenceRevision:ID, status:success|failed|skipped, reason:null|decode|engine|transport|timeout|cancelled|upstream-failed|policy|not-attempted|silence-gate, hypothesis:string|null, seconds:number|null, inputOrigin:audio|verbatim-reference|asr-hypothesis|unavailable, inputSHA256:SHA|null}`. Success has reason=null, hypothesis string (including empty), finite seconds>=0. Failed has reason in decode/engine/transport/timeout/cancelled, hypothesis=null, finite seconds>=0. Skipped has reason in upstream-failed/policy/not-attempted/silence-gate, hypothesis=null, seconds=null. No scores or run references accepted. ASR inputs bind audio hash. Reference-cleanup inputs bind SHA256 of exact parsed verbatim body UTF8. Pipeline cleanup binds SHA256 of exact successful ASR hypothesis UTF8; upstream non-success requires cleanup skipped/upstream-failed, unavailable/null input; upstream success prohibits upstream-failed skip. Other skip reasons retain known input provenance. Decode failure only ASR; transport failure only cleanup. Silence gate only on known empty cleanup input, never an ASR success substitute.

Pairs: distinct runID; identical route, manifest digest/revision and exact per-row bindings/schedules/transport per leg. Engine/config IDs may differ intentionally (comparison labels), transport cannot. Pipeline cleanup with differing successful ASR input digests is explicitly pipeline-dependent; report input-different pairs, never isolated cleanup. Reference-cleanup pairs use same trusted verbatim inputs. Successful-pair deltas only; scheduled/success/both-nonsuccess/unilateral failure and skip denominators visible. No inferred run authenticity.

## Bounds and IO

Policy bounds exactly: manifest1MiB,256cases,128speakers,32cohorts, IDs64/path256UTF8, refs/hyp32KiB/2048 actual Eval tokens, references8MiB,audio64MiB/512MiB,run32MiB/512rows,depth32. Additional bounded consent/parents/cohort array counts follow <=256/128/32 relevant limits. Combined both-run selected successful scoring cells cap16777216 using checked addition/multiplication BEFORE any WER, then one cached Eval.wer score per successful row. Existing scorer functions and >0.20 descriptive threshold unchanged. Metadata-only does not call WER.

Directory descriptor chain from `/` (relative CLI paths use current working directory), O_NOFOLLOW|O_DIRECTORY|O_CLOEXEC; selected files O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC. No root spelling symlinks, no silent realpath. ASCII safe components only (letters/digits/_/hyphen/dot, no leading/trailing dot); rejects hidden/Unicode/case aliases, traversal/URL/drive/UNC/expansion/control. Selected manifest/run .json, audio .wav, references .txt only. fstat regular/single-link/size bounds, streamed SHA256 in64KiB chunks, exact length, pre/post dev/ino/mode/uid/nlink/size/mtime/ctime; retain directory authority and revalidate full directory/file name bindings at end, including fresh file hashes to refuse observed replacement/edit. No recursion. IO injectable internal read-lifecycle hook only for tests; no CLI bypass. Independent files have finite observation windows, not transactional/atomic snapshots; adversarial restore-after-check and later withdrawal cannot be eliminated. Generic finite errors only, no text/paths echoed. Command never writes/discovers/settings/env/models.


## Reporting and limitations

The checker reuses `Eval.wer`, `normalize`, `normalizeStructure` and
`newlineLayout`; it does not trust saved scores or references. Reports include
all declared/eligible/scheduled/attempted/scored/failed/skipped counts by leg,
split and overlapping cohort, distinct curator identity groups and takes.
Attempted means recorded success or operational failure; skipped is separate.
Quality failures above the existing 20% threshold use scored speech rows only.
No-speech controls/hallucinations have separate counts; zero-reference-word WER
is unavailable. Punctuation-only nonempty no-speech output is a hallucination.
Pairs retain unilateral/bilateral non-success counts and separate typed failure
and skip counts; mean WER deltas use both-success speech rows only. Complete
recorded coverage is not complete measured performance. No statistical
significance, sample-size qualification or default-model decision follows.

Reference-cleanup compares the trusted verbatim body as input; pipeline cleanup
compares ASR-derived inputs and remains pipeline-dependent even if some inputs
match. Differing ASR inputs are counted. Config/engine revisions may intentionally
differ between pairs; transport/route and exact manifest bindings must match.
Timings are declared, never measured by this checker or presented as live latency.

Identity/hash checks cannot discover undeclared re-encodes, unrecognized speaker
aliases, undisclosed prior exposure or unrecorded withdrawal. Whole-file hashes
bind exact reference bytes, while the shared legacy parser extracts reference
bodies. Root/parent/leaf no-follow checks and descriptor identity/rehashing refuse
observed replacement. Sequential files are not an atomic snapshot, permissions
may change after a check, and a malicious writer can restore state between
observations. Finite bounds are not wall-time or measured-RSS guarantees. No audio
format/content correctness is inferred from a `.wav` suffix or declared bytes.
Diagnostics contain finite categories/validated identifiers, never reference or
hypothesis text/private paths. Use a separate explicitly authorized local review
process for transcript inspection.

## Proposed collection, reference and withdrawal procedure

1. Approve scope before contact/capture. Name custodian/reviewers, storage/access,
   intended experiments/destinations, retention, withdrawal/deletion and limits
   for derived reports/backups. Publication, distribution, training and cloud
   cleanup each require separate express permission. Existing ordinary dictation
   retention stays unchanged; this checker enables no capture or storage flag.
2. Establish genuine permission privately with comprehensible information and a
   withdrawal route. Confirm every audible speaker, including bystanders. Keep
   identities/contact and actual permission documents under restricted custody;
   only pseudonyms and attestation revisions enter the manifest. Possession or
   successful-recording retention is not consent.
3. Predeclare coverage and acceptance before looking at model wins: microphones,
   accents/languages and Hindi/English switching, names, numerals, quiet/noise,
   no-speech, short/long takes and cleanup preferences. Reconcile aliases, assign
   whole speaker/source families to development or reserved holdout, and record
   uncertainty. Exposure of holdout during tuning requires a fresh holdout or a
   narrower claim. Project-heldout does not prove absence from pretraining.
4. Capture/export only in a separately authorized session and chosen owned
   location. Record real take/source ancestry and permitted conditions, inspect
   for unintended speakers/sensitive material within that authority. Never
   automatically import recovery folders, private audio or unrelated files.
   Preserve exact original identity bindings for each approved derived format.
5. Have real reviewers listen to exact audio, preserving verbatim speech and
   disfluencies separately from reviewed cleaned editorial preferences. Record
   independent versus hypothesis-assisted draft origin, reviewer, adjudication,
   revision, uncertainty, take/audio digest. A hypothesis becomes a reference
   only after genuine separate review. Refuse unresolved selections rather than
   silently filtering after results. Editorial targets are not speech provenance.
6. Refresh current permission/retention/withdrawal records; freeze bytes, split,
   references and run configuration. Check offline bindings first. Later,
   separately authorized inference records actual engines/routes and every
   terminal outcome on the same paired audio. Report cohort/speaker/take counts,
   omissions, controls, operational failures and uncertainty. Keep isolated
   cleanup and pipelines separate; no human claim from synthetic fixtures.
7. On withdrawal/expiry, stop new use, mark ineligible, invalidate affected
   manifests/runs, and trace all known audio/derivatives/references/hypotheses and
   controlled copies. Delete/quarantine under agreed scope and record completion
   and failures without speech content. Review reports/backups/access obligations
   and disclose limits; do not promise retroactive erasure everywhere. Failed
   disposal blocks a fully-deleted claim. The checker cannot erase external
   copies or discover an unrecorded withdrawal.

B02 remains PARTIAL and uncompleted. Real consented collection, reviewed human
references, reserved speakers/cohorts, actual paired engines and separately
approved human/native qualification remain open.

## Authoritative bounded source policy (verbatim ROOTPOLICY8A.1)

### Wave8A investigation closure; B02.1 offline corpus admission/reporting contract

The read-only wave8a-investigation.md and appendix recommend a complete offline extension within existing parla-eval rather than a new collection/retention system or unused manifest store. All492records/index/status/HEAD/branch/tracker and33explicitly read files unchanged; no tests/builds/models/collection/native work. Root inspected actual argument parsing, case/reference parsing, Summary/report/scorer/quality-policy entrypoints and current storage/recognition boundaries. Existing synthetic regression, explicit hypothesis disposal, scorer-drift/quality policy and permissive legacy comparison are deliberate and remain useful. No current defect is alleged.

ROOTPOLICY8A.1 adopts one complete model-free source slice: parla-eval corpus-check MANIFEST [--results SAVED_RUN [--against OTHER_RUN]]. All arguments are explicit read inputs, never output paths; reject unsupported/duplicate/mixed mode flags, missing/extra positionals and against-without-results. No automatic discovery/fallback or silent legacy-array certification. Branch exits before model/request construction, SettingsStore/credentials/environment/external cleanup/network and writes. Legacy verify/quality-check/compare/self-check/live modes, scorer arithmetic/thresholds, fixtures and default retention remain unchanged. No new app UI/capture/retention, participant recruitment/contact/recording, audio decoding, live inference, optional engine selection or acquisition.

Use a strict versioned manifest and saved-run contract per investigation appendix, with exact documented fields. Reject missing/unknown/duplicate object keys (including escaped duplicate spellings), invalid types/versions/IDs, unsupported enum values and contradictory declarations. Human-purpose admission requires explicit human-origin provenance, current attested consent/use/processing scope/retention/withdrawal status, pseudonymous speaker identities reconciled by curator, reviewed exact-audio-bound verbatim and cleaned references/revisions, complete speaker/take/derivation/split declarations and defined cohort tags. Actual identities/contact/consent documents stay outside manifest. Refuse unresolved references, nonhuman/TTS/authored/unknown human claims, speaker/take/family leakage, duplicate IDs/audio/path aliases and duplicate scored take variants. Distinct speakers reading the same text are allowed; hashes do not discover speaker identity or all re-encodes. Attestations are declarations only, never verification of consent truth/legal adequacy/human audio/reference correctness/pretraining exposure or future withdrawals. Never infer consent from retention flag or hyp/raw filename. Include this limitation even on success. Mock declarations/bytes used in tests are explicitly test-authored only, never published or claimed as actual human evidence.

Freeze engineering bounds from appendix: manifest1MiB,256cases,128speakers,32cohort labels,IDs/labels64UTF8,path256UTF8,each reference/hypothesis32KiB and2048 actual scorer tokens,selected reference text8MiB,audio64MiB each/512MiB aggregate,savedrun32MiB/512terminalrows,JSON nesting<=32. Before any WER work use checked totals and cap combined selected scoring cell products (referenceTokens+1)*(hypothesisTokens+1), across both supplied runs, at16777216; cache per-row scores rather than repeat quadratic work. No truncation or silent case filtering. These are resource bounds, not sample-size/quality gates, elapsed guarantees or measured RSS. Byte-hash audio with bounded streaming and no decoding.

Selected manifest parent is sole corpus root, no arbitrary data root. Refuse absolute/traversal/URL/drive/UNC/control/hidden/wildcard/expansion/ambiguous aliases and unsupported roles; conservatively reject symlink parent/leaf, special files and hardlinks. Traverse and open directory-relative with no-follow/nonblocking descriptors, validate regular-file identity/size/change before/after bounded reads, keep selected directory authority and revalidate relevant path binding to refuse replacement rather than read mixed snapshots. A symlink-spelled root is refused with finite canonical-reselection guidance, never silently followed. No recursive traversal or refused-symlink target inspection. Explicitly selected run files receive equivalent bounded regular/no-follow checks; never copy/write files, sidecars/locks/settings/corpus/logs. Errors contain bounded IDs/reason categories, no raw text/private paths. No printed transcript detail by default. Exact race/ownership guarantees and limits must be documented rather than overstated.

Saved-run envelope binds manifest-byte digest/revision, declared run/engine/config revision and input route, all scheduled case/leg terminal rows, exact audio/reference hashes/revisions and cleanup input provenance/digest. Strict full coverage and one status per scheduled case/leg; successful empty ASR differs from failure/skip, unknown/missing/duplicate/extra rows refuse, finite typed failure/skip reasons remain visible, negative/nonfinite duration refuses. References come from admitted manifest files, never untrusted result references; contradictions refuse and scores are recomputed, not trusted. Paired runs require identical manifest/splits/audio/reference identities and compatible declared routes; isolated reference-cleanup versus ASR-derived pipeline cleanup cannot be conflated, and differing ASR-derived inputs never presented as isolated cleanup. Engine identity is recorded/attested, not independently proven by an offline file. No new live run producer in this slice; document how manually/external generated envelopes must satisfy the exact schema and the unverified-generator limitation.

Reuse existing Eval WER/normalization/paragraph scorers and compatible summary arithmetic. Report declared/eligible/scheduled/attempted/scored/operational-failed/skipped counts by leg/split/cohort, distinct speakers/takes, overlapping-cohort caveat, quality-failure counts using current>20% only descriptively, exact successful-pair and unilateral/bilateral-failure counts. Keep no-speech controls/hallucinations separate, zero-reference-word WER explicitly unavailable, no survivor-only complete-performance claim or new numerical quality gate/statistical significance/default-model decision. Exit0 means declarations/bindings admitted, not a quality pass; bad hypotheses and complete recorded operational failures still report truthful counters. Invalid/unreadable/rejected selected input exits2, never fallback. Metadata-only success explicitly says no model quality measured; result success says recorded hypotheses rescored, consent/engine truth and human qualification unverified. Existing modes keep their prior exit contracts.

Allowed source plan only: new Sources/ParlaCore/EvalCorpus.swift, EvalCorpusIO.swift and (if needed for bounded duplicate-key checks) EvalCorpusJSON.swift; Sources/parla-eval/main.swift; new Tests/ParlaCoreTests/EvalCorpusTests.swift and EvalCorpusCLITests.swift; Tests/ParlaCoreTests/RecognitionFactoryTests.swift; eval/README.md; new eval/human-corpus-protocol.md. Narrow identical-behavior extraction of existing case-header parsing into new core helper allowed; no unrelated refactor or scorer/retention/recognition/Package/script/CI/fixture changes. Pre-edit plain baseline and492record opening plus finite path plan protect prior work/index. Record chosen exact schema before edits; stop/report unsupported implementation prerequisites rather than simplify away core admission/reporting/lifecycle contracts.

Authorize ROOT Swift TEST compilation, focused production-parser/admission/scorer/CLI checks and one final broad suite, excluding only TranscriberTests.testTranscribeSilenceProducesNoCrash and TranscriberTests.testMultilingualModelFollowsTheSpeakerLikeWhisperAutoDetect. Exact managed test-produced parla-eval executable may be invoked for isolated offline corpus-check/verify/quality-check/self-check probes; this narrowly permits its execution/existence check, never directory discovery/metadata enumeration of .build or swift run/build/package commands. Use no actual model/provider/audio/native/human data. Exercise real CLI dispatch and secure descriptor/streamed hashing/file replacement bottoms; unmodified ordinary positive controls and all finite source/ref/split/result/limits/privacy/input-route failures. No source-only order test as sole runtime-isolation proof. Document untested crossproducts and human/native gates. Preserve existing scorer baseline/rules/results/context bytes.

One Pritam writer, no children/review/tracker/count/staging/commit/push; root freezes source during task. Exclusive empty own fixture manifest, worker exits/absence, fixed catalog exact own-suffix restoration and owned-exited-unused cleanup recorded. All historical preference/mouse roots/cache/evidence preserved. B02 remains PARTIAL/uncompleted/count22 until genuine consented collection/references, declared heldout speakers/cohorts and actual separately authorized human/native paired evaluation meet research acceptance. No source test or protocol creates that evidence.
