#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${PORTLESSBAR_VERSION:-$(cat VERSION)}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Version must be major.minor.patch.\n' >&2
    exit 1
fi
BUILD_ARGS=(-c release --scratch-path "${PORTLESSBAR_BUILD_DIR:-.build}")
case "${PORTLESSBAR_ARCH:-native}" in
    universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    arm64|x86_64) BUILD_ARGS+=(--arch "$PORTLESSBAR_ARCH") ;;
    native) ;;
    *) printf 'PORTLESSBAR_ARCH must be native, arm64, x86_64, or universal.\n' >&2; exit 1 ;;
esac
if [[ -n "${PORTLESSBAR_BUILD_SYSTEM:-}" ]]; then BUILD_ARGS+=(--build-system "$PORTLESSBAR_BUILD_SYSTEM"); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
DIST_DIR="${PORTLESSBAR_DIST_DIR:-dist}"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
# Stage outside synced folders: File Provider can attach Finder metadata during signing.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/PortlessBar-build.XXXXXX")"
trap 'rm -r "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/PortlessBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PortlessBar" "$APP/Contents/MacOS/PortlessBar"
if [[ -f Assets/AppIcon.png ]]; then
    ./scripts/build-icon.sh Assets/AppIcon.png "$APP/Contents/Resources/AppIcon.icns"
    cp Assets/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
fi
cp Assets/LinkIcons/*.pdf "$APP/Contents/Resources/"
cp LICENSE NOTICE "$APP/Contents/Resources/"
cp Assets/LinkIcons/README.md "$APP/Contents/Resources/LinkIcons-Attribution.md"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PortlessBar</string>
<key>CFBundleIdentifier</key><string>io.akshit.PortlessBar</string>
<key>CFBundleName</key><string>PortlessBar</string>
<key>CFBundleDisplayName</key><string>PortlessBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Akshit Kr Nagpal.</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# File Provider can attach Finder metadata to generated bundles in Documents.
xattr -cr "$APP"
SIGN_ARGS=(--force --options runtime --sign "${PORTLESSBAR_SIGN_IDENTITY:--}")
if [[ "${PORTLESSBAR_SIGN_IDENTITY:--}" == "-" ]]; then SIGN_ARGS+=(--timestamp=none); else SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
ditto --norsrc "$APP" "$DIST_DIR/PortlessBar.app"
ditto -c -k --norsrc --keepParent "$APP" "$DIST_DIR/PortlessBar-build.zip"
printf 'Built %s\n' "$DIST_DIR/PortlessBar.app"
