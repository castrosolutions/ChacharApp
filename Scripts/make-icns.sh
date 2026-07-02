#!/usr/bin/env bash
# Build an AppIcon.icns (all required sizes) from a square master PNG, using only the macOS
# built-ins sips + iconutil. Usage: make-icns.sh [masterPNG] [out.icns]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/Assets/AppIcon.png}"
OUT="${2:-$ROOT/.build/AppIcon.icns}"

TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"

gen() { sips -z "$1" "$1" "$SRC" --out "$TMP/icon_$2.png" >/dev/null; }
gen 16   16x16
gen 32   16x16@2x
gen 32   32x32
gen 64   32x32@2x
gen 128  128x128
gen 256  128x128@2x
gen 256  256x256
gen 512  256x256@2x
gen 512  512x512
gen 1024 512x512@2x

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$TMP" -o "$OUT"
echo "Wrote $OUT"
