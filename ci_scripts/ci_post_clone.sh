#!/bin/bash
set -euo pipefail
REPOSITORY="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPOSITORY"
if [[ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
    if ! command -v xcodegen >/dev/null; then brew install xcodegen; fi
    ./scripts/check-xcode-project.sh
fi
# Provision npm when needed, then install a portable runtime for the test VM.
if ! command -v node >/dev/null || [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 24 ]]; then
    brew install node@24
    export PATH="$(brew --prefix node@24)/bin:$PATH"
fi
./scripts/prepare-test-tools.sh
NODE_EXECUTABLE="$REPOSITORY/.cloud/node_modules/node/bin/node"
# Xcode Cloud transfers the test bundle to a separate VM, not the source checkout.
# TestTools is a test-only resource folder and never goes into the app bundle.
PORTLESS_TEST_CLI="$REPOSITORY/.cloud/node_modules/portless/dist/cli.js" \
PORTLESS_TEST_NODE="$NODE_EXECUTABLE" swift test
