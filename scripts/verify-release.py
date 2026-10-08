#!/usr/bin/env python3
"""Verify local release assets, or the public feed and its download, on macOS."""

import argparse
import hashlib
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
RELEASE_URL = "https://github.com/akshitkrnagpal/portlessbar/releases/download"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or result.stdout.strip()
            or f"{arguments[0]} failed with exit status {result.returncode}.")
    return result.stdout


def download(url, destination):
    run("curl", "--fail", "--location", "--silent", "--show-error",
        "--max-time", "30", url, "--output", str(destination))


def verify(options, staging):
    version = (ROOT / "VERSION").read_text().strip()
    config = plistlib.loads((ROOT / "Config/Info.plist").read_bytes())
    name = f"PortlessBar-{version}-universal.zip"
    url = f"{RELEASE_URL}/v{version}/{name}"
    feed = options.feed
    archive = options.archive or ROOT / "dist" / name
    checksums = archive.parent / "SHA256SUMS.txt"
    if options.published:
        require(options.feed is None and options.archive is None,
                "--published uses the configured live feed and public assets; omit local paths.")
        feed = staging / "appcast.xml"
        archive = staging / name
        checksums = staging / "SHA256SUMS.txt"
        download(config["SUFeedURL"], feed)

    items = ET.parse(feed or ROOT / "appcast.xml").findall("./channel/item")
    item = next((entry for entry in items if entry.findtext(SPARKLE + "version") == version), None)
    visible = ", ".join(entry.findtext(SPARKLE + "version", "unknown") for entry in items)
    require(item is not None,
            f"Feed does not advertise {version}; it contains {visible or 'no releases'}. "
            "For the live feed, wait for GitHub's cache to refresh and retry the same URL.")
    enclosure = item.find("enclosure")
    require(enclosure is not None, "Missing update enclosure.")
    require(enclosure.get("url") == url, "Feed download URL does not match this release.")
    require(item.findtext(SPARKLE + "shortVersionString") == version, "Feed display version mismatch.")
    if options.published:
        download(url, archive)
        download(f"{RELEASE_URL}/v{version}/SHA256SUMS.txt", checksums)

    require(archive.name == name, "Expected the universal archive for VERSION.")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    rows = [line.split(maxsplit=1) for line in checksums.read_text().splitlines()]
    expected = next((row[0] for row in rows if len(row) == 2 and row[1].lstrip("*") == name), None)
    require(digest == expected, "Archive SHA-256 does not match SHA256SUMS.txt.")
    require(enclosure.get("length") == str(archive.stat().st_size), "Feed archive length mismatch.")

    unpacked = staging / "unpacked"
    run("ditto", "-x", "-k", str(archive), str(unpacked))
    app = unpacked / "PortlessBar.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        require(info.get(key) == version, f"Bundle {key} does not match VERSION.")
    for key in ("CFBundleIdentifier", "SUPublicEDKey", "SUFeedURL", "LSMinimumSystemVersion"):
        require(info.get(key) == config.get(key), f"Bundle {key} does not match Config/Info.plist.")
    require(item.findtext(SPARKLE + "minimumSystemVersion") == info["LSMinimumSystemVersion"],
            "Feed minimum macOS version mismatch.")

    # CryptoKit verifies with the bundle's public key, without requesting a private key.
    verifier = staging / "verify-signature.swift"
    verifier.write_text('''import Foundation
import CryptoKit
let args = CommandLine.arguments
guard let keyData = Data(base64Encoded: args[2]),
      let signature = Data(base64Encoded: args[3]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[1]))
guard key.isValidSignature(signature, for: archive) else { exit(1) }
''')
    signature = enclosure.get(SPARKLE + "edSignature")
    require(signature is not None, "Missing Sparkle EdDSA signature.")
    run("swift", str(verifier), str(archive), info["SUPublicEDKey"], signature)
    for architecture in ("arm64", "x86_64"):
        run("lipo", str(app / "Contents/MacOS/PortlessBar"), "-verify_arch", architecture)
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))
    run("xcrun", "stapler", "validate", str(app))
    run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    print(f"Verified {'public' if options.published else 'local'} {version}: feed, checksum, "
          "EdDSA signature, universal binary, code signature, stapled ticket and Gatekeeper.")
    print(f"SHA-256: {digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--published", action="store_true", help="Verify anonymous HTTPS downloads from the live feed.")
    parser.add_argument("--archive", type=Path, help="Local archive; default is dist/PortlessBar-VERSION-universal.zip.")
    parser.add_argument("--feed", type=Path, help="Local feed; default is appcast.xml.")
    options = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="PortlessBar-release-check.") as directory:
            verify(options, Path(directory))
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"Release verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
