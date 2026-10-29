<p align="center">
  <a href="https://github.com/akshitkrnagpal/portlessbar/releases/latest">
    <img src="Assets/AppIcon.png" width="96" height="96" alt="PortlessBar monospace p_ logo" />
  </a>
</p>

<h1 align="center">PortlessBar</h1>

<p align="center"><strong>Your localhost apps. One click away.</strong></p>

<p align="center">
  A tiny native macOS companion for <a href="https://github.com/vercel-labs/portless">Portless</a>.<br />
  Open your apps, toggle the proxy, and get back to work.
</p>

<p align="center">
  <a href="https://github.com/akshitkrnagpal/portlessbar/releases/latest"><strong>Download for macOS</strong></a> ·
  <a href="https://www.youtube.com/watch?v=QpD_BkmKVFM">Watch the video</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="https://github.com/akshitkrnagpal/portlessbar/issues">Support</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-222222" alt="macOS 14 or newer" />
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-222222" alt="Apple Silicon and Intel" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-222222" alt="Apache 2.0 license" /></a>
</p>

<br />

<p align="center">
  <img src="Assets/MenuBar.png" width="720" alt="PortlessBar menu open from the p_ item in the macOS menu bar, showing the proxy switch, sample local servers, and sample network servers" />
</p>
<p align="center"><sub>Your Portless apps, right in the menu bar. Demo uses sample hostnames.</sub></p>

## Within reach

- **Open apps in one click.** Your current Portless registrations appear as URLs under **On this device**. Pick one to open it in your default browser.
- **Find apps on nearby Macs.** Portless apps advertised with `--lan` on other Macs appear under **On this network**. Discovery works while your own proxy is disconnected or in This device mode, and uses each remote proxy's port and HTTP/HTTPS setting.
- **One switch for the proxy.** Use the switch beside the wordmark without stopping your development servers. PortlessBar remembers the observed proxy configuration for reconnecting.
- **Choose This device or Network.** Reach your apps from other devices on your network, or keep them on this Mac. Choose the mode in Portless settings alongside the proxy port, HTTPS, domains, wildcard routing, and custom TLS certificate files. Saving restarts a running proxy; stopped proxies stay stopped. Restart your apps to register their new URLs.
- **Ready when you log in.** Enable Launch at Login in Settings and keep your apps within reach throughout the day.
- **Feels at home on macOS.** A native menu, a monospace identity, and a small Settings screen.

## Get started

You need **macOS 14 or newer** and an existing [Portless installation](https://github.com/vercel-labs/portless) with its supported Node.js runtime. PortlessBar works alongside the CLI you already use.

1. [Download the universal app](https://github.com/akshitkrnagpal/portlessbar/releases/latest).
2. Unzip it and drag `PortlessBar.app` into **Applications**.
3. Open it, then click **`p_`** in your menu bar.

Run your development apps through Portless as usual. They appear in the menu automatically. Use the header switch to control the proxy, **Portless settings…** for proxy options, and **PortlessBar settings…** for Launch at Login and updates.

For apps on another Mac, run its Portless proxy with `--lan` and connect both Macs to the same network. Allow PortlessBar's Local Network access if macOS asks. Network apps appear automatically; PortlessBar filters out this Mac's advertisements and unrelated Bonjour web services. Discovery does not install or trust the other Mac's HTTPS certificate. Your browser uses its existing certificate trust settings when you open a URL.

Or install with Homebrew:

```sh
brew install --cask akshitkrnagpal/tap/portlessbar
```

The **download is Developer ID signed and notarized by Apple**, with support for both Apple Silicon and Intel. It checks for updates automatically and lets you review and install them in-app. Find update controls in **PortlessBar settings…**. Older private beta builds need one manual replacement with the current download to enable the updater.

Complete Portless's initial proxy setup, certificate trust, and any required hosts configuration in Terminal first. macOS may ask for administrator approval when controlling a privileged proxy.

## Small by design

No account. No analytics. No extra dashboard to manage.

PortlessBar keeps the everyday controls in the menu bar. A compact Settings window fits Launch at Login, update preferences, and links to GitHub, X, and email without scrolling.

## Open source

Built in Swift, with [Sparkle](https://sparkle-project.org/) for signed in-app updates. Contributions, bug reports, and ideas are welcome.

To build locally with Swift 6 or newer:

```sh
git clone https://github.com/akshitkrnagpal/portlessbar.git
cd portlessbar
./scripts/build-app.sh
open dist/PortlessBar.app
```

See [Contributing](CONTRIBUTING.md) for development and tests, and [Security](SECURITY.md) for private vulnerability reports and administrator authorization details.

<details>
<summary>Compatibility and custom installations</summary>

Tested with **Portless 0.8.0, 0.15.3 and 0.15.6**. Integration uses Portless's state files and process arguments, so other versions may need compatibility updates.

LAN mode needs a Portless version that has LAN mode; it was tested with 0.15.6. Turning LAN mode off returns to `.localhost`, so set a custom TLD again in Portless.

Nearby discovery was tested against a Portless LAN proxy on another Mac. It uses the Bonjour web service records that Portless publishes on macOS. Portless on Linux currently publishes address records only, so its routes cannot be enumerated this way. Nearby entries refresh automatically and disappear when their advertisements are withdrawn or their proxies stop responding.

If Portless or its supported Node.js runtime is missing, the menu shows setup instructions and disables the proxy controls. Network mode is disabled for older CLI versions before a running proxy is stopped. Proxy identity is independent of package-manager paths: PortlessBar checks that the saved PID owns the listening socket and that the service responds with Portless's identifying header. Existing proxies remain controllable after their original launcher or package directory disappears, provided a working Portless CLI is available for lifecycle commands.

Custom CLI and registry paths can be supplied with `PORTLESSBAR_CLI` and `PORTLESS_STATE_DIR` when launching the app directly from Terminal; Finder and login launches do not inherit your shell's environment.

</details>

PortlessBar is an independent companion and is not affiliated with Vercel.

[Apache License 2.0](LICENSE) © 2026 Akshit Kr Nagpal. See [NOTICE](NOTICE) and [icon attribution](Assets/LinkIcons/README.md).

<p align="center">Made with ❤️ by <a href="https://akshit.io">akshit.io</a></p>
