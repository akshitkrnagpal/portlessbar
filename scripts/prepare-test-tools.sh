#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v npm >/dev/null; then
    printf 'Install Node.js and npm first, then run this script again. No system packages are installed automatically.\n' >&2
    exit 1
fi
npm install --prefix .cloud --no-audit --no-fund --save-exact \
    "node@$(cat ci_scripts/node-version)" "portless@$(cat ci_scripts/portless-version)"
mkdir -p .cloud/TestTools
cp .cloud/node_modules/node/bin/node .cloud/TestTools/node
ditto .cloud/node_modules/portless .cloud/TestTools/portless
printf 'Prepared isolated live test tools. Run tests in Xcode or with swift test.\n'
