#!/bin/bash
# Regenerate the iOS app icon and in-app logo from the desktop Parla artwork.
# Icon: the waveform art from ../Resources/parla.svg, centre-cropped square, full bleed (iOS masks corners).
# Logo: the desktop's white waveform template, ../Resources/menubar.png. Needs macOS (sips).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -I - ../Resources/parla.svg "$T/art.jpg" <<'PY'
import re, base64, sys, pathlib
svg = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(re.search(r'href="data:image/jpeg;base64,([^"]+)"', svg).group(1)))
PY
side=$(sips -g pixelWidth -g pixelHeight "$T/art.jpg" | awk '/pixel/ {print $2}' | sort -n | head -1)
sips -c "$side" "$side" "$T/art.jpg" --out "$T/square.jpg" >/dev/null
sips -z 1024 1024 -s format png "$T/square.jpg" --out Resources/Assets.xcassets/AppIcon.appiconset/ParlaIcon.png >/dev/null
mkdir -p Resources/Assets.xcassets/ParlaLogo.imageset
cp ../Resources/menubar.png Resources/Assets.xcassets/ParlaLogo.imageset/ParlaLogo.png
cat > Resources/Assets.xcassets/ParlaLogo.imageset/Contents.json <<'JSON'
{
  "images" : [ { "filename" : "ParlaLogo.png", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : false, "template-rendering-intent" : "template" }
}
JSON
echo "Wrote AppIcon ParlaIcon.png and ParlaLogo.imageset"
