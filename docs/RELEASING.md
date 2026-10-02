# Releasing PortlessBar

The version in `VERSION` is the single source of truth. Release tags use `vMAJOR.MINOR.PATCH`, for example `v0.1.0`. Repository visibility is managed separately from releases.

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

Downloads are universal ZIP archives with a SHA-256 checksum. Updates currently use manual replacement; the app makes no background update requests. A Homebrew cask can follow stable notarized downloads. Automatic updates would need signed update metadata, a maintained feed and a recovery path before adding an updater.
