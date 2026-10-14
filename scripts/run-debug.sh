#!/bin/bash
# Run from Terminal so macOS can allow LAN access for this unsigned debug app.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project PortlessBar.xcodeproj -scheme PortlessBar -configuration Debug \
    -derivedDataPath .build/preview CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

preview_app="$PWD/.build/PortlessBar Preview.app"
ditto .build/preview/Build/Products/Debug/PortlessBar.app "$preview_app"
plutil -replace CFBundleIdentifier -string io.akshit.PortlessBar.preview "$preview_app/Contents/Info.plist"
plutil -replace CFBundleName -string 'PortlessBar Preview' "$preview_app/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'PortlessBar Preview' "$preview_app/Contents/Info.plist"
plutil -insert PortlessBarPreview -bool YES "$preview_app/Contents/Info.plist"
plutil -remove SUFeedURL "$preview_app/Contents/Info.plist"
exec "$preview_app/Contents/MacOS/PortlessBar" --background
