#!/bin/bash
# Cut a release: tag HEAD, build the notarized DMG, push the tag, and open a
# DRAFT GitHub release with the DMG attached. Drafts are invisible to the
# in-app update check, so install from the DMG and dictate once, then publish:
#   gh release edit vX.Y.Z --draft=false
# Usage: scripts/release.sh v0.5.0
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=${1:-}
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 vX.Y.Z" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Uncommitted changes — commit before releasing." >&2; exit 1; }
# Re-runnable: a tag left by a failed run is fine if it's on this commit.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [ "$(git rev-list -n1 "$TAG")" = "$(git rev-parse HEAD)" ] \
    || { echo "$TAG already exists on another commit." >&2; exit 1; }
else
  git tag "$TAG"
fi
scripts/make-dmg.sh
git push origin "$TAG"
gh release create "$TAG" "Parla-${TAG#v}.dmg" --draft --generate-notes --verify-tag
echo "Draft $TAG created. Test the DMG, then: gh release edit $TAG --draft=false"
