# PortlessBar 0.3.1

Fix proxy controls for FNM and versioned package installations, and explain when Portless needs setup.

- Use stable CLI and Node paths when starting a proxy so it can outlive its FNM shell. Recognize existing proxies whose temporary FNM alias has disappeared, using the live runtime's installed CLI.
- Recognize Portless packages stored under versioned directory names, including Bun layouts.
- Verify privileged proxy operations with the same native process inspection used by the app. Keep unrelated processes protected and show the saved PID when it cannot be verified.
- Show **Portless unavailable** and installation instructions when the CLI or a compatible Node runtime is missing. Disable controls until setup is complete and check again when the menu opens.
- Check whether the installed CLI supports Network mode before restarting a proxy. Older versions keep their proxy controls and show upgrade instructions. Connect once before choosing a mode for a new installation.

Requires macOS 14 or newer, the Portless CLI and its supported Node.js runtime. LAN switching is tested with Portless 0.15.6. Portless 0.8.0 supports proxy controls but not Network mode. Switching modes restarts a running proxy; restart your development apps to register their new URLs. Custom TLDs are not restored after turning Network mode on and then off.

The universal app supports Apple Silicon and Intel. Move `PortlessBar.app` to `/Applications` before enabling Launch at Login.

The download is signed by AKN Technologies FZ-LLC, notarized by Apple, and includes a stapled notarization ticket. SHA256SUMS.txt contains the finalized archive's SHA-256 checksum. Updates use the existing Sparkle trust key.

Licensed under Apache 2.0. PortlessBar is independent and is not affiliated with Vercel.

Made with ❤️ by [akshit.io](https://akshit.io).
