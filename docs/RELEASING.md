# Releasing PortlessBar

The version in `VERSION` is the single source of truth. Release tags use `vMAJOR.MINOR.PATCH`, for example `v0.2.0`. Repository visibility is managed separately from releases. The finalized first release is 0.1.0; subsequent releases must use a higher version.

## Prepare

1. Set the release number in `VERSION`, regenerate the Xcode project with `./scripts/generate-xcode-project.sh`, and update `docs/RELEASE_NOTES.md`.
2. If artwork changes, update `scripts/render-logo.swift` and run `./scripts/render-logo.sh` to regenerate the icon and README wordmark.
3. Run the complete test suite and check the actual UI, including proxy start/stop, Launch at Login, and link destinations.
4. Build and verify the universal binary and its signature.

```sh
PORTLESSBAR_ARCH=universal ./scripts/package-release.sh
lipo dist/PortlessBar.app/Contents/MacOS/PortlessBar -verify_arch arm64
lipo dist/PortlessBar.app/Contents/MacOS/PortlessBar -verify_arch x86_64
codesign --verify --strict dist/PortlessBar.app
```

The default build has a local ad hoc signature. It is useful for local testing but is not a notarized distribution build. Xcode Cloud runs tests and produces archives after account setup; it does not publish GitHub releases. See [Xcode Cloud](XCODE_CLOUD.md).

## Developer ID signing and notarization

Use an installed Developer ID Application certificate. Save Apple notarization credentials with `xcrun notarytool store-credentials` using its secure interactive prompt. Do not put certificate private keys, passwords, or API keys in the repository.

```sh
PORTLESSBAR_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
PORTLESSBAR_NOTARY_PROFILE='your-keychain-profile' \
./scripts/package-release.sh
```

The script enables hardened runtime, adds a secure signature timestamp, submits to Apple's notary service, waits for the result, staples the ticket, verifies it, and creates the final archive and checksum. It fails if notarization or verification fails. See [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

`PORTLESSBAR_BUILD_DIR` and `PORTLESSBAR_DIST_DIR` can move build artifacts outside the source tree. For build-system signing problems caused by extended attributes, try a fresh checkout outside a synchronized folder. `PORTLESSBAR_BUILD_SYSTEM` can select an alternate build system supported by your Swift toolchain.

Set `PORTLESSBAR_SIGN_KEYCHAIN` to use a dedicated signing keychain without changing the user's keychain search list. Unlock that keychain before building.

## Draft and publish

After tests and a signed/notarized build pass, commit and push the final files. Create a draft referencing that exact commit:

```sh
gh release create "v$(cat VERSION)" --draft --target "$(git rev-parse HEAD)" \
  --title "PortlessBar $(cat VERSION)" --notes-file docs/RELEASE_NOTES.md
gh release upload "v$(cat VERSION)" "dist/PortlessBar-$(cat VERSION)-universal.zip" dist/SHA256SUMS.txt
```

Review the release notes and checksums against the actual uploaded archive. Publishing a release does not change repository visibility.

For an intentionally non-notarized distribution, explicitly state that fact in its release notes and include the first-launch instructions from the README. Never claim notarization from a successful signature check alone.

## Distribution and updates

Downloads are universal ZIP archives with a SHA-256 checksum. Sparkle checks the HTTPS `appcast.xml` in this repository. Generate update metadata only from the final notarized archive, after stapling:

```sh
./scripts/generate-appcast.sh dist/PortlessBar-$(cat VERSION)-universal.zip
```

The Ed25519 private key is stored in the local Keychain under the account `io.akshit.PortlessBar`. Its public key is in `Config/Info.plist`. The generation script checks the version, signature, stapled ticket and Gatekeeper acceptance, then uses Sparkle's official tool to sign the archive and generate the feed. It never exports the private key.

Upload the matching ZIP and checksum first; then commit and publish `appcast.xml`. Verify the feed's URL, archive length, EdDSA signature and downloaded SHA-256 before announcing an update. Future releases must increase `CFBundleVersion` through `VERSION` for Sparkle to recognize an update. The finalized first release remains 0.1.0; do not replace a published stable version's assets during subsequent releases.

The first private beta had no updater and needs one manual replacement with the finalized download. The new build enables automatic checks and presents an installation prompt. Manual downloads remain available if updates fail.

The cask lives in [akshitkrnagpal/homebrew-tap](https://github.com/akshitkrnagpal/homebrew-tap), at `Casks/portlessbar.rb`. Update its version and SHA-256 for each stable universal ZIP, test its download, and publish it after the release. It declares `auto_updates true` because the app updates itself through Sparkle. Homebrew users can also run `brew upgrade --cask --greedy akshitkrnagpal/tap/portlessbar`.

The feed and cask need public HTTPS downloads; do not embed GitHub tokens in either.
