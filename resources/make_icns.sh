#!/bin/sh
# Build a macOS .icns from a square PNG (1024x1024 recommended). Needs Xcode command line tools.
# Usage: sh resources/make_icns.sh resources/AppIcon.png MacInfo.app/Contents/Resources/AppIcon.icns
set -eu

SRC=${1:?usage: make_icns.sh <source.png> <output.icns>}
OUT=${2:?usage: make_icns.sh <source.png> <output.icns>}

TMP=$(mktemp -d)
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

render() {
    sips -z "$1" "$1" "$SRC" --out "$2" >/dev/null
}

render 16   "$ICONSET/icon_16x16.png"
render 32   "$ICONSET/icon_16x16@2x.png"
render 32   "$ICONSET/icon_32x32.png"
render 64   "$ICONSET/icon_32x32@2x.png"
render 128  "$ICONSET/icon_128x128.png"
render 256  "$ICONSET/icon_128x128@2x.png"
render 256  "$ICONSET/icon_256x256.png"
render 512  "$ICONSET/icon_256x256@2x.png"
render 512  "$ICONSET/icon_512x512.png"
render 1024 "$ICONSET/icon_512x512@2x.png"

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$TMP"

echo "wrote $OUT"
