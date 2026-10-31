# Ranked opportunity backlog

57 deduplicated opportunities from static source inspection. B01–B48 are the initial pass; B49–B57 were added after web discovery and 13 additional source inspections. IDs remain stable. Ordering reflects user value, dependencies and qualification risk; no invented numerical scoring. “Gap” means an inspected surface lacks the named capability, not that current behavior is defective. Source labels map to numbered sections in the evidence dossiers: **C** = [cleanup](02-cleanup-context.md), **D** = [delivery](03-delivery-platforms.md), **E/W/P/Q** = [speech/workflows](04-speech-workflows.md), **baseline** = [current audit](01-current-baseline.md). Each dossier contains pinned competitor links and counterarguments. See [web expansion](05-web-expansion.md) for the added evidence and prioritization.

Sizes: S ≈ 1–2 engineering days, M ≈ 3–5 days, L ≈ 1–3 weeks, XL = separate multi-week initiative. These exclude runtime/device qualification and are not delivery promises. A “spike” is a decision-producing experiment, not authorization to ship a default.

## First work packages: quality and daily workflow

| ID | Improvement and reason | Size / dependency | Acceptance before completion | Evidence |
|---|---|---|---|---|
| B01 | Paragraph-sensitive cleanup scoring alongside WER and current zero-edit | S–M | Removing email blank lines changes formatting result; punctuation/case comparisons still work; valid variants supported | Q01; baseline refutation |
| B02 | Consented human speech corpus with paired references and held-out speakers | M + ongoing | Real microphones, accents, Hindi/English switching, names, numbers, noise and lengths; human reference for every scored ASR case; ASR and cleanup scored separately | Q02 |
| B03 | User app/domain profiles: cleanup off/style, language, optional model and vocabulary | M–L; B01 | Explicit precedence and winning-rule display; exact domain matching; generic paste still works for unknown apps; terminal/single-line constraints win | C1 |
| B04 | Vocabulary token budget with manual/app-specific priority | S–M | Bounded prompt at large dictionary sizes; deterministic selection; rare-name coverage reported; no silent deletion of saved words | C4 |
| B05 | Explicit literal replacement rules distinct from snippets and hints | M; B01 | Unicode boundaries, longest match, literal dollar handling, overlap/cascade tests and preview; current whole-utterance snippet default preserved | C3 |
| B06 | Desktop history: copy original and retry cleanup with a result diff | S–M | Raw text remains available; chosen provider/settings visible; retry does not paste into a later target; storage retry does not repeat a successful paid request | C9 + W02 |
| B07 | macOS provider/endpoint-scoped Keychain credentials | M | Migrate existing inline keys; environment overrides preserved; blank form does not erase key; denied access and endpoint changes handled | P01; baseline |
| B08 | Publish and execute app/field/delivery qualification matrix | M + ongoing | Named app versions and real outcomes recorded; target switches, selection changes, Unicode and secure fields covered; no “supported” badge from allowlist alone | [App matrix](APP-SUPPORT.md); baseline |
| B09 | Meaningful-filler, self-correction and protected-content cleanup fixtures | S; B01 | Literal “like/sort of/you know,” questions, negatives, quantities, currencies, names and identifiers survive; prompt changes need evidence | C12 |
| B10 | Credential-free vocabulary/snippet import/export | M | Versioned document, Unicode, duplicates, conflict preview and safe merge/replace; never export the whole credentials-bearing settings object | W01 |
| B11 | Manual diagnostic export with accurate stage/outcome semantics | M | App/model/route/stage/outcome metadata; distinguish attempted from confirmed delivery; no text/audio/keys by default; inspect locally | Q03 |
| B12 | Android verified multilingual Whisper model choices | M–L; B02, physical qualification | Hindi/English and switching tested; verified downloads and memory/cancel limits retained; no arbitrary unverified native model import | P03 + D11 |
| B13 | Android standard recognition activity | M | RECOGNIZE_SPEECH result, stop/cancel, requested language and caller lifecycle work; no universal Gboard claim | D7 |
| B14 | Android RecognitionService adapter | M–L; session ownership | Caller permission/attribution, model-not-ready errors, competing sessions, final-once and cancel contracts tested | P02 + D8 |
| B15 | Saved manual transforms and explicit output modes, including translation | M; B01 | Clear intentional transformation versus ordinary cleanup; repeatable preset/hotkey; raw toggle; selection identity stays guarded | C2 |

## Controlled experiments and supporting improvements

