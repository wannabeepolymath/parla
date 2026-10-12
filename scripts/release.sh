#!/bin/bash
# Cut a release: pick the version, check everything that can fail cheaply,
# then tag, build the notarized DMG, push, and create (or resume) the GitHub
# release with release-notes/vX.Y.Z.md as its body.
#
#   export APPLE_ID=you@example.com APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx APPLE_TEAM_ID=XXXXXXXXXX
#   pnpm release [X.Y.Z] [yes|check]
#
# Version: the argument, else the one release-notes/vX.Y.Z.md newer than the
# last release, else asked. `yes` publishes; without it the release stays a
# draft (invisible to the in-app update check) — install from the DMG, dictate
# once, then `gh release edit vX.Y.Z --draft=false`. `check` runs every check
# below and stops before building.
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "release: $*" >&2; exit 1; }

VERSION="" MODE=draft
for arg in "$@"; do
  case "$arg" in
    yes) MODE=publish ;;
    check) MODE=check ;;
    v[0-9]* | [0-9]*) VERSION=${arg#v} ;;
    *) die "unknown argument '$arg' — usage: pnpm release [X.Y.Z] [yes|check]" ;;
  esac
done

valid() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
newer() { # $1 > $2, both X.Y.Z
  local IFS=. i; local a=($1) b=($2)
  for i in 0 1 2; do
    ((10#${a[i]} > 10#${b[i]})) && return 0
    ((10#${a[i]} < 10#${b[i]})) && return 1
  done
  return 1
}

# MARK: - Repo

[ "$(git branch --show-current)" = main ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes (a new notes file must be committed too)"
gh auth status >/dev/null 2>&1 || die "gh isn't logged in — gh auth login"
# No --tags: a stale local tag would make the fetch fail; tags are compared below.
git fetch -q origin main || die "can't fetch origin/main"
read -r BEHIND AHEAD < <(git rev-list --left-right --count origin/main...HEAD)
[ "$BEHIND" -eq 0 ] || die "main is behind or diverged from origin/main — pull first"
HEAD_SHA=$(git rev-parse HEAD)

# The last release is the newest *published* GitHub release — not the newest
# tag, which can be a failed run's leftover (unpushed, or with only a draft).
PUBLISHED=$(gh release list --exclude-drafts --limit 1000 --json tagName -q '.[].tagName') \
  || die "can't list GitHub releases"
BASE=""
for t in $PUBLISHED; do
  v=${t#v}
  valid "$v" || continue
  [ -z "$BASE" ] || newer "$v" "$BASE" && BASE=$v
done

# MARK: - Version

if [ -z "$VERSION" ]; then
  CANDIDATES=()
  for f in release-notes/v*.md; do
    [ -e "$f" ] || continue
    v=$(basename "$f" .md); v=${v#v}
    valid "$v" || continue
    [ -z "$BASE" ] || newer "$v" "$BASE" || continue
    CANDIDATES+=("$v")
  done
  if [ ${#CANDIDATES[@]} -eq 1 ]; then
    VERSION=${CANDIDATES[0]}
  else
    [ -t 0 ] || die "can't tell which version to release — pass it: pnpm release X.Y.Z"
    if [ ${#CANDIDATES[@]} -eq 0 ]; then
      echo "No unreleased release-notes/vX.Y.Z.md newer than v${BASE:-0.0.0}."
    else
      echo "Several unreleased notes files: ${CANDIDATES[*]}"
    fi
    read -rp "Version to release (X.Y.Z): " VERSION
    VERSION=${VERSION#v}
  fi
fi
valid "$VERSION" || die "'$VERSION' isn't X.Y.Z"
[ -z "$BASE" ] || newer "$VERSION" "$BASE" || die "v$VERSION isn't newer than the last release, v$BASE"
TAG=v$VERSION
NOTES=release-notes/$TAG.md
[ -f "$NOTES" ] || die "write $NOTES first (it becomes the release body), commit it, and re-run"
grep -q '[^[:space:]]' "$NOTES" || die "$NOTES is empty"

# MARK: - Existing tag

LOCAL_TAG=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
REMOTE_TAG=$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | awk '{print $1}' | tail -1)
# A tag elsewhere is a failed earlier run of this (unpublished) version.
if [ -n "$REMOTE_TAG" ] && [ "$REMOTE_TAG" != "$HEAD_SHA" ]; then
  die "origin's $TAG is on ${REMOTE_TAG:0:7}, not HEAD — if that run's draft is unwanted: \`gh release delete $TAG --cleanup-tag && git tag -d $TAG\`, then re-run"
fi
if [ -n "$LOCAL_TAG" ] && [ "$LOCAL_TAG" != "$HEAD_SHA" ]; then
  die "$TAG is on ${LOCAL_TAG:0:7} locally and was never pushed — \`git tag -d $TAG\` and re-run"
fi

# MARK: - Credentials

for var in APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID; do
  [ -n "${!var:-}" ] || die "export $var first"
done
# The certificate's hash, not its name: codesign rejects a name two certs share
# (an expired one and its renewal).
IDENTITY=$(security find-identity -v -p codesigning \
  | sed -n "s/.*) \([0-9A-F]\{40\}\) \"Developer ID Application: .*($APPLE_TEAM_ID)\".*/\1/p" | head -1)
[ -n "$IDENTITY" ] || die "no valid Developer ID Application certificate for team $APPLE_TEAM_ID in the keychain"
export PARLA_SIGN_IDENTITY=${PARLA_SIGN_IDENTITY:-$IDENTITY}
xcrun notarytool history --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" >/dev/null 2>&1 \
  || die "Apple rejected the notary credentials — APPLE_APP_PASSWORD must be an app-specific password (account.apple.com)"

# MARK: - Existing release

if out=$(gh release view "$TAG" --json isDraft -q .isDraft 2>&1); then
  [ "$out" = true ] || die "$TAG is already published"
  RELEASE=draft
elif [[ "$out" == *"release not found"* ]]; then
  RELEASE=none
else
  die "gh: $out"
fi

echo "release: $TAG from ${HEAD_SHA:0:7} (last release: v${BASE:-none}), notes: $NOTES, existing release: $RELEASE, mode: $MODE"
[ "$MODE" != check ] || { echo "release: every check passed; nothing built or pushed."; exit 0; }

# MARK: - Build, push, publish

[ -n "$LOCAL_TAG" ] || git tag "$TAG"
scripts/make-dmg.sh
DMG=Parla-$VERSION.dmg
[ "$AHEAD" -eq 0 ] || git push origin main
[ -n "$REMOTE_TAG" ] || git push origin "$TAG"

BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
cat "$NOTES" > "$BODY"
[ -z "$BASE" ] || printf '\n\n**Full Changelog**: %s/compare/v%s...%s\n' \
  "$(gh repo view --json url -q .url)" "$BASE" "$TAG" >> "$BODY"

if [ "$RELEASE" = draft ]; then
  gh release edit "$TAG" --title "$TAG" --notes-file "$BODY"
  gh release upload "$TAG" "$DMG" --clobber
  [ "$MODE" != publish ] || gh release edit "$TAG" --draft=false
else
  DRAFT=(--draft); [ "$MODE" != publish ] || DRAFT=()
  gh release create "$TAG" "$DMG" --title "$TAG" --notes-file "$BODY" --verify-tag ${DRAFT[@]+"${DRAFT[@]}"}
fi

if [ "$MODE" = publish ]; then
  echo "Published $TAG."
else
  echo "Draft $TAG ready. Test the DMG, then: gh release edit $TAG --draft=false"
fi
