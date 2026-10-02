# Xcode Cloud

The repository includes a native macOS Xcode project and the shared **PortlessBar** scheme. GitHub Actions is not used. Xcode Cloud is connected to the private repository under **AKN Technologies FZ-LLC**.

The **Default** workflow builds for Any Mac and runs the native Xcode tests. It starts on changes to `main` and pull requests targeting `main`, and cancels superseded builds. It uses the latest released Xcode and macOS with clean builds. Manage it in [App Store Connect](https://appstoreconnect.apple.com/teams/93400368-2cbe-4945-9c62-4ef33f377c75/xcode-cloud/products/200431e3-9ea1-45fa-b290-a6f7eb12b5e2/workflows).

## Connect your account

1. Open `PortlessBar.xcodeproj` in Xcode and select **PortlessBar**. The checked-in personal signing team (`7D6HNDPR5T`) is used for local Developer ID releases; the Cloud product belongs to **AKN Technologies FZ-LLC**.
2. Open **Report navigator → Cloud → Get Started**. Choose the **PortlessBar** app product and shared scheme.
3. Connect the private `akshitkrnagpal/portlessbar` repository under the company team. The current product uses Xcode Cloud's build-and-test setup and does not need an App Store app record.
4. Configure **Build** for Any Mac and **Test** for the shared scheme, and trigger builds for `main` changes and pull requests targeting it. Archive and distribution are separate, optional actions.
5. Start the first build and inspect the logs. Account roles, agreements, signing assets and repository access can only be confirmed after authorization.

Apple requires initial setup in Xcode; subsequent workflow management is available in Xcode or App Store Connect. See [Apple's setup guide](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow).

## Checks and dependencies

`ci_scripts/ci_post_clone.sh` installs the Portless and portable Node.js versions pinned in `ci_scripts/portless-version` and `ci_scripts/node-version`, and runs the complete Swift Package Manager test suite. A failed check stops the action. It also prepares a test-only resource folder containing the runtime and CLI. Xcode copies that folder into the test bundle so the same tests can run in Cloud's separate test VM without depending on paths in the build checkout. These tools are never included in the app bundle.

Tests choose available ports and temporary state; they do not change the user's Portless registry. Generated dependencies live in ignored `.cloud/`. The native scheme can build and archive both Intel and Apple Silicon. The first remote Cloud build passed with zero warnings or errors, including all 23 tests in the setup hook with no skips. The local native Xcode tests and universal archive have also been verified.

Run the setup hook locally before testing through Xcode:

```sh
./ci_scripts/ci_post_clone.sh
```

Cloud archives are build artifacts. They do not automatically become notarized GitHub downloads. Keep Developer ID release signing and notarization in the [local release process](RELEASING.md). Do not upload your personal notarization password or certificate private key to this repository.

For project changes, regenerate the checked-in Xcode files using `./scripts/generate-xcode-project.sh`; Xcode Cloud itself does not require XcodeGen.
