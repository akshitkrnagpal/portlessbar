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

Select the shared **PortlessBar** scheme and run tests. Debug uses **Sign to Run Locally**, so no Apple Developer team is required. A fresh clone runs the core tests and skips the live proxy and Node watchdog tests until their optional tools are prepared.

For the complete native test suite, install Node.js/npm yourself, then run `./scripts/prepare-test-tools.sh` once. It prepares pinned tools inside ignored `.cloud/` without installing system packages or running tests. Xcode copies those tools into the test bundle when present. Swift Package Manager uses the `PORTLESS_TEST_CLI` and `PORTLESS_TEST_NODE` variables shown above.

Xcode Cloud prepares all dependencies, checks that the generated project matches `project.yml`, and runs both test suites. See [setup instructions](docs/XCODE_CLOUD.md). GitHub Actions is not used. Maintainers should merge or manually approve fork contributions before running their scripts with privileged CI credentials.

`Config/Info.plist` contains shared app metadata and updater configuration; `VERSION` supplies the release version. Both packaging paths use these files. Sparkle is pinned in `Package.swift`, `Package.resolved`, and `project.yml`; keep its version consistent when upgrading it.
