#!/bin/zsh
# Assembles a distributable disk image: bundles the Homebrew libmpv dependency
# closure (plus ffprobe) into the app, rewrites load commands to @rpath,
# re-signs, and packs dist/macmpv-<version>-<arch>.dmg.
#
# Optional argument "torrents" builds the "+ Torrents" variant, which also
# bundles a node runtime and WebTorrent CLI so torrent playback works with
# nothing installed. Default (no argument) builds the standard dmg.
#
# Optional: MACMPV_SIGN_IDENTITY="Developer ID Application: ..." for real
# signing (adds hardened runtime + secure timestamp); defaults to ad-hoc "-".
set -euo pipefail

MODE=${1:-standard}

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

refs_of() {
  otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

brew_root() {
  [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* ]]
}

# closure: every distinct dependency ref string to rewrite. by_name: referenced
# basename -> real path of the file to bundle. Homebrew references dylibs via
# versioned symlink aliases (libavdevice.62.dylib -> libavdevice.62.3.102.dylib
# in the Cellar), so bundle under the referenced name and dedupe traversal by
# real path. Sibling-relative refs (@loader_path/@rpath, e.g. icu4c's
# libicudata) resolve against the referencing file's directory.
typeset -A closure visited by_name
to_visit=()

walk_deps() {
  local current=$1 dep resolved name real
  for dep in $(refs_of "$current"); do
    case "$dep" in
      @loader_path/*|@rpath/*)
        resolved="${current:h}/${dep#*/}"
        ;;
      *)
        resolved=$dep
        ;;
    esac
    if ! brew_root "$resolved" || [[ ! -f "$resolved" ]]; then
      continue
    fi
    closure[$dep]=1
    name=${dep:t}
    real=$(realpath "$resolved")
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
}

# ---- Collect the Homebrew dylib closure of the executable and ffprobe ----
FFPROBE_SOURCE=$(command -v ffprobe || true)
if [[ -z "$FFPROBE_SOURCE" ]]; then
  echo "error: ffprobe not found on PATH (brew install ffmpeg)" >&2
  exit 1
fi

