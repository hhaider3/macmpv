#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${1:-release}
APP_DIR="$PROJECT_DIR/dist/macmpv.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$PROJECT_DIR"
swift build -c "$CONFIGURATION"
BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)

mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/macmpv" "$MACOS_DIR/macmpv"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/macmpv"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
