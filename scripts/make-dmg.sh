#!/bin/bash
# Build a signed, notarized, stapled Parla-<version>.dmg (holding a notarized,
# stapled Parla.app) for a GitHub release.
# One-time setup: a "Developer ID Application" certificate in the keychain, and
# either exported APPLE_ID / APPLE_APP_PASSWORD / APPLE_TEAM_ID or
# scripts/setup-notary.sh. Usually run via scripts/release.sh, which tags first.
set -euo pipefail
cd "$(dirname "$0")/.."
# The version is read from the tag, so the tag must be on exactly what ships.
[ -z "$(git status --porcelain)" ] || { echo "Uncommitted changes — commit before releasing." >&2; exit 1; }
TAG=$(git describe --tags --exact-match 2>/dev/null) || { echo "HEAD is not tagged — git tag vX.Y.Z first." >&2; exit 1; }
# codesign matches by name prefix; set PARLA_SIGN_IDENTITY if you hold more than one.
export PARLA_SIGN_IDENTITY=${PARLA_SIGN_IDENTITY:-Developer ID Application}
# Notary auth: the exported credentials when all three are set, else the
# keychain profile scripts/setup-notary.sh stores.
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  # ponytail: --password is visible in `ps` while notarytool runs; the keychain profile avoids that.
  NOTARY=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  NOTARY=(--keychain-profile "${PARLA_NOTARY_PROFILE:-parla-notary}")
fi

scripts/make-app.sh
DMG="Parla-${TAG#v}.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# Notarize and staple the app itself first: the in-app updater mounts the DMG
# programmatically, which never ingests the DMG's ticket, so the app copied out
# of it must carry its own to launch cleanly offline. Same rejection rule as below.
ditto -c -k --keepParent Parla.app "$STAGE/Parla.zip"
xcrun notarytool submit "$STAGE/Parla.zip" "${NOTARY[@]}" --wait
xcrun stapler staple Parla.app
rm "$STAGE/Parla.zip"
cp -R Parla.app "$STAGE/"
ln -s /Applications "$STAGE/Applications" # drag-to-install target
rm -f "$DMG"
hdiutil create -volname Parla -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --timestamp -s "$PARLA_SIGN_IDENTITY" "$DMG"
# A rejected submission still exits 0 here; stapler then fails (no ticket) and
# set -e stops the script. `xcrun notarytool log <id>` (same auth flags) says why.
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "Ready: $DMG"
