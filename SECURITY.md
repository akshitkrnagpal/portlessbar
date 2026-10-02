# Security

Report vulnerabilities privately to [hello@akshit.io](mailto:hello@akshit.io). Do not post credentials or exploit details in a public issue. GitHub private vulnerability reporting can also be used when available on the repository.

Security fixes target the latest source version, currently 0.1.0. Include the macOS, PortlessBar, Portless and Node.js versions and a minimal reproduction. We aim to acknowledge reports within seven days; this is a maintainer-run project with no guaranteed response time.

## Administrator authorization

PortlessBar normally runs as your user. Starting a privileged-port proxy or stopping a root-owned proxy can require the standard macOS administrator prompt. The app delegates lifecycle operations to the installed Portless CLI; it does not install a privileged helper or retain your password.

Approving the prompt grants root execution to that CLI, its Node runtime and their dependencies. This is the same trust decision as running `sudo portless`. The CLI or runtime may live in directories writable by your user, including package-manager or version-manager installations. Only approve elevation for installations and dependencies you trust. A compromised executable, symlink or dependency can run arbitrary code as root. The process identity check is a guard against accidentally stopping an unrelated process, not a security boundary against an attacker controlling your account.

The app resolves executables without sourcing shell startup files, quotes each argument, and restricts the privileged PATH to the selected Node runtime directory and standard system/package-manager locations. Those package-manager locations can also be user-writable. This reduces ambient PATH exposure but does not remove the installed-CLI trust requirement. Administrator prompts run on a dedicated serial queue so the UI remains responsive.

## Local data

The Portless registry is read-only. Lifecycle changes use the CLI. Proxy launch configuration is stored in `~/Library/Application Support/PortlessBar/proxy.json` with user-only permissions. It can include local certificate paths and network flags; it contains no administrator password. Portless state files and process arguments are implementation details, and compatibility is tested only with the versions listed in the README.

Commands use temporary, user-only log files, deleted after completion. The app has no telemetry, account system or remote management endpoint. Opening URLs, GitHub, X or an email draft uses the corresponding default macOS application.

## Downloads

Check the signing/notarization statement and checksum supplied with each release. Developer ID signing and notarization are distinct. Do not disable macOS security protections globally to launch a download. For a trusted non-notarized local build, follow [Apple’s first-launch instructions](https://support.apple.com/en-us/102445).
