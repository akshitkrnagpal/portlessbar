# PortlessBar 0.1.0

A minimal native macOS menu bar companion for Portless.

- Toggle the proxy with one switch, leaving development servers running.
- Open registered server URLs with one click.
- A single Settings page with Launch at Login, GitHub, X and Email.
- Monospace `portlessbar` identity and square `p_` app icon.
- Configuration recovery, tolerant route parsing, and clear errors.

Requires macOS 14 or newer, the Portless CLI and its supported Node.js runtime. Tested with Portless 0.8.0 and 0.15.6.

The universal ZIP supports Apple Silicon and Intel. It is signed with Developer ID Application, notarized by Apple, and includes a stapled ticket. Gatekeeper assessment passed. Verify the download against `SHA256SUMS.txt`.

Move `PortlessBar.app` to `/Applications` before enabling Launch at Login. Updates use manual replacement. There are no automatic update checks.

Licensed under Apache 2.0. PortlessBar is independent and is not affiliated with Vercel.

Made with ❤️ by [akshit.io](https://akshit.io).
