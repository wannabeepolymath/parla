#!/bin/bash
# Bundle the release binary into Parla.app (mic permission needs an Info.plist).
# PARLA_SIGN_IDENTITY set (scripts/make-dmg.sh does this) ⇒ a universal,
# Developer ID-signed, hardened-runtime build; unset ⇒ a local ad-hoc build.
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID=io.github.wannabeepolymath.parla
# The update check compares this against the latest GitHub release tag, so it
# must come from the tag, not a hand-edited string that drifts behind it.
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
VERSION=${VERSION#v}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
SIGN_ID=${PARLA_SIGN_IDENTITY:-}
ARCHS=""
[ -n "$SIGN_ID" ] && ARCHS="--arch arm64 --arch x86_64"
swift build -c release --product Parla $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)
APP=Parla.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Parla" "$APP/Contents/MacOS/Parla"
# App icon (Finder/Cmd-Tab/About) + menu-bar template glyph. Regenerate with scripts/make-icon.sh.
cp Resources/AppIcon.icns Resources/menubar.png "$APP/Contents/Resources/"
# whisper is a dylib framework now (v1.9.1 xcframework) — bundle it and point
# the binary's @rpath at Contents/Frameworks or the app dies on launch.
cp -R "$BIN/whisper.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Parla"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Parla</string>
    <key>CFBundleExecutable</key><string>Parla</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.3</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Parla transcribes what you dictate, on this Mac only. The microphone is opened while you dictate; an optional setting holds it open between dictations so one starts instantly, at the cost of the microphone indicator staying lit. Only a dictation's own audio is transcribed.</string>
</dict>
</plist>
EOF
if [ -n "$SIGN_ID" ]; then
  # Inside-out: the framework first, so the app's seal covers its final signature.
  codesign --force --timestamp --options runtime -s "$SIGN_ID" "$APP/Contents/Frameworks/whisper.framework"
  codesign --force --timestamp --options runtime -s "$SIGN_ID" \
    --entitlements Resources/Parla.entitlements "$APP"
else
  # Stable designated requirement: TCC ties Mic/Accessibility grants to the DR;
  # plain ad-hoc uses the per-build cdhash, so every rebuild wiped the grants.
  # Local builds only — a Developer ID signature's default DR (identifier +
  # team) is already stable, and this one would trust any same-ID app.
  codesign --force -s - "$APP/Contents/Frameworks/whisper.framework"
  codesign --force -s - --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
echo "Built $APP $VERSION ($BUILD) — run: open $APP"
