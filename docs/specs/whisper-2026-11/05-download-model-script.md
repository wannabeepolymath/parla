# Lane 05 — `download-model.sh` staging, digest check, promotion

Wave 1 · Risk: Low · Depends on: nothing

## Goal

The helper script treats any existing file as a good model and downloads straight onto the final
filename, so an interrupted download looks "already present" forever. Make it stage, verify the
pinned digest, then promote. A `.part` file plus a rename is not verification; the digest is.

## Files owned

- `scripts/download-model.sh`
- `scripts/tests/test_download_model.py` (new; the directory already holds Python script tests)

## Current code

`scripts/download-model.sh` (12 lines): `[ -f "$FILE" ] && exit 0`, then
`curl -L --fail -o "$FILE"`. Its usage line advertises `base.en|large-v3-turbo|tiny.en`; only
`base.en` is a catalog id. Pinned sizes and digests live in `Sources/ParlaCore/ModelCatalog.swift`
(`ModelCatalog.all`) and are duplicated in `android/.../ModelCatalog.kt`.

## Design

1. A pin table in the script mirroring `ModelCatalog.all` exactly — id, bytes, sha256 for
   `base.en`, `small.en-q5_1`, `large-v3-turbo-q5_0`. Copy the values from `ModelCatalog.swift`;
   do not type digests from memory and do not add ids that are not in the catalog.
2. Arguments: `download-model.sh [ID] [--dir DIR] [--sha256 HEX --bytes N]`.
   - Known id → pinned values. Unknown id → refuse with the list of known ids, unless **both**
     `--sha256` and `--bytes` are given (the caller supplies the pin; the script never trusts an
     unpinned download).
   - `--dir` overrides the destination (needed by lane 10's CI cache and by the test). Default
     unchanged: `~/Library/Application Support/Parla/models`.
3. Flow:
   - Existing final file: verify size then `shasum -a 256`. Match → "verified: path", exit 0.
     Mismatch → say so, move it aside to `ggml-ID.bin.rejected` (never silently delete a user
     file), and continue to download.
   - Download to `ggml-ID.bin.part` in the same directory (`curl -L --fail`), with a `trap` that
     removes the `.part` on any exit.
   - Verify size, then reject an HTML payload (first bytes start with `<!doctype`, `<html`, `<head`
     or `<?xml`, case-insensitive — same rule as `ModelCatalog.looksLikeMarkup`), then the digest.
   - Only then `mv -f` the `.part` onto the final name (same directory, so the rename is atomic).
   - Any verification failure: non-zero exit, final path untouched.
4. `PARLA_MODEL_BASE_URL` env override for the URL prefix, default the HuggingFace URL. The test
   uses it with `file://`; document it as a test seam.

## Acceptance criteria and checks (one per behaviour)

`scripts/tests/test_download_model.py` (`unittest`, stdlib only, temp dirs, `file://` source):

| Behaviour | Test |
|---|---|
| Good download is promoted | Custom id with `--sha256/--bytes` of a small temp file → final file exists, no `.part` left |
| Wrong digest never reaches the final name | Same file, wrong `--sha256` → non-zero exit, no final file, no `.part` |
| A truncated existing file is not accepted | Pre-create a short final file → script re-downloads, final file has the right digest, the short one is at `.rejected` |
| Verified existing file is a no-op | Second run exits 0 without fetching (point the URL at a missing path to prove it) |
| Unknown id without a pin is refused | `tiny.en` with no `--sha256` → non-zero exit naming the known ids |
| Pin table matches the catalog | Parse `ModelCatalog.swift` for `id:`/`bytes:`/`sha256:` triples and compare with the script's table |

## Checks to run

- `python3 -m unittest scripts/tests/test_download_model.py`
- `bash -n scripts/download-model.sh` (and `shellcheck scripts/download-model.sh` if installed)

No real model download in this lane.

## Out of scope

- Resumable downloads, mirrors, progress UI.
- Changing the app's installer (`ModelInstaller`, `CatalogDownload*`) — already verified.
- Adding `tiny.en` or any new model pin.

## Needs a human

- [ ] One real run: `scripts/download-model.sh base.en --dir "$(mktemp -d)"` on a normal network,
      confirming the pinned digest still matches what HuggingFace serves.
