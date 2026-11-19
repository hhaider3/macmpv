#!/bin/zsh
# Shared by packaging and its regression test. Source this file before use.

rpaths_of() {
  otool -l "$1" | awk '
    /cmd LC_RPATH/ {
      getline; getline
      sub(/^[[:space:]]*path /, "")
      sub(/ \(offset [0-9]+\)$/, "")
      print
    }'
}

relocate_rpaths() {
  local target=$1 bundle_rpath=$2 existing found=0
  local -a changes=()
  while IFS= read -r existing; do
    if [[ "$existing" == "$bundle_rpath" ]]; then
      found=1
    elif [[ "$existing" != /usr/lib/swift ]]; then
      # A dylib's own rpaths take precedence over the executable's. Leaving
      # build-machine paths here can load Homebrew copies instead of the
      # bundled libraries, even when every dependency uses @rpath.
      changes+=(-delete_rpath "$existing")
    fi
  done < <(rpaths_of "$target")
  if (( ! found )); then
    changes+=(-add_rpath "$bundle_rpath")
  fi
  if (( ${#changes[@]} > 0 )); then
    install_name_tool "${changes[@]}" "$target"
  fi
}

verify_bundle_rpaths() {
  local target=$1 bundle_rpath=$2 existing found=0
  while IFS= read -r existing; do
    if [[ "$existing" == "$bundle_rpath" ]]; then
      found=1
    elif [[ "$existing" != /usr/lib/swift ]]; then
      echo "error: $target still has an external rpath: $existing" >&2
      return 1
    fi
  done < <(rpaths_of "$target")
  if (( ! found )); then
    echo "error: $target is missing its bundle rpath: $bundle_rpath" >&2
    return 1
  fi
}
