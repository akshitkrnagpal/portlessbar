#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# macOS CoreText exports Menlo glyph outlines to SVG and PNG; no external tools needed.
swift scripts/render-logo.swift
./scripts/build-icon.sh Assets/AppIcon.png Assets/AppIcon.icns
