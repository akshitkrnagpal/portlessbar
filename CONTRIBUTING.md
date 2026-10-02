# Contributing

Use macOS 14 or newer and Swift 6 or newer. Open `PortlessBar.xcodeproj` in Xcode or use Swift Package Manager from the command line.

```sh
swift build
swift test
./scripts/build-app.sh
```

For the full integration test, install a supported Node.js runtime and Portless, then run:

```sh
npm install --global portless
PORTLESS_TEST_CLI="$(npm root --global)/portless/dist/cli.js" \
PORTLESS_TEST_NODE="$(command -v node)" swift test
```

Tests create an isolated temporary Portless state directory; they do not change `~/.portless`. Tests choose available ports at runtime. Keep registry access read-only, delegate proxy lifecycle to Portless, and avoid logging process environments or credentials.

Keep pull requests focused. Include the behavior changed and how it was verified. Update the README and release notes for user-facing changes. For UI changes, include screenshots at light and dark appearance when relevant.

Use the issue templates for reproducible bugs and feature proposals. See [release instructions](docs/RELEASING.md) for packaging and signing. Contributions are licensed under Apache 2.0. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Xcode project

The checked-in project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing target files or `VERSION`, regenerate it:

```sh
brew install xcodegen
./scripts/generate-xcode-project.sh
```

To prepare the live test dependencies for Xcode, run `./ci_scripts/ci_post_clone.sh` once. Then select the shared **PortlessBar** scheme and run tests. Xcode Cloud uses the same hook; see [setup instructions](docs/XCODE_CLOUD.md). GitHub Actions is not used.