| ID | Improvement and reason | Size / dependency | Acceptance / decision criterion | Evidence |
|---|---|---|---|---|
| B16 | Small speech capability seam plus one optional Parakeet-family adapter | M seam + L adapter; B02 | Same audio paired across engines; language, quiet speech, cancellation, warm/cold latency, memory and long recordings assessed; retain Intel/older OS fallback | E01 |
| B17 | Speech/no-speech detection with padded boundaries | M–L spike; B02 | Report false rejection and hallucination rates; quiet onsets/single words/code-switching retained; no blind RMS increase | E03 |
| B18 | Persisted model-download resume | M | App restart, server ignores Range, changed artifact, truncated chunk and cancellation; full final size/SHA and atomic install retained | E06 |
| B19 | Apple Shortcuts start/stop/cancel/get-last | M | Cold launch, duplicate start, current target identity and late cancellation safe; return text if destination cannot be retained | W06 |
| B20 | Per-entry history deletion and explicit history/audio retention controls | S–M | Count retention and crash-audio lifetime separately explained; deleting an entry handles linked audio intentionally; history-off behavior clear | Baseline opportunity 6 |
| B21 | Optional ordered cleanup failover under one deadline | M spike | Explicit consent for each destination; total wait bounded; no new-provider disclosure by surprise; compare against immediate raw fallback | C7 |
| B22 | Eligible in-process Apple Intelligence cleanup | M–L | Hardware/OS/language/assets checked at runtime; refusal/empty/late results retain existing guards; no outbound provider request from adapter | E08 |
| B23 | Optional Apple SpeechAnalyzer engine | L; B16 | Older deployment targets retained; locale assets, reservation lifecycle, cancel, unsupported OS and offline-ready state qualified | E02 |
| B24 | Guarded Undo Last Dictation / Restore Raw | M–L spike | Require provable same field/text/caret/freshness; fallback to copy original where opaque; never blind backspace after a paste | C8 |
| B25 | Receipt-aware clipboard restore experiment | M–L spike; B08 | Slow apps, clipboard managers, multiple reads and remote clients; ownership-safe full snapshot retained; receipt not misreported as insertion proof | D1; upstream debug-gated |
| B26 | Optional bounded surrounding-text context | M–L product experiment | Explicit per-profile consent and provider disclosure; secure-field exclusion; injection fixtures; compare quality with category-only baseline | C5 |
| B27 | Optional local OCR vocabulary from the active window | L; B26 | Separate permission and on/off controls; local-only term extraction option; strict bounds/deletion; demonstrated name benefit before expanding | C6 |
| B28 | Explicit pronunciation enrollment / acoustic vocabulary bias | L–XL; B16, B02 | Specific correction-to-audio link; short retention; near-sounding negative controls, possessives, undo and model-upgrade handling | E04 |
| B29 | User-selected cursor-word alternatives first; confidence-aware dictionary repair as a later experiment | M dictionary-only picker / L acoustic path; word confidence output | Explicit selection before replacement; occurrence/session/cursor identity; calibrated scores; ties/short words protected; false substitutions counted; exact restoration before fuzzy matching | E05; [Outspoke M2](07-additional-android.md#m2--user-chosen-cursor-word-correction-candidates-b29-extensionreinforcement) |
| B30 | Incremental cleanup for long dictation | L spike; B01/B02 | Self-corrections across segments, lists/emails and snippets intact; stable ownership; compare end-to-end time and request cost before shipping | C11 |
| B31 | Download/optimize/load preparation states for new backends | S–M; B16 | Stale preparation cannot select older model; cancel/delete/switch safe; no excessive re-scans; avoid unnecessary current Whisper machinery | E07 |

## Platform qualification and expansion

| ID | Improvement and reason | Size / dependency | Acceptance / decision criterion | Evidence |
|---|---|---|---|---|
| B32 | Qualify existing Linux clipboard milestone on real hardware | M prerequisite | Complete linux/VERIFY.md: audio, clipboard lifetime/repeated paste, notifier failure, compositor key release, watchdog and missing backend | Baseline; linux/VERIFY.md |
| B33 | Linux native output backend capability selection | L; B32 | Explicit supported backend detection and user override; focus/layout tests; never retry after partial or unknown dispatch | D2 |
| B34 | GNOME/KDE portal/EI output | L; B33 | Real desktop/version consent and reconnect tests; unknown-delivery outcome surfaced without duplicate retry | D3 |
| B35 | Linux terminal and integrated-terminal routing | M; B33 | Correct terminal paste chord; field-specific override where IDE identity is insufficient; no submit/execute action | D4 |
| B36 | Linux held-modifier guard before synthesized input | M; B33 | Release timeout and missing permission explicit; no compositor shortcut triggered; guard unavailability not treated as keys released | D5 |
| B37 | Linux GlobalShortcuts portal onboarding | M–L; B32 and platform decision | Consent/session recovery, release semantics, desktop versions; retain compositor binding route | D6 |
| B38 | Android voice IME subtype compatibility spike | S–M; physical qualification | HeliBoard/FlorisBoard mic handoff and return-to-keyboard tested; current keyboard discoverability preserved | D9 |
| B39 | Opt-in pause/duck of playback with owned restoration | M per platform | Calls/live streams excluded; same player/session ownership checked; manual user changes win; cancel/quit restoration | D12 |

## Adjacent workflows: keep separately scoped

| ID | Improvement and reason | Size / dependency | Acceptance / decision criterion | Evidence |
|---|---|---|---|---|
| B40 | Desktop audio/video file import and durable queue | L | Start with one file; bounded decode/chunks; cancel/restart/missing file/disk full/mixed failures; no automatic front-app insertion | W03 + C10 |
| B41 | Android share/open audio file transcription | L | URI permission lifetime, unsupported formats, decode cancellation, long-file memory/thermal checks; explicit result screen | D10 |
| B42 | Plain text / Markdown transcript export | S | Unicode, empty entries, filename handling; credentials excluded; export is user-directed | W04 |
| B43 | Meeting recording and transcription workspace | XL; B40, explicit demand | Separate mic/system sources, durable chunks, crash recovery, permissions, drift, echo, partial gaps and storage policy | W05 |
| B44 | iOS host-app transcription plus lightweight voice keyboard | XL feasibility initiative | Physical-device host suspension/kill, field change, keyboard replacement, background interruption and no stale/duplicate insertion | P04 |
| B45 | Android permitted-playback captions | L–XL separate bet | MediaProjection consent, app-policy exclusions, thermal/battery/cancel behavior; no “capture every app” claim | D13 |
| B46 | Desktop failed-audio recovery list with replay/retranscribe/delete | M; existing RecordingStore | Only viable inactive files offered; expiration/failed write clear; secure audio purged; no default successful-recording retention | W02 + baseline |
| B47 | Structured segments, timed subtitle and speaker exports | L; B40 | Preserve actual timestamps and gaps; SRT/VTT escaping, RTL, overlap and missing diarization correct; no timestamps invented from cleaned text | W04 |
| B48 | Separate cleanup-quality regression policy from scorer-drift CI | S–M; B01/B09 | Keep existing offline verify; add reviewed structure/content fixtures and clear failure criteria; no mandatory paid/model download in ordinary CI | Q01; baseline; .github/workflows/ci.yml |

## Web expansion additions: B49–B57

**First corrective action: B49.** It has a concrete source-level witness, a blind audit and a separate neutral refutation; runtime reproduction remains outstanding. B50 is an explicit extension of a deliberate contract. B54 and B55 are small daily-use improvements to consider alongside existing cleanup/profile work. B51/B53/B56/B57 are demand-led or measured experiments, not default changes.

| ID | Improvement and reason | Size / dependency | Acceptance / decision criterion | Evidence |
|---|---|---|---|---|
| B49 | Foreground-generation ownership for completion HUD/hide effects | S | Start A, stop A, start B, then deliver A's nil transcript/empty command/unavailable leg/invalid transform. B keeps listening feedback, state and menu. Current-session errors still show; intended old raw delivery/history semantics preserved | [Blind audit and neutral refutation](10-cancellation-and-feedback.md) |
| B50 | Explicit cancel/discard pending recognition, cleanup and delivery | M; define stage contract | Distinguish stop, dismiss and discard; invalidate ownership before awaiting native/network abort; no late paste; no older error replaces a new HUD; history/audio retention explicit; preserve secure-input refusal | [Cancellation contract](10-cancellation-and-feedback.md) |
| B51 | Guided named-field voice templates with one reviewed completion | L; B15 and user demand | Versioned fields/template; literal placeholder contents never cascade; ordered takes; explicit re-record/skip decisions; cancel during all stages; one history entry; retain original destination identity or offer copy | [WhisPaste R01](09-templates-triggers-recovery.md); [independent R3](08-sotto-projects.md#r3--neutral-snippet-data-model-and-session-flow-comparison) |
| B52 | Optional middle/side mouse-button recording trigger | M + physical qualification | Typed trigger binding into existing reducer; balanced down/up suppression; unrelated buttons untouched; no Back/Forward; missed release/tap reset/rebind/unplug/secure field; no duplicate completion | [OpenSuperWhisper R02](09-templates-triggers-recovery.md); [independent R2](07-additional-android.md#r2--single-neutral-input-trigger-comparison) |
| B53 | Reversible safe-start after repeated interrupted native model preparation | M spike; strongest with B16 | Scope markers to model/backend/version; cover load and first inference; distinguish caught error, cancel, forced kill and failed persistence; UI remains reachable; no claim a marker identifies GPU causality; CPU option only where supported | [WhisPaste R03](09-templates-triggers-recovery.md); [independent R1](06-additional-desktop.md#r1--native-preparation-and-failure-ownership-separate-neutral-audit) |
| B54 | Active-layout shortcut labels separate from canonical saved chords | S–M | Physical matching and serialized names unchanged; QWERTY/AZERTY/QWERTZ and layout switch; explicit ISO/JIS fallback; named modifiers/functions retained | [OpenSuperWhisper R04](09-templates-triggers-recovery.md) |
| B55 | ASR-independent microphone self-test; optional Android route comparison | M diagnostic / L calibrated device qualification | Works without an ASR model; levels/no-signal status plus explicit listening; bounded unsaved audio; stop on close; actual routed device displayed; Android may ignore preference; no automatic quality winner from spectral proxy | [Sotto S1](08-sotto-projects.md); [Outspoke M1](07-additional-android.md) |
| B56 | Separate lightweight preview model from final ASR model | M–L spike; B16/B02 | HUD-only speculative text; final result independently qualified; no assumed prefix equivalence between models; compare time-to-preview, stop latency, quality and peak memory; cancel/failure/switch/long-session behavior | [Tomoima Sotto S2](08-sotto-projects.md) |
| B57 | Optional short in-memory undo window for accidental capture cancellation | M product experiment | Off unless explicitly chosen; no disk retention; expiry/new capture/quit clear audio; secure capture excluded; explicit Undo only; destination changes return text/copy; no silent late paste; ordinary cancel still discards by default | [Psancheti Sotto S3](08-sotto-projects.md) |

### Existing entries strengthened by the expansion

- **B02/B12/B16:** actual IndicConformer provider/caller and language-span policy in taraksh01/wisper, plus alternate engine dispatch in Dictus/OpenDictate. This is stronger feasibility evidence, not a measured Indic/code-switching win. Reject forced Hindi reinterpretation of other languages.
- **B04/B05/B10:** bounded hint selection, literal replacement semantics and vocabulary-pack edit ownership. Require strict token bounds and preserve manual edits on pack removal; source caps/substring matching are not sufficient policies by themselves.
- **B17/B29:** Outspoke's VAD/normal-stop drain and explicit word candidates. Keep quiet-speech controls, final-once ownership and occurrence-linked suggestions. Do not adopt automatic fuzzy mutation or append-on-failed-alignment delivery.
- **B40/B41/B47:** typed import stages, source timestamps, MediaCodec output-EOS drain and file/live finalization differences. Require bounded decode/finally release; a source decoder should not be copied wholesale.
- **B08/B11/B19/B22:** VoiceOver/overlay qualification, honest signal diagnosis, guarded local automation and in-process local cleanup implementation choices. No new generic “local cleanup,” “microphone test,” or server requirement.

## Do not turn these into missing-feature tickets

- “Add app support” without naming the missing layer. Unknown macOS apps already reach generic paste. Profiles, adapter choice and real compatibility tests are separate work.
- “Add Android,” “add multilingual desktop,” “add local LLM cleanup,” “add warm mic,” “add WER,” “preserve clipboard,” “add prompt injection framing,” “add recovery storage,” and “add dictionary learning.” These already have implementations with deliberate boundaries.
- “Upgrade everyone's default model” or quote a competitor's speed multiplier. Current users intentionally retain their model; this research made no comparable measurements.
- “Always capture clipboard/screen context,” “always retry failed paste,” or “enable fuzzy replacements globally.” The proposed experiments depend on consent, bounded ownership and disconfirming tests.
- A localhost API, accounts, sync, organization policy and hosted billing are not prerequisites for the above. Vocabulary export and native automation are smaller starting points. Enterprise competitor code is outside the recommendations' implementation scope.
