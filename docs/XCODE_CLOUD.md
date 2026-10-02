# Xcode Cloud

PortlessBar uses Xcode Cloud for macOS build and test checks. GitHub Actions is not used.

## Workflow

The maintainer workflow builds for Any Mac and runs the native Xcode tests on changes to `main`. It uses a released Xcode version with Swift 6 or newer and clean builds. Automatic pull-request triggers are disabled. Review contributions before merging into `main` or manually starting a branch build, especially scripts from forks. Builds cancel when superseded.

Account authorization, workflow permissions and signing belong to the maintainer's Apple Developer team. Contributors do not need Cloud access or that team's signing credentials. See [Apple's setup guide](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow) when configuring another repository.

## Checks and dependencies

`ci_scripts/ci_post_clone.sh` provisions Cloud's dependencies, verifies that the checked-in Xcode project matches `project.yml`, and runs the complete Swift Package Manager test suite. A failed check stops the action.

The hook installs portable Node.js and Portless versions pinned in `ci_scripts/node-version` and `ci_scripts/portless-version`. Xcode copies the resulting `.cloud/TestTools` folder into the test bundle so live tests work in Apple's separate test VM. These dependencies never go into the app bundle. Tests use available ports and temporary state, leaving the user's Portless registry and development servers alone.

For local development, use the lighter optional setup in [Contributing](../CONTRIBUTING.md). Running the Cloud hook locally is not required.

Cloud checks do not publish GitHub releases. Developer ID signing, notarization and signed update feeds follow the [release process](RELEASING.md). Do not store certificate private keys, notarization passwords or Sparkle private keys in the repository.
