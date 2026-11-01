#!/usr/bin/env bash
# Copy Homebrew libmpv, ffmpeg, and their non-system dylibs into the app bundle.
set -euo pipefail

APP="${1:?app bundle path}"
FW="$APP/Contents/Frameworks"
HELPERS="$APP/Contents/Helpers"
BIN="$APP/Contents/MacOS/Glossa Player"
rm -rf "$FW"
mkdir -p "$FW" "$HELPERS"

resolve() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
}

collect() {
  local bin="$1"
  otool -L "$bin" | awk 'NR>1 {print $1}'
}

bundle_one() {
  local src="$1"
  src="$(resolve "$src")"
  local base
  base="$(basename "$src")"
  local dest="$FW/$base"
  if [[ -f "$dest" ]]; then
    return
  fi
  cp -L "$src" "$dest"
  chmod u+w "$dest"
  install_name_tool -id "@rpath/$base" "$dest"
  local dep
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/opt/*|/usr/local/lib/*)
        bundle_one "$dep"
        install_name_tool -change "$dep" "@rpath/$(basename "$(resolve "$dep")")" "$dest" || true
        ;;
    esac
  done < <(collect "$dest")
}

rewrite_deps() {
  local bin="$1"
  local dep
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/opt/*|/usr/local/lib/*)
        bundle_one "$dep"
        install_name_tool -change "$dep" "@rpath/$(basename "$(resolve "$dep")")" "$bin" || return 1
        ;;
    esac
  done < <(collect "$bin")
}

FFMPEG="$(command -v ffmpeg || true)"
if [[ -z "$FFMPEG" ]]; then
  echo "ffmpeg not on PATH" >&2
  exit 1
fi
cp -L "$(resolve "$FFMPEG")" "$HELPERS/ffmpeg"
chmod 755 "$HELPERS/ffmpeg"
rewrite_deps "$HELPERS/ffmpeg"
# Debug builds put libmpv on Glossa Player.debug.dylib. The stub executable may
# have no header pad; rewriting it is optional.
if [[ -f "$BIN.debug.dylib" ]]; then
  rewrite_deps "$BIN.debug.dylib"
fi
rewrite_deps "$BIN" || true

add_rpath() {
  local bin="$1"
  local rpath="$2"
  if ! otool -l "$bin" | grep -q "$rpath"; then
    install_name_tool -add_rpath "$rpath" "$bin" || true
  fi
}
add_rpath "$BIN" "@executable_path/../Frameworks"
if [[ -f "$BIN.debug.dylib" ]]; then
  add_rpath "$BIN.debug.dylib" "@loader_path/../Frameworks"
fi
add_rpath "$HELPERS/ffmpeg" "@executable_path/../Frameworks"
add_rpath "$HELPERS/glossa-engine" "@executable_path/../Frameworks"

echo "bundled $(find "$FW" -type f | wc -l | tr -d ' ') libraries"
