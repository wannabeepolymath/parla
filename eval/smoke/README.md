# Acoustic smoke tier

`ci.yml` never loads a model, so a broken native integration (prompt wiring, resampling, marker
stripping, language pin) stays invisible until someone dictates. This tier runs the shipping
recognition path on a few fixed clips with one pinned model.

**What it proves:** the real `base.en` model loads, decodes known audio through `parla-eval
--asr-only` (the same recognition path the app uses), and each clip stays at or under the 20 %
per-case WER threshold `parla-eval` already applies. The model-gated `TranscriberTests` run
instead of skipping.

**What it does not prove:** model quality, multilingual behaviour, noisy or accented speech, or
anything about Android, iOS or Linux. The model is tiny and the clips are clean; a pass means
"integration not broken", nothing more.

## How it runs

`.github/workflows/acoustic-smoke.yml` (manual dispatch and weekly):

1. `scripts/download-model.sh base.en` — digest-checked, cached on the `base.en` sha256.
2. `scripts/fetch-smoke-assets.sh` — reads `clips.tsv`, downloads each clip to a `.part`, checks
   bytes and sha256, promotes it to `cases/NAME.wav`, and writes `NAME.raw.txt` and
   `NAME.golden.txt` (`# category: smoke`) from `reference_text`. A digest mismatch fails the run.
   With no rows it prints `no smoke clips configured` and exits 0.
3. `swift test --filter TranscriberTests`.
4. `swift run parla-eval --asr-only eval/smoke/cases --out "$RUNNER_TEMP/smoke.json"`, or an
   explicit `SKIPPED: no smoke clips configured` line when there are no clips. Exit codes are
   `parla-eval`'s: 1 a case over 20 % WER, 2 missing model, 3 infrastructure error.
5. `smoke.json` is uploaded as an artifact.

Run it locally the same way: `scripts/download-model.sh base.en && scripts/fetch-smoke-assets.sh`
then step 4 with any `--out` path.

## Adding a clip

`clips.tsv` is tab-separated with a header row:
`name  url  sha256  bytes  license  attribution  reference_text`.

- Clips must be 16 kHz mono 16-bit WAV (what `Eval.loadSamples` reads). If the source is in another
  format, convert it (e.g. `afconvert -f WAVE -d LEI16@16000 -c 1 in.flac out.wav`), host the
  converted file, and record the digest and size **of the converted file**. Note the conversion in
  the `attribution` column.
- `sha256` is `shasum -a 256 FILE`, `bytes` is `wc -c < FILE`.
- `reference_text` is the exact verbatim transcript.
- Fetched WAVs are gitignored. Commit one (`git add -f`) only when its licence allows it.

Never add a row you have not downloaded and checked yourself.

## Needs a human

- [ ] Choose 3–6 short clips with a licence that permits this use (public-domain speech or CC0 /
      CC BY corpora are the usual candidates). Read the licence; record it and the attribution.
- [ ] Download each, convert if needed to 16 kHz mono 16-bit WAV, compute `shasum -a 256` and size,
      and add the rows to `clips.tsv` with an exact reference transcript.
- [ ] Decide per clip whether the licence allows committing the WAV; otherwise keep it fetched.
- [ ] Trigger the workflow once manually and confirm the model cache, the fetch step and the
      `parla-eval` step behave; fix the workflow from that run's logs.
- [ ] Include at least one clip with a proper noun so a prompt-wiring regression is visible.
