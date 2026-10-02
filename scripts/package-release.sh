#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f Assets/AppIcon.png ]]; then
    printf 'Missing Assets/AppIcon.png. Restore the asset or run scripts/render-logo.sh.\n' >&2
    exit 1
fi
export PORTLESSBAR_ARCH="${PORTLESSBAR_ARCH:-universal}"
./scripts/build-app.sh
DIST_DIR="${PORTLESSBAR_DIST_DIR:-dist}"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
APP="$DIST_DIR/PortlessBar.app"
VERSION="${PORTLESSBAR_VERSION:-$(cat VERSION)}"
ARCHIVE="$DIST_DIR/PortlessBar-${VERSION}-${PORTLESSBAR_ARCH}.zip"
if [[ -n "${PORTLESSBAR_NOTARY_PROFILE:-}" ]]; then
    if [[ "${PORTLESSBAR_SIGN_IDENTITY:--}" == "-" ]]; then
        printf 'Notarization requires PORTLESSBAR_SIGN_IDENTITY to name a Developer ID Application certificate.\n' >&2
        exit 1
    fi
    xcrun notarytool submit "$DIST_DIR/PortlessBar-build.zip" \
        --keychain-profile "$PORTLESSBAR_NOTARY_PROFILE" --wait
    STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/PortlessBar-notarize.XXXXXX")"
    trap 'rm -r "$STAGING_DIR"' EXIT
    ditto -x -k "$DIST_DIR/PortlessBar-build.zip" "$STAGING_DIR"
    APP="$STAGING_DIR/PortlessBar.app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose "$APP"
    ditto --norsrc "$APP" "$DIST_DIR/PortlessBar.app"
    ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
else
    cp "$DIST_DIR/PortlessBar-build.zip" "$ARCHIVE"
fi
cp LICENSE "$DIST_DIR/LICENSE"
cp NOTICE "$DIST_DIR/NOTICE"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt)
printf 'Release archive: %s\n' "$ARCHIVE"
