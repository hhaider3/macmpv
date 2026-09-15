#!/bin/zsh
# Build the stable mpv library with the upstream fix for mpv#18274.
# Requires the existing Homebrew mpv dependencies, plus meson and ninja.
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
WORK_DIR="$PROJECT_DIR/.build/patched-mpv"
SOURCE_DIR="$WORK_DIR/source"
BUILD_DIR="$WORK_DIR/build"
ARCHIVE="$WORK_DIR/mpv-0.41.0.tar.gz"
PATCH_FILE="$SCRIPT_DIR/patches/mpv-coreaudio-init-cleanup.patch"
MESON=${MESON:-meson}

command -v "$MESON" >/dev/null || { echo "Install meson and ninja (brew install meson ninja)." >&2; exit 1; }
mkdir -p "$WORK_DIR"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 2 \
        https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz \
        -o "$ARCHIVE.partial"
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
echo "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209  $ARCHIVE" | shasum -a 256 -c -

patch_digest=$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')
if [[ ! -d "$SOURCE_DIR" ]]; then
    staging=$(mktemp -d "$WORK_DIR/source.XXXXXX")
    tar -xzf "$ARCHIVE" --strip-components=1 -C "$staging"
    patch -d "$staging" -p1 < "$PATCH_FILE"
    echo "$patch_digest" > "$staging/.macmpv-patch"
    mv "$staging" "$SOURCE_DIR"
elif [[ ! -f "$SOURCE_DIR/.macmpv-patch" || "$(<"$SOURCE_DIR/.macmpv-patch")" != "$patch_digest" ]]; then
    echo "Cached mpv source has a different patch. Move $SOURCE_DIR and $BUILD_DIR aside before rebuilding." >&2
    exit 1
fi

# Keep the selected compiler and SDK together, including after a macOS upgrade.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=26.0
brew_prefix=$(brew --prefix)
export PKG_CONFIG_PATH="$brew_prefix/opt/libarchive/lib/pkgconfig:$brew_prefix/opt/jpeg-turbo/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
setup_args=()
[[ ! -f "$BUILD_DIR/build.ninja" ]] || setup_args+=(--reconfigure)
"$MESON" setup "${setup_args[@]}" "$BUILD_DIR" "$SOURCE_DIR" \
    --buildtype=release -Dlibmpv=true -Dcplayer=false -Dtests=true \
    -Dbuild-date=false -Dmanpage-build=disabled -Dhtml-build=disabled \
    -Dvapoursynth=disabled -Dlua=luajit
"$MESON" compile -C "$BUILD_DIR" -j 4
echo "$BUILD_DIR/libmpv.2.dylib"
