#!/usr/bin/env bash
# Render the macOS app icon PNGs from icon-source.svg.
#
# Apple's asset catalog wants 7 distinct PNG sizes (each used at
# two @scale slots). We use rsvg-convert (`brew install librsvg`)
# so the SVG → PNG rasterization is deterministic across machines
# and CI runners.

set -euo pipefail

cd "$(dirname "$0")/.."
SRC="GeoClockWallpaper/Assets.xcassets/AppIcon.appiconset/icon-source.svg"
OUT="GeoClockWallpaper/Assets.xcassets/AppIcon.appiconset"

if ! command -v rsvg-convert >/dev/null; then
  echo "rsvg-convert not found. Run: brew install librsvg" >&2
  exit 1
fi

for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$size" -h "$size" "$SRC" -o "$OUT/icon-${size}.png"
done

echo "Wrote icon-{16,32,64,128,256,512,1024}.png to $OUT"
