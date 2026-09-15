#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
library=${1:-"$PROJECT_DIR/.build/patched-mpv/build/libmpv.2.dylib"}
library=${library:A}
[[ -f "$library" ]] || { echo "Build the patched library first: zsh Scripts/build-libmpv.sh" >&2; exit 1; }
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/macmpv-audio-regression.XXXXXX")
trap 'rm -f "$test_dir/runner" "$test_dir/interpose.dylib"; rmdir "$test_dir"' EXIT
brew_prefix=$(brew --prefix)
xcrun clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -I"$brew_prefix/include" -framework CoreAudio -framework AudioToolbox \
    -dynamiclib -DMACMPV_AUDIO_INTERPOSE "$PROJECT_DIR/Tests/CoreAudioInitializationRegression.c" \
    -o "$test_dir/interpose.dylib"
xcrun clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -I"$brew_prefix/include" -framework CoreAudio -framework AudioToolbox \
    -Wl,-headerpad_max_install_names -Wl,-rpath,"${library:h}" "$PROJECT_DIR/Tests/CoreAudioInitializationRegression.c" \
    "$library" "$test_dir/interpose.dylib" -o "$test_dir/runner"
# Force this exact library, rather than its original Homebrew/install location.
install_name=$(otool -D "$library" | tail -1)
install_name_tool -change "$install_name" "$library" "$test_dir/runner"
codesign --force --sign - "$test_dir/runner"
DYLD_INSERT_LIBRARIES="$test_dir/interpose.dylib" "$test_dir/runner"
