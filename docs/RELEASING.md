# Releasing PortlessBar

Use this runbook for every stable release. `VERSION` supplies both bundle versions; tags use `vMAJOR.MINOR.PATCH`. Keep published stable assets immutable. A corrected binary needs a new version.

## Saved signing setup

The 0.2.0 release established the following setup on the maintainer's Mac:

| Item | Value |
| --- | --- |
| Developer team | AKN Technologies FZ-LLC, `7D6HNDPR5T` |
| Identity | `Developer ID Application: AKN Technologies FZ-LLC (7D6HNDPR5T)` |
| Certificate ID / expiry | `75DUCSHYL2` / September 17, 2031 |
| Dedicated keychain | `~/.portlessbar-signing/portlessbar-release.keychain-db` |
| Machine-specific instructions | `~/.portlessbar-signing/README.md` |
| Sparkle key account / service | `io.akshit.PortlessBar` / `https://sparkle-project.org` in the login Keychain |
| Public update key | `SUPublicEDKey` in `Config/Info.plist` |

The private instructions name the encrypted identity and Sparkle key backups, password file and saved `asc` API profile. Keep backups outside the repository and back up the encrypted identity and its password separately. The dedicated signing keychain is locked after releases; its creation did not change the user's keychain search list.

Reuse these credentials. Apple Development and Apple Distribution certificates cannot replace Developer ID Application for this download. A certificate downloaded from Apple is insufficient without its matching private key. Restore the encrypted identity backup on a new machine before considering a replacement. Creating a Developer ID certificate requires the Account Holder role; see [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

No `notarytool` profile was created for 0.2.0. That release used the saved `asc` App Store Connect API profile. An `asc` profile name and a `notarytool` Keychain profile name are separate settings. Do not assume one exists because the other does.

Never commit private keys, passwords, exported Apple sessions or authentication codes. Do not print secrets or pass them through commands whose exception output includes their arguments.

## Signing recovery for 0.3.2

The documented dedicated keychain and backup directory were unavailable on the release machine. The accessible Developer ID Application identity is `Developer ID Application: Akshit Kumar Nagpal (7D6HNDPR5T)` in the login Keychain. It preserves the downloaded 0.3.1 app’s exact designated requirement on both architectures. No certificate or private key was created.

The existing `io.akshit.PortlessBar` Sparkle account contains the original key with public value `ZkB2c8BZ1vTG7oUMK5wXfYZKT7sMQnhBgJVCywh1nB4=`. The 0.3.1 private key could not be found in the main checkout, other worktrees, documented backup location or login Keychain. Version 0.3.2 returns to the accessible key through the documented rotation path below. `Config/Info.plist` supplies the current public key; never assume the historical table identifies an accessible backup.

Notarization uses the saved `asc` profile `App Store Connect CLI`. macOS may require local Keychain authorization for `asc` and Sparkle’s signing tool. Approve those prompts locally; do not enter passwords in chat or logs. The signing identity and API credentials remain in the login Keychain. Do not lock the user’s login Keychain as if it were the absent dedicated release keychain.

## Prepare and test

1. Review each feature PR and test its exact head before merging. Keep the review evidence and commit SHA.
2. Increase `VERSION`, run `./scripts/generate-xcode-project.sh`, and update `docs/RELEASE_NOTES.md`.
3. If artwork changes, update `scripts/render-logo.swift` and run `./scripts/render-logo.sh`.
4. Prepare the pinned integration tools and run both test suites:

```sh
./scripts/prepare-test-tools.sh
PORTLESS_TEST_NODE="$PWD/.cloud/TestTools/node" \
PORTLESS_TEST_CLI="$PWD/.cloud/TestTools/portless/dist/cli.js" swift test
xcodebuild -project PortlessBar.xcodeproj -scheme PortlessBar \
  -destination 'platform=macOS' test
./scripts/check-xcode-project.sh
```

Confirm the live tests ran rather than skipped. Check the actual menu, proxy start/stop, LAN on/off, service-managed restart, Launch at Login, Settings and link destinations. Record any manual checks that were not performed. Tests that capture authorization commands do not prove a real privileged restart succeeded.

Xcode Cloud provides additional build and macOS test evidence, but does not publish GitHub releases. Check the tested commit, not just a green email. See [Xcode Cloud](XCODE_CLOUD.md).

## Build, notarize and finalize the archive

Unlock the dedicated keychain through its interactive prompt. Do not put the password in shell history:

```sh
security unlock-keychain "$HOME/.portlessbar-signing/portlessbar-release.keychain-db"
export PORTLESSBAR_SIGN_IDENTITY='Developer ID Application: AKN Technologies FZ-LLC (7D6HNDPR5T)'
export PORTLESSBAR_SIGN_KEYCHAIN="$HOME/.portlessbar-signing/portlessbar-release.keychain-db"
export PORTLESSBAR_ARCH=universal
```

Use one of these notarization paths.

### Saved asc API profile, used for 0.2.0

Check `asc auth doctor` and select the saved profile named in the private instructions. The examples use a placeholder for that name. These commands were checked with `asc` 5.2.1; check `--help` if upgrading the CLI.

```sh
./scripts/package-release.sh
asc --profile '<saved-profile>' notarization submit \
  --file dist/PortlessBar-build.zip --output json > dist/notarization.json
```

Save `data.id` from the response. Check that submission rather than uploading again when it is still in progress:

```sh
asc --profile '<saved-profile>' notarization status --id '<submission-id>' --output json
```

Continue only after `data.attributes.status` is `Accepted`. For `Invalid` or `Rejected`, inspect Apple's log and fix the build before submitting again. Do not claim notarization based on code signing alone.

```sh
asc notarization staple --file dist/PortlessBar.app --confirm
xcrun stapler validate dist/PortlessBar.app
spctl --assess --type execute --verbose=2 dist/PortlessBar.app
# Staple the app first, then recreate the distribution ZIP and checksum.
rm -f "dist/PortlessBar-$(cat VERSION)-universal.zip"
ditto -c -k --norsrc --keepParent dist/PortlessBar.app \
  "dist/PortlessBar-$(cat VERSION)-universal.zip"
(cd dist && shasum -a 256 "PortlessBar-$(cat ../VERSION)-universal.zip" > SHA256SUMS.txt)
```

The first archive produced without `PORTLESSBAR_NOTARY_PROFILE` is signed but unstapled. Replace it locally with the finalized archive above before generating update metadata or uploading assets.

### Existing notarytool Keychain profile

To set up this alternative, use `xcrun notarytool store-credentials` and its secure interactive prompt. Then:

```sh
PORTLESSBAR_NOTARY_PROFILE='<notarytool-profile>' ./scripts/package-release.sh
```

The script signs with hardened runtime and a timestamp, submits to Apple, waits, staples, validates, checks Gatekeeper, and creates the final ZIP and checksum. See [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

The default build without a Developer ID identity uses ad hoc signing and is only for local testing. `PORTLESSBAR_BUILD_DIR` and `PORTLESSBAR_DIST_DIR` can move artifacts outside the checkout. For extended-attribute build failures, use a fresh checkout outside a synchronized folder. `PORTLESSBAR_BUILD_SYSTEM` can select another build system supported by the Swift toolchain.

## Sign and verify the update feed

Reuse the Sparkle key. Inspect its public value without exporting the private key:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.akshit.PortlessBar -p
```

It must match `SUPublicEDKey` in `Config/Info.plist` and in the final app. Generate the feed only from the final stapled ZIP:

```sh
./scripts/generate-appcast.sh "dist/PortlessBar-$(cat VERSION)-universal.zip"
python3 scripts/verify-release.py
```

The generator validates the ZIP, signs it with Sparkle's official tool, then runs the verifier before replacing `appcast.xml`. The verifier checks the version, URL, archive length, SHA-256 checksum, embedded public key, EdDSA signature, both CPU architectures, code signature, stapled ticket and Gatekeeper acceptance. Signature verification uses the public key and does not request Keychain access.

If `generate_appcast` waits for Keychain access, approve its access locally when macOS prompts. Do not regenerate the key. If interactive access is unavailable, use `generate_keys -x` to export the existing key into a temporary file inside a private directory with `umask 077`, then set `PORTLESSBAR_SPARKLE_KEY_FILE` to that file for the generation command. Delete the export immediately afterward, including on failures. The script never exports keys itself. Use an encrypted, separately stored backup for transferring the key to another Mac.

### Only when a signing key must change

Read [Sparkle's key rotation rules](https://sparkle-project.org/documentation/#rotating-signing-keys) before changing either trust mechanism. Preserve compatibility with the previous app's Apple code-signing requirement or retain the existing EdDSA key across the update. Enabling `SUVerifyUpdateBeforeExtraction` or `SURequireSignedFeed` changes the recovery rules and needs a separate migration review.

In 0.2.0, the unavailable EdDSA key was replaced while the new AKN certificate preserved the published 0.1.0 app's designated Apple signing requirement. Both architectures passed that requirement. A shared team ID alone is insufficient evidence; test the actual requirement from the previous published app:

```sh
# Extract only the text after "designated =>" from this output.
codesign -d -r- /path/to/previous/PortlessBar.app
# Use that exact requirement after the equals sign, not the new app's requirement.
codesign --verify --strict --all-architectures \
  -R '=<previous designated requirement>' dist/PortlessBar.app
```

Also verify the finalized ZIP's EdDSA signature against the new app's embedded key. Test an update from the previous stable app, including installation and relaunch, before treating a key migration as fully exercised.

## Publish in this order

1. Commit the final source, version and release notes. Merge the preparation PR. Point the draft at the exact resulting main commit; confirm the built source matches it.
2. Create or update the draft, then upload the finalized ZIP, checksum, license and notice:

```sh
gh release create "v$(cat VERSION)" --draft --target '<final-main-commit>' \
  --title "PortlessBar $(cat VERSION)" --notes-file docs/RELEASE_NOTES.md
gh release upload "v$(cat VERSION)" "dist/PortlessBar-$(cat VERSION)-universal.zip" \
  dist/SHA256SUMS.txt dist/LICENSE dist/NOTICE
```

3. Download the draft assets into a fresh directory with `gh release download` and run `shasum -a 256 -c SHA256SUMS.txt` there. Check notes against the actual assets. If the draft already exists, edit it rather than creating another release. Do not replace an existing stable release's assets.
4. Publish the release with `gh release edit "v$(cat VERSION)" --draft=false --latest`. Confirm it is stable, its tag points to the intended commit, and its ZIP downloads without authentication.
5. Commit and merge `appcast.xml` after the matching archive is public. Do not make the feed point at a draft release.
6. Verify the live feed and download:

```sh
python3 scripts/verify-release.py --published
```

7. Update `Casks/portlessbar.rb` in [akshitkrnagpal/homebrew-tap](https://github.com/akshitkrnagpal/homebrew-tap) with the version and finalized ZIP checksum. Run `ruby -c Casks/portlessbar.rb` and `brew style Casks/portlessbar.rb`, verify its download and merge it.
8. Check for updates from the previous stable app, install and relaunch. Confirm the new version and menu controls. Lock the dedicated signing keychain when done.

```sh
security lock-keychain "$HOME/.portlessbar-signing/portlessbar-release.keychain-db"
```

Keep release evidence: reviewed/tested SHA, test results and skips, signing identity, notarization submission/status, finalized ZIP checksum, public verification result, feed commit, cask commit, and actual update-test result. If distribution verification fails, stop announcing the update and repair or revert the feed while preparing a new version. Published assets remain immutable.

## If the updater says the old version is current

Check the exact URL in the installed app's `SUFeedURL`. During 0.2.0 publication, GitHub's raw-file CDN served the old 0.1.0 feed until its roughly five-minute cache refreshed. The repository API already showed 0.2.0. Query strings and a no-cache request did not force a refresh.

```sh
curl --fail --silent --show-error --dump-header /tmp/portlessbar-feed-headers.txt \
  https://raw.githubusercontent.com/akshitkrnagpal/portlessbar/main/appcast.xml
```

Inspect the feed version and `source-age`, `x-cache` and `cache-control` headers. Wait for propagation and rerun `verify-release.py --published` against the unchanged feed URL. A successful merge, a green Cloud build, or a commit-specific raw URL does not establish that the app's live feed has refreshed. Announce automatic-update availability only after live verification passes, then repeat Check for Updates in the app. If the public feed is current but the app is still stale, inspect the running app's bundle version, feed URL and Sparkle logs before changing updater settings.

The first private beta had no updater and needs one manual replacement with the current download. Homebrew users can also run `brew upgrade --cask --greedy akshitkrnagpal/tap/portlessbar`. The feed and cask use public HTTPS downloads; never embed GitHub tokens.
