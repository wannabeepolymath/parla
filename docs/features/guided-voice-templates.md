# Guided voice templates

Voice Templates is an explicit Hub/menu workflow for short, ordered forms. It is available before onboarding completes, but recording requires already granted microphone permission and a prepared saved recognition backend. Opening, selecting, editing and Begin never request permission, capture audio or warm a model. Use **Allow Microphone**, then begin a fresh form and press **Start recording**. No definitions or default selection are installed.

For example, create your own **Bug report** definition with fields `title`, `steps`, `expected`, `actual`, labelled Title, Steps, Expected, Actual, in that order. Use this body:

```text
Title: {{title}}
Steps: {{steps}}
Expected: {{expected}}
Actual: {{actual}}
```

Save definition, select it, and Begin form. Each Start records one field; Stop performs one complete raw recognition pass. Review/edit its candidate and explicitly Accept. Accept advances the prompt without starting another recorder. Back returns to earlier fields. An accepted value survives a failed or discarded retake until a replacement is explicitly accepted. Optional fields can be explicitly skipped; required fields cannot. Empty/whitespace Accept is refused, including optional values: use Skip instead. Spoken “skip”, “cancel” or instructions remain text.

After every field is accepted or skipped, **Review completed form** shows the full literal document. **Approve completion** seals its ID, date and exact body, without copying or saving. **Copy** explicitly requests those bytes through the Hub clipboard port; clipboard acceptance is not verified. Repeated explicit Copy is allowed. **Save completed result / Retry Save** conditionally saves one composed History row, raw body only, cleaned text nil. History off creates no pending row. Load/disk failure permits storage-only retry with the same identity/date/body; no recognition, cleanup or Copy repeats. A conflicting History ID refuses Save. After successful Save, deleting/clearing the row does not rearm this card. Done/Cancel drops the transient form; it cannot retract an already requested Copy or committed Save.

## Literal grammar

`{{key}}` is the only field token. Keys match `[a-z][a-z0-9_]{0,31}` exactly, with no whitespace or case folding. Every declared field must be referenced. Repeated/adjacent tokens are allowed, and body order is independent of recording order. Duplicate field IDs/keys, unknown/empty/malformed/nested tokens, unmatched double delimiters and triple delimiters refuse the definition.

Fixed escapes are scanned first: `{{{{` emits `{{`, and `}}}}` emits `}}`. Thus `{{{{key}}}}` prints literal `{{key}}` and does not reference a field. Single isolated braces stay literal, so ordinary JSON/code works. There is no backslash escape, expression, conditional or loop.

The original body is compiled once per validation/session. Values are appended once and never reparsed. Braces, `$1`, backslashes, HTML, shell/code text, email addresses and prompt-like instructions remain data. Unicode scalar sequences, RTL text, combining marks, emoji, spacing, CR/LF and newlines are preserved. The recognizer may already filter markers or normalize whitespace in its native payload. Once a candidate reaches the form, its reviewed values are not normalized or trimmed; whitespace is only inspected to refuse empty acceptance/completion.

## Limits and storage

| Item | Limit |
|---|---:|
| Definitions | 32; complete encoded block 262,144 UTF-8 bytes |
| Fields | 1–12; unique stable IDs and keys |
| Key | 1–32 ASCII bytes |
| Name / field label | 120 / 160 UTF-8 bytes, non-whitespace |
| Body | 8,192 UTF-8 bytes; 64 token occurrences |
| Candidate / accepted field | 8,192 UTF-8 bytes each |
| Accepted values total | 98,304 UTF-8 bytes |
| Composed output | 65,536 UTF-8 bytes; overflow refuses, never truncates |
| Take | 30 seconds; 480,000 mono 16 kHz Float sample ceiling including drain |
| Session | One form and one active take; absolute 20 minutes including approved review; 60 recording starts |

Reaching either take ceiling, route/conversion/drain loss, nonfinite PCM, silence or a below-floor take refuses recognition. A capped prefix is never accepted as a complete take. The actual recorder route may be known, a system fallback, or unknown; no preferred-device or acoustic quality guarantee is made. There is no playback or retained-audio retry.

Only definitions persist in the versioned `guidedTemplates` Settings block (`format: parla-guided-templates`, `schemaVersion: 1`). An absent block is empty without a migration write. Malformed/null/future blocks refuse template actions and writes while unrelated decodable globals remain usable. They are never silently replaced with empty definitions. Narrow CRUD checks revision and fresh bytes, preserves unrelated JSON/legacy credential members, and has a 1 MiB Settings read/write budget. This cap does not apply to ordinary larger full Settings saves. Full writers preserve the fresh template block under the existing lock. Detected byte races refuse; this is not an OS cross-process compare-and-swap guarantee. Definition adoption does not flush/cancel unrelated drafts, debounces or owed callbacks. Pending/error drafts block Begin/output until explicitly saved/repaired.

## Recognition, privacy and disposal

The form freezes saved **global raw** backend/model, language/filter, bounded dictionary hints, input UID and preparation authority. App/site profiles, output presets, cleanup providers, snippets, replacements, transforms and spoken commands do not apply. Hints use existing 2,048-byte ASR / 256-byte per-hint bounds; backends may ignore them. Each eligible take gets a fresh capture/operation/handle through the existing serial queue and recognition factory, with one full final raw pass and no warmup, timed pass, partial-window promotion, fallback or automatic retry.

Field PCM, candidates, accepted values and renders stay in RAM until disposal, except an explicit composed History Save. There is no field History, recovery WAV/corpus, Original-copy retention, correction learning, provider request, automation result, foreign insertion or synthetic paste/keystroke. Definitions and explicitly saved text can themselves be sensitive; no encryption, secret detection or physical memory erasure is promised.

One shared capture lease, owned hotkey suspension and recorder warmth suspension cover the entire wizard, including between fields, candidate/full review, approved output and actual drain. Begin invalidates previous B57 offers/preview, Original-copy and queued mouse/result authority, then waits behind prior queue work before permitting capture. No preference/global Boolean is toggled. Closing the form does not automatically rewarm; existing explicit owner entry is required.

Cancel revokes publication immediately and closes owned capture, then aborts and joins queued/native work. Admission, suspension and lifetime registration release only after actual constructor/converter/native/worker exit. A visibly stopping form can remain charged if native work is blocked; no timeout pretends it exited. Expiry follows the same rule. Page/window/app resign, editor/permission/preparation actions, security evidence, relevant observed saved/draft changes, quit/restart and updater intent discard the form. Changing away and back cannot revive observed revoked authority. Unobserved external changes restored between checks cannot be detected by equality alone. Unchanged valid refresh preserves the form; History policy changes only affect explicit output permission. Quit/restart use the existing concrete local/recognition/import/preparation/clipboard/download participant graph; canceled quit/update failure never restores the form.

Model-free tests exercise production parser, Settings/Hub, recorder adapter, queue/acquisition/factory, session, History and lifecycle owners above explicit synthetic/fake bottoms. They do not qualify physical microphone/route/converter behavior, real assets/backends/preparation/packaging, clipboard acceptance, native UI/VoiceOver/RTL layout, filesystem power loss, acoustic accuracy or human acceptance. Those gates remain separate.
