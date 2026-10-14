#!/bin/sh
# Renders loupe.svg to the app target's Loupe.icns and the review previews.
# Needs rsvg-convert (brew install librsvg); iconutil ships with macOS.
set -eu

cd "$(dirname "$0")"
rsvg=${RSVG_CONVERT:-rsvg-convert}

iconset=$(mktemp -d "${TMPDIR:-/tmp}/loupe-icon.XXXXXX")/Loupe.iconset
mkdir -p "$iconset"
trap 'rm -rf "$(dirname "$iconset")"' EXIT

for size in 16 32 128 256 512; do
  "$rsvg" -w "$size" -h "$size" loupe.svg -o "$iconset/icon_${size}x${size}.png"
  double=$((size * 2))
  "$rsvg" -w "$double" -h "$double" loupe.svg -o "$iconset/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$iconset" -o ../Sources/Loupe/Resources/Loupe.icns
"$rsvg" -w 512 -h 512 loupe.svg -o preview-512.png
"$rsvg" -w 16 -h 16 loupe.svg -o preview-16.png
