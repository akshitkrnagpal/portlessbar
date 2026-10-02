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
cp Config/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string PortlessBar "$APP/Contents/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string en "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Frameworks"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE="${PORTLESSBAR_BUILD_DIR:-.build}/artifacts/sparkle/Sparkle"
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$FRAMEWORK"
cp Assets/Sparkle-LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
# SPM's command-line executable also needs the app-bundle framework runpath.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/PortlessBar"
# File Provider can attach Finder metadata to generated bundles in Documents.
xattr -cr "$APP"
SIGN_ARGS=(--force --sign "${PORTLESSBAR_SIGN_IDENTITY:--}")
if [[ "${PORTLESSBAR_SIGN_IDENTITY:--}" == "-" ]]; then SIGN_ARGS+=(--timestamp=none); else SIGN_ARGS+=(--options runtime --timestamp); fi
for nested in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
    codesign "${SIGN_ARGS[@]}" "$nested"
done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
ditto --norsrc "$APP" "$DIST_DIR/PortlessBar.app"
ditto -c -k --norsrc --keepParent "$APP" "$DIST_DIR/PortlessBar-build.zip"
printf 'Built %s\n' "$DIST_DIR/PortlessBar.app"
