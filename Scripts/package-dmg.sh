#!/bin/zsh
# Assembles a distributable disk image: bundles the Homebrew libmpv dependency
# closure (plus ffprobe) into the app, rewrites load commands to @rpath,
# re-signs, and packs dist/macmpv-<version>-<arch>.dmg.
#
# Optional: MACMPV_SIGN_IDENTITY="Developer ID Application: ..." for real
# signing (adds hardened runtime + secure timestamp); defaults to ad-hoc "-".
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/macmpv.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SIGN_IDENTITY=${MACMPV_SIGN_IDENTITY:--}

echo "==> Building release app"
# Start from a clean bundle so stale helpers and dylibs never accumulate.
rm -rf "$APP_DIR"
zsh "$SCRIPT_DIR/build-app.sh" release

brew_root() {
  [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* ]]
}

refs_of() {
  otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

# ---- Collect the Homebrew dylib closure of the executable and ffprobe ----
FFPROBE_SOURCE=$(command -v ffprobe || true)
if [[ -z "$FFPROBE_SOURCE" ]]; then
  echo "error: ffprobe not found on PATH (brew install ffmpeg)" >&2
  exit 1
fi

# closure: every distinct Homebrew ref string to rewrite. by_name: referenced
# basename -> real path of the file to bundle. Homebrew references dylibs via
# versioned symlink aliases (libavdevice.62.dylib -> libavdevice.62.3.102.dylib
# in the Cellar), so bundle under the referenced name and dedupe traversal by
# real path — the same file reached via /opt/homebrew/opt and /opt/homebrew/lib
# is still one bundle entry.
typeset -A closure visited by_name
to_visit=("$MACOS_DIR/macmpv" "$FFPROBE_SOURCE")
while (( ${#to_visit[@]} > 0 )); do
  current=${to_visit[1]}
  to_visit=(${to_visit:1})
  for dep in $(refs_of "$current"); do
    if ! brew_root "$dep"; then continue; fi
    closure[$dep]=1
    name=${dep:t}
    real=$(realpath "$dep")
    if [[ -n "${by_name[$name]:-}" && "${by_name[$name]}" != "$real" ]]; then
      echo "error: two different libraries share the name $name" >&2
      exit 1
    fi
    by_name[$name]=$real
    if [[ -z "${visited[$real]:-}" ]]; then
      visited[$real]=1
      to_visit+=("$real")
    fi
  done
done

if (( ${#by_name[@]} == 0 )); then
  echo "error: no Homebrew libraries found to bundle" >&2
  exit 1
fi
echo "==> Bundling ${#by_name[@]} dylibs"

rm -rf "$FRAMEWORKS_DIR"
mkdir -p "$FRAMEWORKS_DIR"

for name in "${(k)by_name[@]}"; do
  cp "${by_name[$name]}" "$FRAMEWORKS_DIR/$name"
done

# Homebrew's ffprobe is read-only (555); copy fresh and force a writable mode.
rm -f "$MACOS_DIR/ffprobe"
cp "$FFPROBE_SOURCE" "$MACOS_DIR/ffprobe"
chmod 755 "$MACOS_DIR/ffprobe"

# ---- Rewrite load commands to @rpath ----
rewrite_refs() {
  local target=$1 old name
  for old in "${(k)closure[@]}"; do
    name=${old:t}
    if refs_of "$target" | grep -Fxq "$old"; then
      install_name_tool -change "$old" "@rpath/$name" "$target"
    fi
  done
}

add_rpath() {
  local target=$1 rpath=$2
  if ! otool -l "$target" | grep -q "path $rpath"; then
    install_name_tool -add_rpath "$rpath" "$target"
  fi
}

for f in "$FRAMEWORKS_DIR"/*.dylib; do
  install_name_tool -id "@rpath/${f:t}" "$f"
  rewrite_refs "$f"
done

rewrite_refs "$MACOS_DIR/macmpv"
rewrite_refs "$MACOS_DIR/ffprobe"
add_rpath "$MACOS_DIR/macmpv" "@executable_path/../Frameworks"
add_rpath "$MACOS_DIR/ffprobe" "@executable_path/../Frameworks"

# ---- Sign ----
echo "==> Code signing (${SIGN_IDENTITY})"
sign_flags=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  sign_flags+=(--options runtime --timestamp)
fi
for f in "$FRAMEWORKS_DIR"/*.dylib "$MACOS_DIR/ffprobe"; do
  codesign "${sign_flags[@]}" "$f"
done
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# ---- Verify no absolute Homebrew references remain ----
for f in "$MACOS_DIR/macmpv" "$MACOS_DIR/ffprobe" "$FRAMEWORKS_DIR"/*.dylib; do
  if refs_of "$f" | grep -Eq '^/opt/homebrew|^/usr/local'; then
    echo "error: $f still references Homebrew libraries" >&2
    exit 1
  fi
done
# Smoke test: exercises the bundled dylibs through dyld, same as playback will.
"$MACOS_DIR/ffprobe" -version >/dev/null

# ---- Create the dmg ----
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS_DIR/Info.plist")
ARCH=$(uname -m)
DMG="$PROJECT_DIR/dist/macmpv-${VERSION}-${ARCH}.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}macmpv-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_DIR" "$STAGING/macmpv.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
echo "==> Creating $DMG"
hdiutil create -volname "macmpv" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
