#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${1:-release}
APP_DIR="$PROJECT_DIR/dist/macmpv.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$PROJECT_DIR"
# Retry with --disable-sandbox only for the sandbox denial described in the
# README's Troubleshooting section; a real compile error must fail here, with
# its output shown once, instead of being re-run and duplicated.
BUILD_LOG=$(mktemp "${TMPDIR:-/tmp}macmpv-build.XXXXXX")
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build -c "$CONFIGURATION" 2>&1 | tee "$BUILD_LOG"; then
  if grep -q "sandbox_apply: Operation not permitted" "$BUILD_LOG"; then
    echo "==> sandbox denial detected; retrying once with --disable-sandbox" >&2
    swift build -c "$CONFIGURATION" --disable-sandbox
  else
    echo "error: ${CONFIGURATION} build failed" >&2
    exit 1
  fi
fi
BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path 2>/dev/null || swift build -c "$CONFIGURATION" --disable-sandbox --show-bin-path)

mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/macmpv" "$MACOS_DIR/macmpv"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/macmpv"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
