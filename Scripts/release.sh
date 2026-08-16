#!/bin/zsh
# One-command release: builds both dmg variants, patches site/index.html
# (download URLs, sizes, checksum), and publishes both GitHub Releases
# (vX.Y standard, vX.Yt torrents).
#
# Usage: Scripts/release.sh [VERSION]
#   VERSION  optional; defaults to Info.plist. When given, the plist is bumped
#            first (CFBundleVersion becomes the current date).
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

command -v gh >/dev/null 2>&1 || die "gh CLI required (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

for tag in "v$VERSION" "v${VERSION}t"; do
  if git ls-remote --tags origin "refs/tags/$tag" | grep -q .; then
    die "tag $tag already exists on origin"
  fi
done

if [[ -z "${FORCE:-}" ]]; then
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || {
    git status --short
    die "uncommitted changes present (commit first, or FORCE=1 to ignore)"
  }
fi

if [[ -n "${1:-}" ]]; then
  echo "==> Bumping version to $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d)" "$PLIST"
fi

echo "==> Building both dmg variants"
zsh "$SCRIPT_DIR/package-dmg.sh"
zsh "$SCRIPT_DIR/package-dmg.sh" torrents

STD_DMG="dist/macmpv-${VERSION}-arm64.dmg"
TOR_DMG="dist/macmpv-${VERSION}-arm64-torrents.dmg"
[[ -f "$STD_DMG" ]] || die "expected $STD_DMG missing"
[[ -f "$TOR_DMG" ]] || die "expected $TOR_DMG missing"

STD_SHA=$(shasum -a 256 "$STD_DMG" | awk '{print $1}')
TOR_SHA=$(shasum -a 256 "$TOR_DMG" | awk '{print $1}')
echo "==> standard: $(basename $STD_DMG)  $STD_SHA"
echo "==> torrents: $(basename $TOR_DMG)  $TOR_SHA"

echo "==> Patching site/index.html"
python3 - "$PROJECT_DIR/site/index.html" "$VERSION" "$STD_SHA" "$STD_DMG" "$TOR_DMG" <<'PY'
import os, re, sys

path, version, std_sha, std_dmg, tor_dmg = sys.argv[1:6]
std_mb = round(os.path.getsize(std_dmg) / 1e6)
tor_mb = round(os.path.getsize(tor_dmg) / 1e6)

html = open(path).read()
html, n_std_url = re.subn(
    r'/releases/download/v[\w.]+/macmpv-[\d.]+-arm64\.dmg',
    f'/releases/download/v{version}/macmpv-{version}-arm64.dmg', html)
html, n_tor_url = re.subn(
    r'/releases/download/v[\w.]+/macmpv-[\d.]+-arm64-torrents\.dmg',
    f'/releases/download/v{version}t/macmpv-{version}-arm64-torrents.dmg', html)
html, n_sha = re.subn(
    r'(SHA-256 \(standard\)</span>\s*<code>)[0-9a-f]{64}',
    r'\g<1>' + std_sha, html)
html = re.sub(r'\b\d+ MB · add torrents later',
              f'{std_mb} MB · add torrents later', html)
html = re.sub(r'\b\d+ MB · WebTorrent bundled',
              f'{tor_mb} MB · WebTorrent bundled', html)
html = re.sub(r'(<span class="button-sub">)\d+ MB(</span>)',
              rf'\g<1>{std_mb} MB\g<2>', html)

for label, count in (('standard url', n_std_url),
                     ('torrents url', n_tor_url),
                     ('checksum', n_sha)):
    if count == 0:
        sys.exit(f'error: no {label} matches in site/index.html — layout changed?')
open(path, 'w').write(html)
PY

echo "==> Publishing GitHub releases (standard first, then torrents)"
gh release create "v$VERSION" "$STD_DMG" \
  --title "macmpv $VERSION" \
  --generate-notes
gh release create "v${VERSION}t" "$TOR_DMG" \
  --title "macmpv ${VERSION}t — Torrents build" \
  --generate-notes

echo ""
echo "Release published: https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]##;s#\.git$##')/releases/tag/v${VERSION}t"
echo "Remaining manual steps:"
echo "  1. Review both release notes on GitHub (--generate-notes drafts from commits)"
echo "  2. git add site/ Resources/Info.plist && git commit -m \"release v$VERSION\" && git push"
echo "     — the push deploys the updated site via Cloudflare Pages"
