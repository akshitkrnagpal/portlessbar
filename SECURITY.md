# Security

Report vulnerabilities privately to [hello@akshit.io](mailto:hello@akshit.io). Do not post credentials or exploit details in a public issue. GitHub private vulnerability reporting can also be used when available on the repository.

Security fixes target the latest source version. Include the macOS, PortlessBar, Portless and Node.js versions and a minimal reproduction. We aim to acknowledge reports within seven days; this is a maintainer-run project with no guaranteed response time.

## Administrator authorization

PortlessBar normally runs as your user. Starting a privileged-port proxy or stopping a root-owned proxy can require the standard macOS administrator prompt. Switching LAN mode restarts such a proxy under a single prompt, or reruns `portless service install` when Portless's startup service is installed. That reinstall runs with the runtime and script recorded in the service, or the resolved CLI when they no longer exist. The app delegates lifecycle operations to the installed Portless CLI; it does not install a privileged helper or retain your password.

Approving the prompt grants root execution to PortlessBar's process verifier, that CLI, its Node runtime and their dependencies. The verifier checks that the state directory's saved PID owns the loopback TCP listener and that a HEAD request returns `X-Portless: 1`. It checks the state and socket generation again after the request, before allowing the CLI to stop the proxy. Installation paths and process executable names are not used to authorize stopping a process, and the verifier does not install a persistent helper. This is the same trust decision as running `sudo portless`. The CLI or runtime may live in directories writable by your user, including package-manager or version-manager installations. Only approve elevation for installations and dependencies you trust. A compromised executable, symlink or dependency can run arbitrary code as root. The process identity check is a guard against accidentally stopping an unrelated process, not a security boundary against an attacker controlling your account; the identifying HTTP header can be imitated.

Identity probes connect only to numeric IPv4/IPv6 loopback addresses. They ignore curl configuration and proxy environment settings, do not follow redirects, and have a short timeout. Certificate validation is disabled only for this local HTTPS identity probe so it can identify a proxy using development certificates; this does not change browser trust or system certificate settings.

The app resolves executables without sourcing shell startup files, quotes each argument, and restricts the privileged PATH to the selected Node runtime directory and standard system/package-manager locations. Those package-manager locations can also be user-writable. This reduces ambient PATH exposure but does not remove the installed-CLI trust requirement. Administrator prompts run on a dedicated serial queue so the UI remains responsive.

## Local data

The Portless registry is read-only. Lifecycle changes use the CLI. Proxy launch configuration is stored in `~/Library/Application Support/PortlessBar/proxy.json` with user-only permissions. It can include local certificate paths and network flags; it contains no administrator password. Portless state files and process arguments are implementation details, and compatibility is tested only with the versions listed in the README.

Commands use temporary, user-only log files, deleted after completion. The app has no telemetry, account system or remote management endpoint. Opening URLs, GitHub, X or an email draft uses the corresponding default macOS application.

## Downloads

Sparkle checks an HTTPS appcast hosted in this repository and downloads releases from GitHub. Automatic checks can be disabled in Settings; installation uses Sparkle's update prompt. Optional system-profile reporting is disabled. Update requests still expose ordinary HTTP connection information to the hosting provider.

Update archives are verified with the Ed25519 public key embedded in the app and Apple code signing. Release builds are Developer ID signed and notarized. The Sparkle private key stays in the maintainer's Keychain; it is not stored in source control or Xcode Cloud. A manual GitHub download remains available if the updater fails.

Check the signing/notarization statement and checksum supplied with each release. Developer ID signing and notarization are distinct. Do not disable macOS security protections globally to launch a download. For a trusted non-notarized local build, follow [Apple’s first-launch instructions](https://support.apple.com/en-us/102445).
