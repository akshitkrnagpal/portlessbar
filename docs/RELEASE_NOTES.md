# Unreleased

- Compact the Settings window with a smaller header and tighter rows, keeping every section visible without scrolling.

# PortlessBar 0.2.0

Switch Portless LAN mode from the menu bar to reach your apps from other devices on your network.

- Change LAN mode with a second switch below the proxy switch. A running proxy restarts in the selected mode.
- Keep the selected mode while disconnected and use it on the next connection.
- Update the Portless startup service when it manages the proxy, preserving its installed runtime and supported options.
- Use one administrator prompt for privileged proxy restarts.
- Show when running apps need a restart to register URLs for the new mode.

Requires macOS 14 or newer, the Portless CLI and its supported Node.js runtime. LAN switching was tested with Portless 0.15.6. Portless 0.8.0 remains supported for proxy controls but does not support LAN mode. Custom TLDs are not restored after turning LAN mode on and then off.

The universal app supports Apple Silicon and Intel. Move `PortlessBar.app` to `/Applications` before enabling Launch at Login.

The download is signed by AKN Technologies FZ-LLC, notarized by Apple, and includes a stapled notarization ticket. Gatekeeper accepts the final archive. SHA256SUMS.txt contains its SHA-256 checksum.

Licensed under Apache 2.0. PortlessBar is independent and is not affiliated with Vercel.

Made with ❤️ by [akshit.io](https://akshit.io).
