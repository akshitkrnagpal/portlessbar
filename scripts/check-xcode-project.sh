#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/generate-xcode-project.sh
git diff --exit-code -- PortlessBar.xcodeproj/project.pbxproj \
    PortlessBar.xcodeproj/xcshareddata/xcschemes/PortlessBar.xcscheme
