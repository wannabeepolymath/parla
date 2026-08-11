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
swift run parla-eval compare a b      # diff two results files (see A/B below)
```

`dir` defaults to `eval/cases`. The two partial modes exist so an ASR
regression and a cleanup regression are never conflated.

Two flags modify a run: `--model <id>` swaps the cleanup model for that run
only, and `--out <path>` writes the fixtures somewhere other than
`eval/results.json`. Together they are the A/B recipe below.

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

## A/B: comparing two cleanup models

The default `cleanupModel` was picked on cost and latency. This is the recipe
for measuring it. **It has been run once** — haiku-4-5 vs sonnet-5, plus a
same-model calibration run — and the answer was that this corpus cannot tell
them apart: the noise between two runs of the *same* model (9 of 30 cases,
13.3pp of zero-edit) was larger than anything between the two models, and the
net sign flipped depending on which calibration run you compared against. See
`progress.md`, "Tier 1 #14". The default stands, and the next useful move is
more cases, not more runs.

`--model` replaces the cleanup model for one run and never writes
`settings.json`. It covers both provider shapes — `anthropic` reads
`cleanupModel`, `openai-compatible` reads `cleanup.model` — so pass whatever id
your configured provider serves. Credentials and base URL still come from
Settings; only the model name moves.

```
swift run parla-eval --cleanup-only --model <A> --out /tmp/ab-a.json
swift run parla-eval --cleanup-only --model <B> --out /tmp/ab-b.json
swift run parla-eval compare /tmp/ab-a.json /tmp/ab-b.json
```

`--cleanup-only` keeps whisper out of it: no model download, and the ASR leg
cannot drift between the two runs. The output goes to `/tmp` deliberately —
`eval/` is not gitignored, and these files are scratch. Only the default
`eval/results.json` is the baseline `verify` gates on, and it must stay a run of
the default model, which is why a partial mode still refuses to write it.

`compare` prints, per leg and per category, zero-edit rate, corpus WER and
p50/p90 — then **the cases the two runs scored differently, worst first, with
the golden and both outputs**. Read that list. The aggregates tell you *whether*
something moved; only the per-case diff tells you *why*, and whether the model
that scores better is better in ways you want.

It exits `0` even when one model is plainly worse: that is the result, not a
failure. Non-zero means the comparison could not be made at all — `3` for a
missing or unreadable file, `2` for two files with no case in common.

### How big a delta is worth acting on?

Cleanup is **not deterministic**. The same model on the same case can return
different text on two runs, so both metrics move when nothing has changed. Two
runs of the *same* model are the calibration for this, and are worth doing once
before reading any A/B. Against today's corpus — **n = 32** cleanup cases, ~370
reference words — the resolution is coarse:

| Smallest thing that can move | What it shows up as |
|---|---|
| one case flipping zero-edit | 3.1pp of zero-edit rate |
| one word edited | 0.27pp of corpus WER |

So, concretely:

- **One or two cases (≈3–6pp of zero-edit) is noise.** A corpus WER move under
  ~1pp is three or four edited words across all 32 cases — also noise. Do not
  move the default on either.
- **Six or more cases flipping one way with none flipping back** is the smallest
  result that beats a coin toss at this n (sign test, p ≈ 0.03). Mixed movement
  needs more than that.
- **Do not decide on p90.** At n = 32 it is set by the worst three or four
  cases. Use it to find cases to read, not to pick a model.

Re-running to break a tie helps less than it feels like it should. More runs
average out the model's per-run noise, but they cannot shrink the uncertainty
that comes from having only 32 cases, and they keep resampling the same 32
choices. **The honest way to settle a close call is more cases** — ideally in
the category where `compare` showed the two models disagreeing — not more runs
of the cases already here.

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
`2` model or API key missing, or unusable `compare` arguments · `3`
infrastructure error (unreadable WAV, cleanup request failed, unreadable
`compare` input). A network flake and a real quality regression must never
share an exit code — and for the same reason `compare` never returns `1`: one
model scoring worse than another is its answer, not its failure.

`swift run parla-eval --self-check` asserts the `compare` arithmetic offline in
a few milliseconds — no corpus, no key, no network. It is the only check the
comparison math gets, because exercising it for real costs two full runs.
