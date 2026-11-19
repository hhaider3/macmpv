#!/bin/zsh
# Reproduce a dylib's build-time rpath shadowing the app's bundled dependency.
set -euo pipefail
SCRIPT_DIR=${0:A:h}
source "$SCRIPT_DIR/bundle-rpaths.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/macmpv-rpaths.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
frameworks="$test_dir/Test.app/Contents/Frameworks"
macos="$test_dir/Test.app/Contents/MacOS"
host_libs="$test_dir/build machine/lib"
mkdir -p "$frameworks" "$macos" "$host_libs"

cat > "$test_dir/leaf.c" <<'EOF'
int leaf_value(void) { return VALUE; }
EOF
cat > "$test_dir/parent.c" <<'EOF'
extern int leaf_value(void);
int parent_value(void) { return leaf_value(); }
EOF
cat > "$test_dir/main.c" <<'EOF'
#include <stdio.h>
extern int parent_value(void);
int main(void) { printf("%d\n", parent_value()); return 0; }
EOF

for location value in "$frameworks" 1 "$host_libs" 2; do
  xcrun clang -dynamiclib -DVALUE="$value" "$test_dir/leaf.c" \
    -Wl,-headerpad_max_install_names -Wl,-install_name,@rpath/libLeaf.dylib \
    -o "$location/libLeaf.dylib"
done
xcrun clang -dynamiclib "$test_dir/parent.c" "$frameworks/libLeaf.dylib" \
  -Wl,-headerpad_max_install_names -Wl,-install_name,@rpath/libParent.dylib \
  -Xlinker -rpath -Xlinker "$host_libs" -Wl,-rpath,/usr/lib/swift \
  -o "$frameworks/libParent.dylib"
xcrun clang "$test_dir/main.c" "$frameworks/libParent.dylib" \
  -Wl,-headerpad_max_install_names -Wl,-rpath,@executable_path/../Frameworks \
  -o "$macos/runner"

[[ "$("$macos/runner")" == 2 ]] || { echo "Failed to reproduce rpath shadowing" >&2; exit 1; }
if verify_bundle_rpaths "$frameworks/libParent.dylib" "@loader_path" 2>/dev/null; then
  echo "Verification accepted an external rpath" >&2
  exit 1
fi
for library in "$frameworks"/*.dylib; do
  relocate_rpaths "$library" "@loader_path"
  relocate_rpaths "$library" "@loader_path" # Repeated packaging is safe.
  verify_bundle_rpaths "$library" "@loader_path"
  codesign --force --sign - "$library"
done
relocate_rpaths "$macos/runner" "@executable_path/../Frameworks"
verify_bundle_rpaths "$macos/runner" "@executable_path/../Frameworks"
codesign --force --sign - "$macos/runner"
[[ "$("$macos/runner")" == 1 ]] || { echo "Loaded the host library after relocation" >&2; exit 1; }
rm -rf "$host_libs"
[[ "$("$macos/runner")" == 1 ]] || { echo "Bundle depends on build-machine libraries" >&2; exit 1; }
echo "Bundle rpath regression passed"
