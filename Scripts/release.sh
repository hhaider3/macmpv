#!/bin/zsh
# One-command release: builds both dmg variants, patches site/index.html
# (download URLs, sizes, checksum), and publishes both GitHub Releases
# (vX.Y standard, vX.Yt torrents).
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

for tag in "v$VERSION" "v${VERSION}t"; do
  if git ls-remote --tags origin "refs/tags/$tag" | grep -q .; then
    die "tag $tag already exists on origin"
  fi
done

if [[ -z "${FORCE:-}" ]]; then
  [[ -z "$(git status --porcelain)" ]] || {
    git status --short
    die "uncommitted changes present (commit first, or FORCE=1 to ignore)"
  }
fi

if [[ -n "${1:-}" ]]; then
  echo "==> Bumping version to $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d)" "$PLIST"
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

echo "==> Building both dmg variants"
zsh "$SCRIPT_DIR/package-dmg.sh"
zsh "$SCRIPT_DIR/package-dmg.sh" torrents

ARCH=$(uname -m)
STD_DMG="dist/macmpv-${VERSION}-${ARCH}.dmg"
TOR_DMG="dist/macmpv-${VERSION}-${ARCH}-torrents.dmg"
[[ -f "$STD_DMG" ]] || die "expected $STD_DMG missing"
[[ -f "$TOR_DMG" ]] || die "expected $TOR_DMG missing"

STD_SHA=$(shasum -a 256 "$STD_DMG" | awk '{print $1}')
TOR_SHA=$(shasum -a 256 "$TOR_DMG" | awk '{print $1}')
echo "==> standard: $(basename $STD_DMG)  $STD_SHA"
echo "==> torrents: $(basename $TOR_DMG)  $TOR_SHA"

echo "==> Patching site/index.html"
python3 "$SCRIPT_DIR/update-downloads.py" "$PROJECT_DIR/site/index.html" "$VERSION" "$STD_SHA" "$STD_DMG" "$TOR_DMG"
python3 "$SCRIPT_DIR/validate-site.py"

echo "==> Publishing GitHub releases (standard first, then torrents)"
gh release create "v$VERSION" "$STD_DMG" \
  --title "macmpv $VERSION" \
  --target "$RELEASE_COMMIT" \
  --generate-notes
gh release create "v${VERSION}t" "$TOR_DMG" \
  --title "macmpv ${VERSION}t — Torrents build" \
  --target "$RELEASE_COMMIT" \
  --generate-notes

echo ""
echo "Release published: https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##;s#\.git$##')/releases/tag/v${VERSION}t"
echo "Remaining manual steps:"
echo "  1. Review both release notes on GitHub (--generate-notes drafts from commits)"
echo "  2. git add site/ && git commit -m \"site: point downloads at v$VERSION releases\" && git push"
echo "     — the push deploys the updated site via Cloudflare Pages"
