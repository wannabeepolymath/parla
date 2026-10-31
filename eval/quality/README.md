# Reviewed cleanup text policy (B01 / B09 / B48)

These 25 raw/golden pairs are authored text examples, **not recorded human
speech or generated provider outputs**. `reviewed-results.json` contains authored
accepted outputs (`engine: authored:reviewed-text`), so passing ordinary CI checks
fixture/policy consistency and the offline evaluator. It does not measure live
model quality, ASR accuracy, or human speech coverage. No cleanup prompt or model
default was changed to fit these examples.

Run from the repository root, using the existing executable:

```sh
.build/debug/parla-eval quality-check
.build/debug/parla-eval --self-check
.build/debug/parla-eval verify
```

`verify` retains its separate scorer-drift contract over `eval/results.json`.
That original baseline has not been edited or re-scored in place.

## Check real results offline

When a provider run is authorized separately, the existing runner can consume
this corpus, with its pinned context (currently no dictionary/snippets):

```sh
.build/debug/parla-eval --cleanup-only eval/quality/cases --out /tmp/quality-real.json
.build/debug/parla-eval quality-check --out /tmp/quality-real.json
```

The first command invokes the configured provider; the second only reads files.
`quality-check` never generates or writes outputs. It accepts a real runner's
results format, uses `hypothesis` from every cleanup row, and ignores that run's
`reference` and `wer` fields. A full run may also include ASR rows for these names;
ASR rows cannot satisfy required cleanup coverage. Additional, duplicate or
missing cases are errors. Generate results for this corpus, not a different
corpus or a partially filtered run.

A custom corpus uses `quality-check path/to/cases --policy path/to/rules.json
--out path/to/results.json`. Defaults are the selected case directory's parent
`rules.json` and `reviewed-results.json`; with no directory, use
`eval/quality/cases`. Every raw/golden name must exactly match the policy inventory.

## Explicit failure criteria

`rules.json` has exactly `version: 1` and a non-empty `cases` array. Each rule has
exactly these required fields:

```json
{
  "name": "question",
  "protected": ["autoPay", "?"],
  "alternatives": ["Could you disable autoPay?"]
}
```

The primary accepted output comes from `cases/question.golden.txt` (normal case
headers apply). `alternatives` lists additional reviewed complete outputs; an
empty array permits only the golden. This is intentionally a finite acceptance
policy, not a semantic judge: an unlisted good paraphrase fails until reviewed.

Every accepted/output string gets the same structure normalization: CRLF, CR,
and other Foundation newline characters become LF, horizontal whitespace runs
within each line become a space, and outer whitespace is ignored. Internal
newlines/blank lines, case, punctuation, symbols and lexical content remain
significant. Indentation and exact horizontal spacing are not evaluated, so
these fixtures do not qualify indentation-sensitive code or verbatim bytes.

Each `protected` string is a case-sensitive literal span whose non-overlapping
occurrence count must match the golden after structure normalization. These
explicit constraints cover meaningful phrases, names, negation, quantities,
currency, questions, URLs, identifier case, operators and terminal flags. They
are literal-span checks, not identifier parsing; the full accepted-text check
also rejects embedded/extended tokens and other unlisted output changes.
Every protected span must occur in the golden and with the same count in every
alternative, so a permissive alternative cannot bypass protection.

- Exit **0**: every required cleanup output matches one accepted text and all
  protected literal counts.
- Exit **1**: evaluated output violates accepted content/layout or protected spans.
- Exit **2**: unreadable/malformed policy, corpus or results; missing, duplicate or
  unknown cases; absent constraints/fields; unsupported version/unknown policy
  fields; empty goldens or contradictory alternatives. No silent skip/pass.

The corpus pairs literal `like`, `sort of`, and `you know` with removable uses;
retained hedging versus an explicitly abandoned phrase; correction with retained negation; question with statement; positive with
negative; 15 with 50; $12.50 with $12.05 and €12.50; URL query values and identifier
case/operators. Email paragraphs, list newlines, and a single-line terminal case
exercise layout. These are narrow editorial choices for evaluation, not a claim
that all filler ambiguity is resolved.
