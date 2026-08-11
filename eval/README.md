# Parla eval harness

Measures whether Parla's output is getting better or worse. Two metrics per leg:

- **zero-edit rate** — fraction where the output needs *zero* edits versus a
  human-written golden (case- and punctuation-sensitive). This is the product
  promise, and it is binary.
- **WER** — word error rate over a canonically normalized token stream, so a
  one-word regression is distinguishable from a total failure. Reported as
  corpus WER, **p50, p90 and failure rate (WER > 20 %)** — a mean hides exactly
  the tail that makes a dictation app feel broken.

Both sides of every comparison go through the **same** normalizer
(`Eval.werTokens`): curly apostrophes folded first, then case, punctuation,
whitespace and single-word numbers (`six` == `6`). Normalizing one side only is
the most common way a WER harness lies. Digits still count for zero-edit rate,
which is why both metrics are reported.

```
swift run parla-eval [dir]            # full pipeline: wav → whisper → cleanup
swift run parla-eval --asr-only       # whisper leg only  (no API key needed)
swift run parla-eval --cleanup-only   # cleanup leg only  (no model needed)
swift run parla-eval verify           # re-score committed fixtures, offline
```

`dir` defaults to `eval/cases`. The two partial modes exist so an ASR
regression and a cleanup regression are never conflated.

## Case kinds

A case is `NAME.golden.txt` — the expected **cleaned** text — plus at least one
input:

| File | Role |
|---|---|
| `NAME.wav` | 16 kHz mono audio; drives the whisper leg |
| `NAME.raw.txt` | verbatim transcript: the **ASR reference** when a `.wav` exists, otherwise the **cleanup input** (a text-only case) |

**Text cases need no microphone.** They exercise the cleanup path directly, and
they are how the corpus grew past its original two entries. **Audio cases are
still missing**: only `hello.wav` and `fillers.wav` exist, neither has a
`.raw.txt`, so the ASR leg is currently unscored and everything below the
whisper decoder is unmeasured. Recording that corpus is outstanding work — the
text cases do not substitute for it.

Golden files may lead with header lines, which are stripped before comparison:

```
# category: terminal
# app: Ghostty
# bundle: com.mitchellh.ghostty
- npm install - npm run build - npm test
```

- `category` — groups the per-category WER breakdown in the report.
- `app` — the app name given to the cleanup prompt (tone).
- `bundle` — the insertion target. Terminals and chat apps where Return submits
  get `TextRules.flattenForTerminal` applied to the output, exactly as the app
  does, so a list dictated into a terminal is checked on one line.

Categories currently covered by text cases: `fillers`, `self-correction`,
`lists`, `numbers`, `code`, `terminal`, `injection` (instruction-shaped speech
that must be transcribed, never obeyed), `jargon`, `snippets`.

## Reproducibility

The cleanup context is pinned to `eval/context.json` (dictionary + snippets),
**not** to your live Settings — an eval that reads the developer's settings is
not reproducible. Only provider credentials (key, model, base URL) still come
from Settings.

## Recording an audio case

`say` and other TTS **will not do** — the whole point is real speech (fillers,
self-corrections, trailing-off). Record yourself:

- QuickTime Player → New Audio Recording → export, converted to 16 kHz mono, or
- `sox -d -r 16000 -c 1 eval/cases/name.wav` (Ctrl-C to stop).

Then write `name.raw.txt` (what was actually said, verbatim — this scores the
ASR leg) and `name.golden.txt` (what Parla should have inserted).

## `verify` — the CI gate

A full run writes `eval/results.json`: every scored leg with its reference and
hypothesis. Commit it. `parla-eval verify` re-scores those committed
hypotheses with today's normalizer and scorers — **no model, no API key, no
network** — so a change to `Eval`, `CleanupSanitizer`, `TextRules` or the
degenerate-output guards is caught in seconds. Until a full run has been done
and committed, `verify` reports zero fixtures and exits 0.

## Requirements (full run only)

- The whisper model at `~/Library/Application Support/Parla/models/ggml-base.en.bin`.
- An Anthropic API key: `ANTHROPIC_API_KEY`, or `anthropicApiKey` in Settings.

## Output

```
near cleanup correction-number (wer 0.0%)
  golden: The timeout is 10 seconds.
  actual: The timeout is ten seconds.
cleanup: n=23  zero-edit 21/23 (91.3%)  wer 1.8%  p50 0.0%  p90 5.0%  fail(>20%) 0/23
  by category: code 2.1%  fillers 0.0%  injection 0.0%  ...
  latency p50/p95: 0.81s/1.02s
```

Exit codes: `0` clean · `1` quality regression (some case scored WER > 20 %) ·
`2` model or API key missing · `3` infrastructure error (unreadable WAV,
cleanup request failed). A network flake and a real quality regression must
never share an exit code.
