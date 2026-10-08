# PortlessBar 0.3.0

Choose where your apps are reachable with clearer menu controls and a smaller Settings window.

- Replace the LAN switch with a native **This Mac / Network** selector. The status below it shows the current mode and reminds you when running apps need a restart to update their URLs.
- Fit Launch at Login, update controls and links into a compact Settings window without scrolling at its default size.
- Add space around the proxy controls and between each control and its status text. The menu also accommodates larger fonts and wider status messages.

The release process now verifies the public update feed and archive, including the checksum, Sparkle signature, both CPU architectures, code signature, stapled notarization ticket and Gatekeeper acceptance.

Requires macOS 14 or newer, the Portless CLI and its supported Node.js runtime. LAN mode is supported with Portless 0.15.6. Portless 0.8.0 remains supported for proxy controls but does not support LAN mode. Switching modes restarts a running proxy; restart your development apps to register their new URLs. Custom TLDs are not restored after turning LAN mode on and then off.

The universal app supports Apple Silicon and Intel. Move `PortlessBar.app` to `/Applications` before enabling Launch at Login.

The download is signed by AKN Technologies FZ-LLC, notarized by Apple, and includes a stapled notarization ticket. Gatekeeper accepts the final archive. SHA256SUMS.txt contains its SHA-256 checksum.

Licensed under Apache 2.0. PortlessBar is independent and is not affiliated with Vercel.

Made with ❤️ by [akshit.io](https://akshit.io).