to_visit=("$MACOS_DIR/macmpv" "$FFPROBE_SOURCE")
while (( ${#to_visit[@]} > 0 )); do
  current=${to_visit[1]}
  to_visit=(${to_visit:1})
  walk_deps "$current"
done

# The "+ Torrents" variant also bundles node + WebTorrent CLI. The node
# launcher already references libnode via @rpath, so libnode joins the closure
# like any other dylib and lands in Frameworks.
WEBTORRENT_CLI_DIR=""
if [[ "$MODE" == "torrents" ]]; then
  NODE_BIN=$(realpath "$(command -v node)" || true)
  [[ -n "${NODE_BIN:-}" ]] || { echo "error: node not found on PATH" >&2; exit 1; }
  LIBNODE=$(ls "${NODE_BIN:h}/../lib"/libnode.*.dylib 2>/dev/null | head -1)
  [[ -n "$LIBNODE" ]] || { echo "error: libnode not found next to $NODE_BIN" >&2; exit 1; }
  WEBTORRENT_CLI_DIR=$(realpath "$(dirname "$(command -v webtorrent)")/../lib/node_modules/webtorrent-cli" 2>/dev/null || true)
  [[ -n "$WEBTORRENT_CLI_DIR" && -f "$WEBTORRENT_CLI_DIR/bin/cmd.js" ]] || {
    echo "error: webtorrent-cli not found (npm install -g webtorrent-cli)" >&2
    exit 1
  }

  closure[$LIBNODE]=1
  by_name[${LIBNODE:t}]=$(realpath "$LIBNODE")
  to_visit+=("$(realpath "$LIBNODE")")
  while (( ${#to_visit[@]} > 0 )); do
    current=${to_visit[1]}
    to_visit=(${to_visit:1})
    walk_deps "$current"
  done
fi

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

HELPERS_DIR="$CONTENTS_DIR/Helpers"
WEBTORRENT_RESOURCES_DIR=""
if [[ "$MODE" == "torrents" ]]; then
  echo "==> Bundling WebTorrent runtime"
  # The node launcher is code and lives in Helpers; the npm tree lives in
  # Resources, where codesign seals it as data instead of scanning it — its
  # bundle detection misreads dotted directory names like ipaddr.js.
  mkdir -p "$HELPERS_DIR"
  cp "$NODE_BIN" "$HELPERS_DIR/webtorrent-node"
  chmod 755 "$HELPERS_DIR/webtorrent-node"
  # The launcher loads libnode via @rpath, same as the app's own dylibs.
  add_rpath "$HELPERS_DIR/webtorrent-node" "@executable_path/../Frameworks"

  WEBTORRENT_RESOURCES_DIR="$CONTENTS_DIR/Resources/webtorrent-cli"
  rm -rf "$WEBTORRENT_RESOURCES_DIR"
  mkdir -p "$CONTENTS_DIR/Resources"
  cp -R "$WEBTORRENT_CLI_DIR" "$WEBTORRENT_RESOURCES_DIR"

  # Prune what can never run on this build: foreign-platform native prebuilds,
  # docs, source maps, type definitions, repo/editor/npm droppings. LICENSE
  # files are kept. Types-only dirs also trip codesign's bundle detection.
  find "$WEBTORRENT_RESOURCES_DIR" \( \
    -path "*prebuilds*" -name "*.node" ! -path "*darwin-arm64*" \) -delete
  find "$WEBTORRENT_RESOURCES_DIR" -type d \( \
    -name "@types" -o -name ".github" -o -name ".bin" \) -prune -exec rm -rf {} + 2>/dev/null || true
  find "$WEBTORRENT_RESOURCES_DIR" -name ".*" ! -name "." ! -name ".." \
    -prune -exec rm -rf {} + 2>/dev/null || true
  find "$WEBTORRENT_RESOURCES_DIR" \( \
    -name "*.md" -o -name "*.markdown" -o -name "*.map" \
    -o -name "*.d.ts" -o -name "*.d.mts" -o -name "*.d.cts" \) -delete 2>/dev/null || true
  find "$WEBTORRENT_RESOURCES_DIR" -type d -empty -delete 2>/dev/null || true
  du -sh "$WEBTORRENT_RESOURCES_DIR"
fi

# ---- Sign ----
echo "==> Code signing (${SIGN_IDENTITY})"
sign_flags=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  sign_flags+=(--options runtime --timestamp)
fi
for f in "$FRAMEWORKS_DIR"/*.dylib "$MACOS_DIR/ffprobe"; do
  codesign "${sign_flags[@]}" "$f"
done
# If the deep sign hits a pseudo-bundle directory it names, delete exactly that
# subcomponent and retry; the smoke tests below are the runtime safety net.
sign_attempts=0
while true; do
  if sign_output=$(codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" 2>&1); then
    break
  fi
  sign_attempts=$((sign_attempts + 1))
  offender=$(printf '%s\n' "$sign_output" | sed -n 's/^In subcomponent: \(.*\)$/\1/p')
  if [[ -z "$offender" || $sign_attempts -gt 25 ]]; then
    echo "$sign_output" >&2
    echo "error: codesign failed and no prunable subcomponent was named" >&2
    exit 1
  fi
  echo "  pruning codesign offender: ${offender#$APP_DIR/}"
  rm -rf "$offender"
done
codesign --verify --deep --strict "$APP_DIR"

# ---- Verify no absolute Homebrew references remain ----
for f in "$MACOS_DIR/macmpv" "$MACOS_DIR/ffprobe" "$FRAMEWORKS_DIR"/*.dylib; do
  if refs_of "$f" | grep -Eq '^/opt/homebrew|^/usr/local|^@loader_path'; then
    echo "error: $f still references non-bundled libraries" >&2
    exit 1
  fi
done
# Smoke tests: exercise the bundled dylibs through dyld, same as playback will.
"$MACOS_DIR/ffprobe" -version >/dev/null
if [[ "$MODE" == "torrents" ]]; then
  "$HELPERS_DIR/webtorrent-node" --version >/dev/null
  "$HELPERS_DIR/webtorrent-node" "$WEBTORRENT_RESOURCES_DIR/bin/cmd.js" --version >/dev/null
fi

# ---- Create the dmg ----
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS_DIR/Info.plist")
ARCH=$(uname -m)
SUFFIX=""
if [[ "$MODE" == "torrents" ]]; then
  SUFFIX="-torrents"
fi
DMG="$PROJECT_DIR/dist/macmpv-${VERSION}-${ARCH}${SUFFIX}.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}macmpv-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_DIR" "$STAGING/macmpv.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
echo "==> Creating $DMG"
hdiutil create -volname "macmpv" -srcfolder "$STAGING" -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
