#!/bin/zsh
# One-command release: builds the dmg (torrent playback included), patches
# site/index.html (download URLs, size, checksum) and both update feeds, and
# publishes the GitHub Release vX.Y with its notes from CHANGELOG.md.
#
# Since 2.0 there is one build. appcast.xml (read by pre-2.0 Standard installs)
# and appcast-torrents.xml (read by every install since) offer the same dmg,
# so Standard installs move onto it.
#
# Usage: Scripts/release.sh [VERSION]
#   VERSION  optional; defaults to Info.plist. When given, the plist is bumped
#            first (CFBundleVersion becomes the current date) and the bump is
#            committed, so the published tag always points at the version built.
# Requires the gh CLI, authenticated. Refuses a dirty working tree unless
# FORCE=1 — the release tags point at HEAD, so HEAD must be what you built.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
PLIST="$PROJECT_DIR/Resources/Info.plist"

die() { echo "error: $*" >&2; exit 1; }

VERSION=${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "invalid version '$VERSION'"

cd "$PROJECT_DIR"
[[ "$(uname -m)" == "arm64" ]] || die "website releases must be built on Apple Silicon"

command -v gh >/dev/null 2>&1 || die "gh CLI required (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

if git ls-remote --tags origin "refs/tags/v$VERSION" | grep -q .; then
  die "tag v$VERSION already exists on origin"
fi

NOTES_FILE=$(mktemp "${TMPDIR:-/tmp}/macmpv-notes.XXXXXX")
trap 'rm -f "$NOTES_FILE"' EXIT
python3 - "$PROJECT_DIR/CHANGELOG.md" "$VERSION" > "$NOTES_FILE" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(rf'^## {re.escape(sys.argv[2])} .*?\n(.*?)(?=^## |\Z)', text, re.S | re.M)
if not match or not match.group(1).strip():
    sys.exit(f'error: CHANGELOG.md has no section for {sys.argv[2]}')
print(match.group(1).strip())
PY

if [[ -z "${FORCE:-}" ]]; then
  [[ -z "$(git status --porcelain)" ]] || {
    git status --short
    die "uncommitted changes present (commit first, or FORCE=1 to ignore)"
  }
fi

if [[ -n "${1:-}" ]]; then
  echo "==> Bumping version to $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  # Sparkle compares CFBundleVersion, so it must grow with every release,
  # including several on one day.
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$PLIST"
  # The release tags HEAD, so the bump must be part of pushed HEAD — commit it
  # now; the explicit source push below makes this commit available to gh.
  # Guarded so a rerun
  # after a mid-script failure skips the no-op empty commit. Site patches stay
  # uncommitted for the manual step.
  git add "$PLIST"
  if ! git diff --cached --quiet; then
    git commit -m "release: bump to $VERSION"
  fi
fi

# Capture and publish the exact source commit before creating either tag.
# gh otherwise defaults to the remote default branch, which can move mid-build.
RELEASE_COMMIT=$(git rev-parse HEAD)
git push origin HEAD

echo "==> Building the dmg"
zsh "$SCRIPT_DIR/package-dmg.sh" torrents

ARCH=$(uname -m)
# package-dmg names the torrent build *-torrents.dmg; it is the only download now.
DMG="dist/macmpv-${VERSION}-${ARCH}.dmg"
mv -f "dist/macmpv-${VERSION}-${ARCH}-torrents.dmg" "$DMG"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
SUMS="dist/SHA256SUMS-${VERSION}.txt"
(cd dist && shasum -a 256 "${DMG:t}") > "$SUMS"
echo "==> $(basename $DMG)  $SHA"

echo "==> Signing the update and writing both update feeds"
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || die "Sparkle's sign_update is missing (swift package resolve)"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "dist/macmpv.app/Contents/Info.plist")
REPO_URL="https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##;s#\.git$##')"
SIGNED=$("$SIGN_UPDATE" --account macmpv "$DMG")
for feed in appcast.xml appcast-torrents.xml; do
  python3 "$SCRIPT_DIR/update-appcast.py" "$PROJECT_DIR/site/$feed" "macmpv" \
    "$VERSION" "$BUILD_NUMBER" "$REPO_URL/releases/download/v$VERSION/${DMG:t}" \
    "$REPO_URL/releases/tag/v$VERSION" "$SIGNED"
done

echo "==> Patching site/index.html"
python3 "$SCRIPT_DIR/update-downloads.py" "$PROJECT_DIR/site/index.html" "$VERSION" "$SHA" "$DMG"
python3 "$SCRIPT_DIR/validate-site.py"

echo "==> Publishing the GitHub release"
gh release create "v$VERSION" "$DMG" "$SUMS" \
  --title "macmpv $VERSION" \
  --target "$RELEASE_COMMIT" \
  --notes-file "$NOTES_FILE"

echo ""
echo "Release published: https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##;s#\.git$##')/releases/tag/v${VERSION}"
echo "Remaining manual steps:"
echo "  1. Review the release notes on GitHub (taken from CHANGELOG.md)"
echo "  2. git add site/ && git commit -m \"site: point downloads at v$VERSION releases\" && git push"
echo "     — the push deploys the updated site via Cloudflare Pages"
