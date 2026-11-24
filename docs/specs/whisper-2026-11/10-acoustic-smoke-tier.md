# Lane 10 — Acoustic smoke tier: one pinned model, a few licensed clips

Wave 2 · Risk: Medium · Depends on: lane 05 (`download-model.sh --dir`, digest check), lane 04 (eval prompt path)

## Goal

CI never loads a model, so a broken native integration (prompt wiring, resampling, marker
stripping, language pin) is invisible until a person dictates. Add a small, separate tier that runs
real recognition on fixed audio. It detects integration breakage; it does not qualify model quality.

Keep it small: reuse `parla-eval --asr-only` and the existing case-file format. No new test
framework, no new schema.

## Files owned

- `eval/smoke/README.md` (new)
- `eval/smoke/clips.tsv` (new; header row only until a human fills it)
- `eval/smoke/cases/.gitkeep` (new)
- `scripts/fetch-smoke-assets.sh` (new)
- `.github/workflows/acoustic-smoke.yml` (new)
- `eval/README.md` (one pointer paragraph)
- `.gitignore` (ignore fetched `eval/smoke/cases/*.wav` unless a clip's licence allows committing it)

## What already exists (reuse, do not rebuild)

- `parla-eval --asr-only DIR --out FILE`: discovers `NAME.wav` + `NAME.raw.txt` + `NAME.golden.txt`,
  runs the shipping recognition path on the default catalog model, prints per-case WER, exits 1
  when a case exceeds 20 % WER, 2 on a missing model, 3 on infrastructure errors.
- `WhisperTranscriber.defaultModelPath()` is `base.en`, whose size and sha256 are pinned in
  `ModelCatalog.all`.
- Model-gated tests that skip without a model: `TranscriberTests.testTranscribeSilenceProducesNoCrash`,
  `testMultilingualModelFollowsTheSpeakerLikeWhisperAutoDetect`, and (after lanes 01 and 07) the
  prompt-budget and language-range tests.
- `.github/workflows/ci.yml`: the fast offline tier. Do not change it.

## Design

1. **Pinned model: `base.en`** — the only English model already pinned by digest in the repo and the
   product default. Fetched with `scripts/download-model.sh base.en` (lane 05 verifies the digest).
   One model only. The multilingual model (574 MB) stays out of this tier.

2. **Clip manifest `eval/smoke/clips.tsv`**, tab-separated, one clip per row:
   `name  url  sha256  bytes  license  attribution  reference_text`
   - This lane commits the header and **no rows**. Digests, URLs and licences are entered by a
     person who has downloaded and checked each clip. Never invent a row.
   - Clips must be 16 kHz mono 16-bit WAV (what `Eval.loadSamples` reads) or the README must say how
     the human converted them and which bytes the digest covers (the converted file).

3. **`scripts/fetch-smoke-assets.sh`**: for each row, download to a `.part`, check bytes and
   sha256, promote to `eval/smoke/cases/NAME.wav`, and write `NAME.raw.txt` and `NAME.golden.txt`
   from `reference_text` (golden gets a `# category: smoke` header). Zero rows → print
   "no smoke clips configured" and exit 0. A digest mismatch is a hard failure.

4. **Workflow `acoustic-smoke.yml`**: `workflow_dispatch` plus a weekly `schedule`; `macos-15`
   (same pin as `ci.yml`). Steps:
   - checkout; cache the model directory keyed on the `base.en` sha256;
   - `scripts/download-model.sh base.en`;
   - `scripts/fetch-smoke-assets.sh`;
   - `swift test --filter TranscriberTests` (the model-gated tests now run);
   - if `eval/smoke/cases` has any `.wav`: `swift run parla-eval --asr-only eval/smoke/cases --out "$RUNNER_TEMP/smoke.json"`;
     otherwise print an explicit "SKIPPED: no smoke clips configured" line — a visible skipped
     prerequisite, never a silent green;
   - upload `smoke.json` as an artifact.
   The workflow builds because CI must; nothing in this lane asks the implementer to build locally.

5. **`eval/smoke/README.md`**: what the tier proves and does not prove (tiny model, clean clips,
   integration only), how to add a clip, the 20 % per-case threshold inherited from `parla-eval`,
   and the human checklist below.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Check |
|---|---|
| Fetch script verifies before promoting | Run it against a temp TSV with one `file://` row: correct digest → case files created; wrong digest → non-zero exit and no `.wav` |
| Empty manifest is an explicit skip | Run with the committed header-only TSV → exit 0 and the "no smoke clips configured" line |
| Workflow is well-formed | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/acoustic-smoke.yml'))"` (or `actionlint` if installed) |
| Offline CI untouched | `git diff --stat` shows no change to `.github/workflows/ci.yml` |

## Checks to run

- `bash -n scripts/fetch-smoke-assets.sh` (and `shellcheck` if installed)
- The two local fetch-script runs above, in a temp directory.
- YAML parse of the workflow.

The workflow itself cannot be validated locally. Say so in the report.

## Out of scope

- Any quality gate on shipping models, a multilingual clip set, Android/iOS/Linux runners, a
  platform matrix, timing-anchor or cancellation tests beyond what `TranscriberTests` already has.
- Committing audio whose licence has not been checked by a person.

## Needs a human

- [ ] Choose 3–6 short clips with a licence that permits this use (public-domain speech or CC0 /
      CC BY corpora are the usual candidates). Read the licence; record it and the attribution.
- [ ] Download each, convert if needed to 16 kHz mono 16-bit WAV, compute `shasum -a 256` and size,
      and add the rows to `eval/smoke/clips.tsv` with an exact reference transcript.
- [ ] Decide per clip whether the licence allows committing the WAV; otherwise keep it fetched.
- [ ] Trigger the workflow once manually and confirm the model cache, the fetch step and the
      `parla-eval` step behave; fix the workflow from that run's logs.
- [ ] Include at least one clip with a proper noun so a prompt-wiring regression is visible.
