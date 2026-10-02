#!/bin/bash
set -euo pipefail
SOURCE="${1:?Usage: build-icon.sh source.png output.icns}"
DESTINATION="${2:?Usage: build-icon.sh source.png output.icns}"
ICON_PARENT="$(dirname "$DESTINATION")"
mkdir -p "$ICON_PARENT"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/PortlessBar-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir "$ICONSET"
WIDTH="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')"
HEIGHT="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')"
if [[ "$WIDTH" != "$HEIGHT" || "$WIDTH" -lt 1024 ]]; then
    printf 'App icon must be square and at least 1024 pixels wide.\n' >&2
    exit 1
fi
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DESTINATION"
