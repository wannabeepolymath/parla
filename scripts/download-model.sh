#!/bin/bash
# Download a pinned ggml whisper model: stage to .part, verify size + sha256, then promote.
# Usage: scripts/download-model.sh [ID] [--dir DIR] [--sha256 HEX --bytes N]   (default: base.en)
#   Known ids use the pins below. Any other id needs both --sha256 and --bytes.
#   --dir defaults to ~/Library/Application Support/Parla/models.
#   PARLA_MODEL_BASE_URL overrides the URL prefix (test seam, e.g. file:///tmp/src).
set -euo pipefail

# id bytes sha256 — mirrors ModelCatalog.all in Sources/ParlaCore/ModelCatalog.swift.
PINS="
base.en 147964211 a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
small.en-q5_1 190098681 bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30
large-v3-turbo-q5_0 574041195 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
"

MODEL=base.en
DIR="$HOME/Library/Application Support/Parla/models"
SHA=""
BYTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    --sha256) SHA="${2:?--sha256 needs a value}"; shift 2 ;;
    --bytes) BYTES="${2:?--bytes needs a value}"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) MODEL="$1"; shift ;;
  esac
done

# The id becomes a filename and a URL path segment.
[[ "$MODEL" =~ ^[A-Za-z0-9._-]+$ && "$MODEL" != .* ]] || { echo "invalid model id: $MODEL" >&2; exit 2; }

PIN=$(awk -v id="$MODEL" '$1 == id { print $2, $3 }' <<<"$PINS")
if [ -n "$PIN" ]; then
  read -r BYTES SHA <<<"$PIN"
elif [ -z "$SHA" ] || [ -z "$BYTES" ]; then
  echo "unknown model id: $MODEL (known: $(awk 'NF { printf "%s ", $1 }' <<<"$PINS"))" >&2
  echo "for another model pass both --sha256 HEX and --bytes N" >&2
  exit 2
fi
SHA=$(tr '[:upper:]' '[:lower:]' <<<"$SHA")
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "--sha256 must be 64 hex characters" >&2; exit 2; }
[[ "$BYTES" =~ ^[0-9]+$ ]] || { echo "--bytes must be a number" >&2; exit 2; }

# Size, then not an HTML page (ModelCatalog.looksLikeMarkup), then the digest.
verify() {
  local f=$1 size head digest
  size=$(wc -c <"$f" | tr -d ' ')
  [ "$size" = "$BYTES" ] || { echo "$f: $size bytes != pinned $BYTES" >&2; return 1; }
  head=$(head -c 512 "$f" | LC_ALL=C tr -d '\0' | LC_ALL=C tr '[:upper:]' '[:lower:]')
  head="${head#"${head%%[![:space:]]*}"}"  # trim leading whitespace
  case "$head" in
    '<!doctype'* | '<html'* | '<head'* | '<?xml'*)
      echo "$f: server returned a web page, not a model" >&2; return 1 ;;
  esac
  digest=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [ "$digest" = "$SHA" ] || { echo "$f: sha256 $digest != pinned $SHA" >&2; return 1; }
}

mkdir -p "$DIR"
FILE="$DIR/ggml-$MODEL.bin"
PART="$FILE.part"

if [ -f "$FILE" ]; then
  if verify "$FILE"; then echo "verified: $FILE"; exit 0; fi
  mv -f "$FILE" "$FILE.rejected"
  echo "moved unverified file to $FILE.rejected; downloading again" >&2
fi

trap 'rm -f "$PART"' EXIT
curl -L --fail --silent --show-error -o "$PART" \
  "${PARLA_MODEL_BASE_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main}/ggml-$MODEL.bin"
verify "$PART" || exit 1
mv -f "$PART" "$FILE"  # same directory, so the rename is atomic
echo "downloaded: $FILE"
