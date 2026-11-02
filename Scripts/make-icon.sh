#!/usr/bin/env bash
# Rebuilds Packaging/AppIcon.icns from Packaging/AppIcon.svg. The .icns is committed, so a normal build does not need this.
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
swiftc -O Scripts/render-icon.swift -o "$T/render" 2>/dev/null
SET="$T/AppIcon.iconset"; mkdir -p "$SET"
for size in 16 32 128 256 512; do
  "$T/render" Packaging/AppIcon.svg "$SET/icon_${size}x${size}.png" "$size"
  "$T/render" Packaging/AppIcon.svg "$SET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
"$T/render" Packaging/AppIcon.svg Packaging/AppIcon-site.png 128
iconutil -c icns "$SET" -o Packaging/AppIcon.icns
echo "Wrote Packaging/AppIcon.icns"
