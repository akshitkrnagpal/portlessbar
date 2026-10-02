#!/bin/bash
set -euo pipefail
REPOSITORY="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPOSITORY"
# Provision npm when needed, then install a portable runtime for the test VM.
if ! command -v node >/dev/null || [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 24 ]]; then
    brew install node@24
    export PATH="$(brew --prefix node@24)/bin:$PATH"
fi
npm install --prefix .cloud --no-audit --no-fund --save-exact \
    "node@$(cat ci_scripts/node-version)" "portless@$(cat ci_scripts/portless-version)"
NODE_EXECUTABLE="$REPOSITORY/.cloud/node_modules/node/bin/node"
mkdir -p .cloud/TestTools
cp "$NODE_EXECUTABLE" .cloud/TestTools/node
ditto .cloud/node_modules/portless .cloud/TestTools/portless
# Xcode Cloud transfers the test bundle to a separate VM, not the source checkout.
# TestTools is a test-only resource folder and never goes into the app bundle.
PORTLESS_TEST_CLI="$REPOSITORY/.cloud/node_modules/portless/dist/cli.js" \
PORTLESS_TEST_NODE="$NODE_EXECUTABLE" swift test
