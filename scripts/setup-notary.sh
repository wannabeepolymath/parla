#!/bin/bash
# One-time: save Apple notary credentials to the keychain as "parla-notary",
# which scripts/make-dmg.sh uses. Asks for your Apple ID email here, then
# notarytool asks for an app-specific password (account.apple.com > Sign-In and
# Security > App-Specific Passwords) — not your Apple ID password.
set -euo pipefail
TEAM=$(security find-identity -v -p codesigning \
  | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]*\))".*/\1/p' | head -1)
[ -n "$TEAM" ] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }
read -rp "Apple ID email: " APPLE_ID
xcrun notarytool store-credentials parla-notary --apple-id "$APPLE_ID" --team-id "$TEAM"
