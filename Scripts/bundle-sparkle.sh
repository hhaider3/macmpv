#!/bin/zsh
# Copies Sparkle.framework from a SwiftPM build into an app bundle and signs
# its executables inside-out, as Sparkle requires (never with --deep).
#
# Usage: bundle-sparkle.sh <bin-dir> <app-dir> [codesign flags...]
set -euo pipefail

BIN_DIR=$1
APP_DIR=$2
shift 2
SIGN_FLAGS=("$@")
(( ${#SIGN_FLAGS[@]} > 0 )) || SIGN_FLAGS=(--force --sign -)

SOURCE="$BIN_DIR/Sparkle.framework"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
TARGET="$FRAMEWORKS_DIR/Sparkle.framework"
[[ -d "$SOURCE" ]] || { echo "error: $SOURCE not found (swift build first)" >&2; exit 1; }

mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$TARGET"
# ditto keeps the framework's Versions/Current symlinks intact.
ditto "$SOURCE" "$TARGET"
# The XPC services exist for sandboxed apps; macmpv is not sandboxed.
rm -rf "$TARGET/Versions/B/XPCServices" "$TARGET/XPCServices"

EXECUTABLE="$APP_DIR/Contents/MacOS/macmpv"
if ! otool -l "$EXECUTABLE" | grep -q "path @executable_path/../Frameworks "; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
fi

codesign "${SIGN_FLAGS[@]}" "$TARGET/Versions/B/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$TARGET/Versions/B/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$TARGET"
