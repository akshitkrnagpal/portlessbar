# PortlessBar 0.4.0

Find Portless apps across your network and configure your proxy from a dedicated settings window.

- Show local registrations under **On this device** and verified Bonjour apps from other Macs under **On this network**. Hide empty groups; show **No servers registered** when both are empty.
- Keep the compact, left-aligned portlessbar wordmark and native proxy switch, with **Portless settings…** directly below.
- Configure This device / Network availability, HTTPS, proxy port, domains, wildcard routing, and custom TLS certificate/key files. Validate edits, preserve other reconnect flags, and apply settings through Portless’s lifecycle, including installed startup services. Saving restarts a running proxy; stopped proxies stay stopped.
- Resize the settings window, remember its frame, and reveal the Advanced controls when expanded.
- Discover network apps even when this Mac’s proxy is stopped or available only on this device. Filter out this Mac’s advertisements and unrelated web services. Use each remote proxy’s advertised port and verified HTTP/HTTPS scheme.

Requires macOS 14 or newer and an existing Portless installation with its supported Node.js runtime. Tested with Portless 0.15.6; proxy compatibility coverage also includes older installations. Network discovery requires Portless LAN mode on another Mac and Local Network access when macOS asks. Discovery does not change certificate trust or control remote proxies. Restart development apps after changing domains or network mode to register their new URLs.

The universal download supports Apple Silicon and Intel, is Developer ID signed and notarized by Apple, and includes a stapled notarization ticket. The finalized archive’s checksum is included in SHA256SUMS.txt. In-app updates use the existing Sparkle signing key.

Licensed under Apache 2.0. PortlessBar is independent and is not affiliated with Vercel.

Made with ❤️ by [akshit.io](https://akshit.io).

# PortlessBar 0.3.2

Fix proxy controls across package-manager installations, preserve connection state when changing network mode, and animate both controls.

- Restore proxy on/off and This Mac/Network switching when a running proxy's original launcher or package directory has disappeared. Verify the running proxy by its saved PID, listening socket and Portless response instead of package-manager path patterns.
- Keep the main switch at its previous on/off setting throughout a mode change. An enabled proxy restarts; changing modes while disconnected keeps it off.
- Preserve the native switch animation and add a short fade for This Mac/Network. Keep the selected position visible while commands run, restore the observed position on failure, and respect Reduce Motion.
- Identify installed JavaScript entry points from package metadata and preserve reconnect options when the original CLI has disappeared.

Requires macOS 14 or newer, the Portless CLI and its supported Node.js runtime. Tested with Portless 0.8.0, 0.15.3 and 0.15.6. Network mode requires a supporting CLI and a working LAN connection. Restart your development apps after a mode change to register their new URLs. Turning Network mode off returns to `.localhost`; custom TLDs must be set again in Portless.

The universal app supports Apple Silicon and Intel. Move `PortlessBar.app` to `/Applications` before enabling Launch at Login.

The download is Developer ID signed, notarized by Apple, and includes a stapled notarization ticket. SHA256SUMS.txt contains the finalized archive's SHA-256 checksum. The update signing key is recovered through Sparkle’s supported rotation process, preserving the previous release’s Apple signing requirement.

Licensed under Apache 2.0. PortlessBar is independent and is not affiliated with Vercel.

Made with ❤️ by [akshit.io](https://akshit.io).

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
