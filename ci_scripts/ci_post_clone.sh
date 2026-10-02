#!/bin/bash
set -euo pipefail
REPOSITORY="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPOSITORY"
# Use an installed supported Node runtime, or provision it on Xcode Cloud.
if ! command -v node >/dev/null || [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 20 ]]; then
    brew install node@24
    export PATH="$(brew --prefix node@24)/bin:$PATH"
fi
NODE_EXECUTABLE="$(node -p 'process.execPath')"
mkdir -p .cloud/bin
ln -sf "$NODE_EXECUTABLE" .cloud/bin/node
npm install --prefix .cloud --no-audit --no-fund --save-exact "portless@$(cat ci_scripts/portless-version)"
PORTLESS_TEST_CLI="$REPOSITORY/.cloud/node_modules/portless/dist/cli.js" \
PORTLESS_TEST_NODE="$NODE_EXECUTABLE" swift test
