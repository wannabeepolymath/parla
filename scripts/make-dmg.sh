#!/bin/bash
# Build a signed, notarized, stapled Parla-<version>.dmg for a GitHub release.
# One-time setup: a "Developer ID Application" certificate in the keychain, and
# scripts/setup-notary.sh. Usually run via scripts/release.sh, which tags first.
set -euo pipefail
cd "$(dirname "$0")/.."
# The version is read from the tag, so the tag must be on exactly what ships.
[ -z "$(git status --porcelain)" ] || { echo "Uncommitted changes — commit before releasing." >&2; exit 1; }
TAG=$(git describe --tags --exact-match 2>/dev/null) || { echo "HEAD is not tagged — git tag vX.Y.Z first." >&2; exit 1; }
# codesign matches by name prefix; set PARLA_SIGN_IDENTITY if you hold more than one.
export PARLA_SIGN_IDENTITY=${PARLA_SIGN_IDENTITY:-Developer ID Application}
PROFILE=${PARLA_NOTARY_PROFILE:-parla-notary}

scripts/make-app.sh
DMG="Parla-${TAG#v}.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R Parla.app "$STAGE/"
ln -s /Applications "$STAGE/Applications" # drag-to-install target
rm -f "$DMG"
hdiutil create -volname Parla -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --timestamp -s "$PARLA_SIGN_IDENTITY" "$DMG"
# A rejected submission still exits 0 here; stapler then fails (no ticket) and
# set -e stops the script. `xcrun notarytool log <id> --keychain-profile $PROFILE` says why.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "Ready: $DMG"
