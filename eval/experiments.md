# Decoder experiments

Internal switches for answering decoder-policy questions with evidence. They exist only in the
`parla-eval` process: no app setting, no Hub control, no product default changes. With no flags,
`parla-eval` output is byte-identical to before.

## Flags

| Flag | Effect |
|---|---|
| `--experiment LIST` | Comma-separated: `suppress-nst`, `carry-prompt`, `beam=N` (2…8), `vad=PATH`. Unknown, repeated or out-of-range tokens and a missing VAD file exit 2. |
| `--whisper-model PATH` | Recognition model file for this run only (any local ggml file; no catalog change). |
| `--language CODE` | Pins the request language for this run. |
| `--evidence-out FILE` | New file (refuses an existing one). One JSON line per ASR case: `name`, `audioSeconds`, `decodeSeconds`, `model`, `experiment`, `evidence`. Never transcript text. |

All four work with the live modes (`--asr-only`, full) and with `corpus-run`. The ASR `engine`
label of live results carries the experiment (`ggml-base.en.bin+suppress-nst`); for `corpus-run`,
put it in the `--config-revision` you supply.

Temperature fallback and the full audio context stay on in every experiment. Timed decodes (file
import segments) refuse any experiment.

### Reading the evidence

`evidence.segments[]` has `noSpeechProbability`, `tokens` and `meanTokenProbability` per native
segment; `languageRetry`, `requestedLanguage` and `detectedLanguage` describe the language policy.
Token probabilities are the decoder's raw per-token probabilities (special tokens included). They
are **not** calibrated accuracy, and they are not OpenAI's `avg_logprob` or compression ratio.

## The matrix

Every row is a baseline/variant pair on the same cases. Compare with
`swift run parla-eval compare base.json variant.json`, then the evidence files: no-speech
hallucinations (high `noSpeechProbability` with non-empty output), per-case regressions, and
`decodeSeconds`.

```
swift run parla-eval --asr-only DIR --out base.json --evidence-out base.jsonl
swift run parla-eval --asr-only DIR --experiment SWITCH --out variant.json --evidence-out variant.jsonl
```

| Switch | Question | Cases that matter | Would justify shipping |
|---|---|---|---|
| `suppress-nst` | Does suppressing non-speech tokens cut hallucinations without losing text? | Silence/noise tails **and** cases with code symbols, brackets, URLs and literal punctuation: upstream's suppression list contains symbols dictation needs. | Fewer hallucinated words, no lost symbols in any case, no per-case regression. |
| `carry-prompt` | Does re-sending the dictionary prompt every 30 s window help later windows? | Only clips **longer than 30 s** with dictionary terms after the first window (today the dictionary conditions only the first window). | Dictionary terms recovered after 30 s with no regression elsewhere. |
| `beam=N` | Does beam search beat greedy enough to pay its decode time? | All cases; watch `decodeSeconds`. | A WER gain worth the measured slowdown on target hardware. |
| `vad=PATH` | Does native VAD trim silence-induced hallucinations? | Long recordings with pauses. **Experiment only, never for timed output.** Record the VAD model file and its sha256 in the run notes. | Not a product switch without a separate timing design. |
| `--whisper-model` | Is another model file better for this corpus? | Any. | A catalog change is a separate decision. |

Synthetic `syn-*` cases cannot settle any of these. They need the human corpus (`corpus-run`,
see the README) and the acoustic smoke clips (`eval/smoke/`).

## Needs a human

- [ ] Obtain the whisper.cpp VAD model file from the upstream project, record its sha256, keep it
      outside the repo.
- [ ] Run the matrix on the human corpus and the smoke clips; file the `compare` output and evidence
      files with the run notes.
- [ ] Decide from that evidence whether any switch becomes a product default — a separate change.
