#!/bin/bash
# Fetch the acoustic smoke clips listed in eval/smoke/clips.tsv: stage each to .part,
# verify size + sha256, then promote to CASES/NAME.wav and write NAME.raw.txt / NAME.golden.txt.
# Usage: scripts/fetch-smoke-assets.sh [MANIFEST] [CASES]   (defaults: eval/smoke/clips.tsv eval/smoke/cases)
# Manifest columns (tab-separated, header row first): name url sha256 bytes license attribution reference_text
set -euo pipefail

MANIFEST="${1:-eval/smoke/clips.tsv}"
CASES="${2:-eval/smoke/cases}"
# The loop reads through process substitution, which hides a missing file from set -e.
[ -f "$MANIFEST" ] && [ -r "$MANIFEST" ] || { echo "manifest not readable: $MANIFEST" >&2; exit 1; }
mkdir -p "$CASES"

PART=""
trap '[ -z "$PART" ] || rm -f "$PART"' EXIT
count=0
while IFS=$'\t' read -r name url sha bytes license attribution reference || [ -n "${name:-}" ]; do
  [ -n "${name:-}" ] || continue
  # The name becomes a filename.
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "invalid clip name: $name" >&2; exit 1; }
  sha=$(tr '[:upper:]' '[:lower:]' <<<"$sha")
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "$name: sha256 must be 64 hex characters" >&2; exit 1; }
  [[ "$bytes" =~ ^[0-9]+$ ]] || { echo "$name: bytes must be a number" >&2; exit 1; }
  [ -n "$license" ] && [ -n "$reference" ] || { echo "$name: license and reference_text are required" >&2; exit 1; }
  WAV="$CASES/$name.wav"
  PART="$WAV.part"
  curl -L --fail --silent --show-error -o "$PART" "$url"
  size=$(wc -c <"$PART" | tr -d ' ')
  [ "$size" = "$bytes" ] || { echo "$name: $size bytes != pinned $bytes" >&2; exit 1; }
  digest=$(shasum -a 256 "$PART" | cut -d' ' -f1)
  [ "$digest" = "$sha" ] || { echo "$name: sha256 $digest != pinned $sha" >&2; exit 1; }
  mv -f "$PART" "$WAV"; PART=""
  printf '%s\n' "$reference" >"$CASES/$name.raw.txt"
  printf '# category: smoke\n%s\n' "$reference" >"$CASES/$name.golden.txt"
  echo "fetched: $name ($license; $attribution)"
  count=$((count + 1))
done < <(tail -n +2 "$MANIFEST")

[ "$count" -gt 0 ] || echo "no smoke clips configured"
