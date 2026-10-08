#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
ARCHIVE="${1:-dist/PortlessBar-${VERSION}-universal.zip}"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
TOOLS="${PORTLESSBAR_BUILD_DIR:-.build}/artifacts/sparkle/Sparkle/bin"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/PortlessBar-appcast.XXXXXX")"
trap 'rm -r "$STAGING"' EXIT
mkdir "$STAGING/verify" "$STAGING/updates"
ditto -x -k "$ARCHIVE" "$STAGING/verify"
APP="$STAGING/verify/PortlessBar.app"
test "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" = "$VERSION"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"
cp "$ARCHIVE" "$STAGING/updates/"
KEY_ARGS=(--account io.akshit.PortlessBar)
if [[ -n "${PORTLESSBAR_SPARKLE_KEY_FILE:-}" ]]; then
    KEY_ARGS=(--ed-key-file "$PORTLESSBAR_SPARKLE_KEY_FILE")
fi
"$TOOLS/generate_appcast" "${KEY_ARGS[@]}" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/akshitkrnagpal/portlessbar/releases/download/v${VERSION}/" \
    --full-release-notes-url "https://github.com/akshitkrnagpal/portlessbar/releases/tag/v${VERSION}" \
    "$STAGING/updates"
python3 scripts/verify-release.py --archive "$ARCHIVE" --feed "$STAGING/updates/appcast.xml"
cp "$STAGING/updates/appcast.xml" appcast.xml
printf 'Generated signed update metadata in appcast.xml. Publish the matching archive before the feed.\n'
