#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null; then
    printf 'Install XcodeGen with: brew install xcodegen\n' >&2
    exit 1
fi
export PORTLESSBAR_VERSION="$(cat VERSION)"
xcodegen generate --spec project.yml
