# Xcode Cloud

The repository includes a native macOS Xcode project and the shared **PortlessBar** scheme. GitHub Actions is not used. Apple account authorization and the first remote build remain account-side setup steps.

## Connect your account

1. Open `PortlessBar.xcodeproj` in Xcode. Select **PortlessBar** and your **Akshit Kumar Nagpal** team (`7D6HNDPR5T`) under Signing & Capabilities.
2. Open **Report navigator → Cloud → Get Started**. Choose the **PortlessBar** app product and shared scheme.
3. Authorize access to the new private `akshitkrnagpal/portlessbar` repository. If Apple requests an App Store Connect app record, create a macOS record for `io.akshit.PortlessBar` with SKU `portlessbar`. This does not publish the app.
4. Start with Apple's suggested workflow on `main`, using an available released Xcode version with Swift 6 or newer. Keep **Archive**, add **Test** for the shared scheme, and trigger builds for `main` changes and pull requests targeting it.
5. Start the first build and inspect the logs. Account roles, agreements, signing assets and repository access can only be confirmed after authorization.

Apple requires initial setup in Xcode; subsequent workflow management is available in Xcode or App Store Connect. See [Apple's setup guide](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow).

## Checks and dependencies

`ci_scripts/ci_post_clone.sh` installs the Portless version pinned in `ci_scripts/portless-version`, provisions Node.js 24 if a supported runtime is missing, and runs the complete Swift Package Manager test suite. A failed check stops the action. The Xcode Test action also runs the same tests, using those isolated CLI dependencies.

Tests choose available ports and temporary state; they do not change the user's Portless registry. Generated dependencies live in ignored `.cloud/`. The native scheme can build and archive both Intel and Apple Silicon. The local setup hook, native Xcode tests and universal archive have been verified; a remote Xcode Cloud run still needs your authorization.

Run the setup hook locally before testing through Xcode:

```sh
./ci_scripts/ci_post_clone.sh
```

Cloud archives are build artifacts. They do not automatically become notarized GitHub downloads. Keep Developer ID release signing and notarization in the [local release process](RELEASING.md). Do not upload your personal notarization password or certificate private key to this repository.

For project changes, regenerate the checked-in Xcode files using `./scripts/generate-xcode-project.sh`; Xcode Cloud itself does not require XcodeGen.
