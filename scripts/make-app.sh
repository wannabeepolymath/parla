#!/bin/bash
# Bundle the release binary into Parla.app (mic permission needs an Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=Parla.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/Parla "$APP/Contents/MacOS/Parla"
# App icon (Finder/Cmd-Tab/About) + menu-bar template glyph. Regenerate with scripts/make-icon.sh.
cp Resources/AppIcon.icns Resources/menubar.png "$APP/Contents/Resources/"
# whisper is a dylib framework now (v1.9.1 xcframework) — bundle it and point
# the binary's @rpath at Contents/Frameworks or the app dies on launch.
cp -R .build/release/whisper.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Parla"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.parla.app</string>
    <key>CFBundleName</key><string>Parla</string>
    <key>CFBundleExecutable</key><string>Parla</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Parla transcribes what you dictate, on this Mac only. It holds the microphone open between dictations (except Bluetooth ones) so one starts the moment you press the hotkey; only a dictation's own audio — what you say, plus the half-second before it starts — is transcribed.</string>
</dict>
</plist>
EOF
# Stable designated requirement: TCC ties Mic/Accessibility grants to the DR;
# plain ad-hoc uses the per-build cdhash, so every rebuild wiped the grants.
codesign --force -s - "$APP/Contents/Frameworks/whisper.framework"
codesign --force -s - --identifier com.parla.app \
  -r='designated => identifier "com.parla.app"' "$APP"
echo "Built $APP — run: open $APP"
