#!/bin/bash
# Rebuilds AppIcon_1024.png and AppIcon.icns from make_icon.swift.
set -euo pipefail

ICON_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$(dirname "$ICON_DIR")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc "$ICON_DIR/make_icon.swift" -o "$WORK/make_icon"
"$WORK/make_icon" "$OUT_DIR/AppIcon_1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$OUT_DIR/AppIcon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$OUT_DIR/AppIcon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
echo "✅ $OUT_DIR/AppIcon.icns"
