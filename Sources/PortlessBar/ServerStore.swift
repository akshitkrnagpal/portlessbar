import AppKit
import Combine
import PortlessSystem

struct ProxyConfiguration: Codable, Equatable, Sendable {
    var port: Int
    var tls: Bool
    var extras: [String] = []

    var startArguments: [String] {
        ["proxy", "start", "-p", String(port), tls ? "--https" : "--no-tls"] + extras
    }

    var lan: Bool { extras.contains("--lan") || extras.contains("--ip") }

    // Portless keeps LAN mode across restarts through its proxy.lan marker, and
    // has no --no-lan flag. Only an explicit PORTLESS_LAN=0 starts without it,
    // and an inherited LAN address would turn it back on.
    var startEnvironment: [String: String] { lan ? [:] : ["PORTLESS_LAN": "0", "PORTLESS_LAN_IP": ""] }

    func settingLAN(_ enabled: Bool) -> ProxyConfiguration {
        var result = self
        result.extras = []
        let tokens = Self.reconnectExtras(extras)
        var cursor = 0
        while cursor < tokens.count {
            let flag = tokens[cursor]
            let value = tokens.indices.contains(cursor + 1) ? tokens[cursor + 1] : nil
            if flag == "--lan" { cursor += 1 }
            else if ["--ip", "--lan-ip-auto"].contains(flag), !enabled { cursor += 2 }
            // LAN mode forces .local, and .local only resolves through LAN mode's mDNS.
            else if flag == "--tld", enabled || value == "local" { cursor += 2 }
            else { result.extras.append(flag); cursor += 1 }
        }
        if enabled { result.extras.append("--lan") }
        return result
    }

    /// The command that reinstalls Portless's startup service in the given mode, or nil
    /// when no service is installed for this state directory.
    static func serviceInstall(plist: URL, directory: String, lan: Bool) -> (executable: [String]?, arguments: [String], environment: [String: String])? {
        guard let data = try? Data(contentsOf: plist),
              let service = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let variables = service["EnvironmentVariables"] as? [String: Any], variables["PORTLESS_STATE_DIR"] as? String == directory,
              let arguments = service["ProgramArguments"] as? [String], let proxy = arguments.firstIndex(of: "proxy"),
              arguments.indices.contains(proxy + 1), arguments[proxy + 1] == "start" else { return nil }
        let flags = Array(arguments.dropFirst(proxy + 2))
        guard let flag = flags.firstIndex(where: { ["-p", "--port"].contains($0) }),
              flags.indices.contains(flag + 1), let port = Int(flags[flag + 1]) else { return nil }
        // The installer adds --skip-trust (and --foreground) itself and rejects them as options.
        let extras = reconnectExtras(flags).filter { $0 != "--skip-trust" }
        let configuration = ProxyConfiguration(port: port, tls: !flags.contains("--no-tls"), extras: extras).settingLAN(lan)
        var environment = configuration.startEnvironment
        // The installer copies this from its own environment rather than from the installed service.
        if let hosts = variables["PORTLESS_SYNC_HOSTS"] as? String { environment["PORTLESS_SYNC_HOSTS"] = hosts }
        // Portless writes the service from the runtime and script running the installer.
        // Reuse the installed pair so a mode change cannot repoint the daemon to another build.
        let installed = Array(arguments.prefix(proxy))
        let usable = installed.count == 2 && FileManager.default.isExecutableFile(atPath: installed[0])
            && FileManager.default.fileExists(atPath: installed[1])
        return (usable ? installed : nil, ["service", "install"] + configuration.startArguments.dropFirst(2) + ["--state-dir", directory], environment)
    }

    static func reconnectExtras(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var cursor = 0
        while cursor < arguments.count {
            let token = arguments[cursor]
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(parts[0])
            // Port/TLS come from the observed state. Foreground would keep the
            // CLI attached indefinitely; state-dir is supplied by the app.
            if ["-p", "--port", "--state-dir"].contains(flag) {
                cursor += parts.count == 2 ? 1 : 2
                continue
            }
            if ["--https", "--no-tls", "--foreground"].contains(flag) {
                cursor += 1
                continue
            }
            if ["--tld", "--cert", "--key", "--ip"].contains(flag), parts.count == 2 {
                result += [flag, String(parts[1])]
            } else {
                // Preserve newer flags and their values for the same installed
                // CLI rather than silently losing configuration on reconnect.
                result.append(token)
            }
            cursor += 1
        }
        return result
    }

    static func read(directory: String, pid: Int32?) -> ProxyConfiguration? {
        guard let raw = try? String(contentsOfFile: directory + "/proxy.port", encoding: .utf8),
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else { return nil }
        var result = ProxyConfiguration(port: port, tls: FileManager.default.fileExists(atPath: directory + "/proxy.tls"))
        let args = pid.map(Integration.arguments) ?? []
        let tlds: [String]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: directory + "/proxy.tlds")),
           let values = try? JSONDecoder().decode([String].self, from: data) { tlds = values }
        else if let raw = try? String(contentsOfFile: directory + "/proxy.tld", encoding: .utf8) {
            tlds = [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else { tlds = [] }
        if let proxy = Integration.proxyStartIndex(args) {
            result.extras = reconnectExtras(Array(args.dropFirst(proxy + 2)))
        } else {
            for tld in tlds where !tld.isEmpty { result.extras += ["--tld", tld] }
        }
        // Portless's own rule. It removes the marker while no LAN address is available,
        // but a proxy serving .local is still in LAN mode.
        if FileManager.default.fileExists(atPath: directory + "/proxy.lan") || tlds.contains("local") {
            result = result.settingLAN(true)
        }
        return result
    }
}

struct Snapshot: Sendable {
    var routes: [Route]
    var proxyRunning: Bool
    var proxyPID: Int32?
    var configuration: ProxyConfiguration?

    static func read(directory: String) throws -> Snapshot {
        let routes = try Integration.readRoutes(directory: directory)
        let raw = try? String(contentsOfFile: directory + "/proxy.pid", encoding: .utf8)
        let pid = raw.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 1 ? $0 : nil }
        let configuration = ProxyConfiguration.read(directory: directory, pid: pid)
        let alive = pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false
        let online = alive && configuration.map { pb_listening(Int32($0.port)) != 0 } == true
        return Snapshot(routes: routes, proxyRunning: online,
                        proxyPID: pid, configuration: configuration)
    }
}

struct CommandResult: Sendable {
    var status: Int32
    var output: String
}

struct ProxyCommand: Sendable {
    var executable: [String] = ["portless"]
    var environment = ProcessInfo.processInfo.environment

    var timeout: TimeInterval = 30
    var authorize: @Sendable (String) async throws -> Void = { try await Authorization.execute($0) }
    private let versionManagerDirectories: [String]
    private let home: String

    init(executable: [String] = ["portless"], environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.executable = executable
        self.environment = environment
        home = homeDirectory
        versionManagerDirectories = Self.discoverVersionManagers(environment: environment, home: homeDirectory)
    }

    var path: String {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [home + "/.bun/bin", home + "/.local/bin", home + "/.volta/bin",
                        environment["PNPM_HOME"] ?? home + "/Library/pnpm", home + "/.npm-global/bin",
                        (environment["NPM_CONFIG_PREFIX"] ?? home + "/.npm-global") + "/bin",
                        home + "/.asdf/shims", home + "/.local/share/mise/shims",
                        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        directories += versionManagerDirectories
        var seen = Set<String>()
        return directories.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func discoverVersionManagers(environment: [String: String], home: String) -> [String] {
        var directories: [String] = []
        // Discover version-manager installations without sourcing any shell rc.
        let roots = [environment["FNM_DIR"] ?? home + "/.local/share/fnm",
                     home + "/Library/Application Support/fnm"]
        for root in roots {
            let versions = root + "/node-versions"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []
            directories += names.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                .map { versions + "/" + $0 + "/installation/bin" }
        }
        let nvmRoot = environment["NVM_DIR"] ?? home + "/.nvm"
        let nvm = nvmRoot + "/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        var preferred = (try? String(contentsOfFile: nvmRoot + "/alias/default", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for _ in 0..<5 where preferred.hasPrefix("lts/") && !preferred.contains("..") {
            guard let alias = try? String(contentsOfFile: nvmRoot + "/alias/" + preferred, encoding: .utf8) else { break }
            preferred = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = preferred.hasPrefix("v") ? preferred : "v" + preferred
        let ordered = versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        let matches = ordered.filter { $0 == prefix || $0.hasPrefix(prefix + ".") }
        directories += (matches + ordered.filter { !matches.contains($0) }).map { nvm + "/" + $0 + "/bin" }
        return directories
    }

    private func resolve(_ name: String, path: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        guard !name.contains("/") else { return nil }
        return path.split(separator: ":").map { String($0) + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func prepare() async throws -> (executable: String, arguments: [String], path: String) {
        let first = executable.first ?? "portless"
        let selected = first == "portless" ? (environment["PORTLESSBAR_CLI"] ?? first) : first
        var path = path
        guard let resolved = resolve(selected, path: path) else {
            throw PortlessError.message("Install the Portless CLI with npm install -g portless using its supported Node.js runtime, then reopen this menu. If Portless is already installed, set PORTLESSBAR_CLI to its absolute path before launching PortlessBar.")
        }
        let runtime = URL(fileURLWithPath: resolved).resolvingSymlinksInPath()
        if ["node", "nodejs", "bun"].contains(runtime.lastPathComponent) {
            var arguments = Array(executable.dropFirst())
            if let script = arguments.first, let stable = Integration.portlessScript(script) { arguments[0] = stable.path }
            return (runtime.path, arguments, path)
        }
        // A Node-based CLI must use a runtime compatible with its own package,
        // rather than whichever Homebrew/version-manager node happens to be first.
        let realCLI = URL(fileURLWithPath: resolved).resolvingSymlinksInPath()
        let source = (try? String(contentsOf: realCLI, encoding: .utf8)) ?? ""
        if source.hasPrefix("#!/usr/bin/env node") {
            var minimum = 20
            var ancestor = realCLI.deletingLastPathComponent()
            var candidates = [URL(fileURLWithPath: resolved).deletingLastPathComponent().appendingPathComponent("node").path]
            for _ in 0..<6 {
                if let data = try? Data(contentsOf: ancestor.appendingPathComponent("package.json")),
                   let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   package["name"] as? String == "portless",
                   let engines = package["engines"] as? [String: String], let range = engines["node"],
                   let value = range.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) {
                    minimum = value
                }
                candidates.append(ancestor.appendingPathComponent("bin/node").path)
                ancestor.deleteLastPathComponent()
            }
            candidates += path.split(separator: ":").map { String($0) + "/node" }
            var seen = Set<String>()
            var selected: String?
            for candidate in candidates where seen.insert(candidate).inserted && FileManager.default.isExecutableFile(atPath: candidate) {
                if let result = try? await Commands.execute(executable: candidate, arguments: ["--version"], environment: environment, timeout: 2),
                   result.status == 0,
                   let major = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(separator: ".").first ?? ""),
                   major >= minimum { selected = candidate; break }
            }
            guard let selected else { throw PortlessError.message("This Portless installation needs Node.js \(minimum) or newer. Install a compatible runtime and try again.") }
            let node = URL(fileURLWithPath: selected).resolvingSymlinksInPath()
            path = node.deletingLastPathComponent().path + ":" + path
            // Pass stable paths to Node so a proxy outlives its FNM shell.
            return (node.path, [realCLI.path] + executable.dropFirst(), path)
        }
        return (resolved, Array(executable.dropFirst()), path)
    }

    func installationIssue() async -> String? {
        do { _ = try await prepare(); return nil }
        catch { return error.localizedDescription }
    }

    func installation(directory: String) async -> (issue: String?, supportsLAN: Bool?) {
        do {
            let prepared = try await prepare()
            guard Integration.isPortless([prepared.executable] + prepared.arguments) else { return (nil, nil) }
            var inspector = self
            inspector.timeout = min(timeout, 5)
            let help = try await inspector.run(["--help"], directory: directory)
            guard help.status == 0 else {
                return ("Could not run Portless: " + (help.output.isEmpty ? "exit status \(help.status)." : help.output.trimmingCharacters(in: .whitespacesAndNewlines)), nil)
            }
            return (nil, help.output.contains("--lan"))
        } catch { return (error.localizedDescription, nil) }
    }

    func run(_ arguments: [String], directory: String, environment extra: [String: String] = [:]) async throws -> CommandResult {
        try Task.checkCancellation()
        let prepared = try await prepare()
        var environment = environment.merging(extra) { $1 }
        environment["PATH"] = prepared.path
        environment["PORTLESS_STATE_DIR"] = directory
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        return try await Commands.execute(executable: prepared.executable, arguments: prepared.arguments + arguments,
                                          environment: environment, timeout: timeout)
    }

    func runAsAdministrator(_ arguments: [String], directory: String, verifyingPID: Int32? = nil,
                            restarting: Bool = false, environment extra: [String: String] = [:]) async throws {
        // Resolve the CLI as the user. Never run their login-shell startup files as root.
        let prepared = try await prepare()
        let resolved = prepared.executable
        var command = ""
        if let pid = verifyingPID {
            // A root-owned proxy's sockets may be inaccessible to a normal user.
            // Validate ownership and protocol inside the authorized command.
            guard let verifier = Bundle.main.executableURL?.path else {
                throw PortlessError.message("Could not verify the proxy process. Reopen PortlessBar and try again.")
            }
            command = [verifier, "--verify-portless-proxy", String(pid), directory].map(Integration.quote).joined(separator: " ")
                + " || { echo 'The saved PID no longer identifies a Portless proxy. No process was stopped.'; exit 1; }; "
        }
        // A CLI given as a runtime and script, like an installed service's, brings its own Node.
        let node = URL(fileURLWithPath: resolved).lastPathComponent == "node" ? resolved : resolve("node", path: prepared.path)
        let nodeDirectory = node.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let privilegedPath = [nodeDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .compactMap { $0 }.joined(separator: ":")
        let env = ["PATH=" + privilegedPath, "HOME=" + home, "SUDO_USER=" + NSUserName(), "SUDO_UID=" + String(getuid()), "SUDO_GID=" + String(getgid()), "PORTLESS_STATE_DIR=" + directory, "NO_COLOR=1", "TERM=dumb"]
            + extra.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
        guard let node else {
            throw PortlessError.message("A Node.js runtime is required to safely run the administrator command.")
        }
        let bounded = ["/usr/bin/env"] + env + [node, "-e", Self.administratorWatchdog, "--", String(timeout), resolved] + prepared.arguments
        if restarting, let pid = verifyingPID {
            // macOS prompts again for every script, so a restart is one script. Portless
            // only signals the proxy; wait for it to exit and release the port.
            command += (bounded + ["proxy", "stop"]).map(Integration.quote).joined(separator: " ")
                + " || exit $?; n=0; while /bin/kill -0 \(pid) 2>/dev/null; do n=$((n+1)); "
                + "if [ $n -gt 50 ]; then echo 'The proxy did not stop. Check Portless in Terminal and try again.'; exit 1; fi; /bin/sleep 0.2; done; "
        }
        command += (bounded + arguments).map(Integration.quote).joined(separator: " ")
        let literal = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        try await authorize("do shell script \(literal) with administrator privileges")
    }

    // Runs only after approval. Limit the CLI, not time spent at the password prompt,
    // and signal only that child process; development servers are never targeted.
    static let administratorWatchdog = """
    const {spawn}=require('node:child_process');
    const [seconds, executable, ...args]=process.argv.slice(1);
    const child=spawn(executable,args,{stdio:'inherit'});
    let timedOut=false, escalation;
    const timer=setTimeout(()=>{timedOut=true; console.error('The Portless command timed out. Check Portless in Terminal and try again.'); child.kill('SIGTERM'); escalation=setTimeout(()=>child.kill('SIGKILL'),2000);},Number(seconds)*1000);
    child.on('error',error=>{clearTimeout(timer);console.error(error.message);process.exitCode=1;});
    child.on('close',code=>{clearTimeout(timer);clearTimeout(escalation);process.exitCode=timedOut?124:(code??1);});
    """
}

enum Authorization {
    // AppleScript instances are confined to this serial queue. A synchronous
    // authorization dialog never blocks the app's main actor or task executor.
    static let queue = DispatchQueue(label: "io.akshit.PortlessBar.authorization")

    static func execute(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                autoreleasepool {
                    var failure: NSDictionary?
                    guard let script = NSAppleScript(source: source) else {
                        continuation.resume(throwing: PortlessError.message("Could not prepare the macOS authorization prompt."))
                        return
                    }
                    script.executeAndReturnError(&failure)
                    if let failure {
                        let number = failure[NSAppleScript.errorNumber] as? Int
                        let message = number == -128 ? "Connection change cancelled." :
                            (failure[NSAppleScript.errorMessage] as? String ?? "Could not change the proxy connection.")
                        continuation.resume(throwing: PortlessError.message(message))
                    } else { continuation.resume() }
                }
            }
        }
    }
}

@MainActor
final class ServerStore: ObservableObject {
    @Published var routes: [Route] = []
    @Published var proxyRunning = false
    @Published var transitioning = false
    @Published var lanMode = false
    @Published var switchingLAN = false
    @Published private var proxyToggleDuringLANChange: Bool?
    @Published private var requestedProxyState: Bool?
    @Published private var requestedLANMode: Bool?
    var proxyToggleOn: Bool { requestedProxyState ?? proxyToggleDuringLANChange ?? proxyRunning }
    var lanSelectionOn: Bool { requestedLANMode ?? lanMode }
    @Published var error: String?
    @Published var installationIssue: String?
    @Published var supportsLAN: Bool?
    static let unsupportedLANMessage = "This Portless version does not support Network mode. Update it with npm install -g portless, then reopen this menu."
    var canChooseLANMode: Bool { proxyRunning || configuration != nil }
    let stateDirectory: String
    private let command: ProxyCommand
    private let servicePlist: URL
    private let configURL: URL
    private var configuration: ProxyConfiguration?
    private var monitor: Task<Void, Never>?
    private var refreshTask: Task<Snapshot, Error>?
    private var installationTask: Task<(issue: String?, supportsLAN: Bool?), Never>?
    private var installationCheckedAt = Date.distantPast
    private var readError: String?
    private let monitorEnabled: Bool
    private var menuOpen = false
    var pollingInterval: Duration { menuOpen ? .seconds(2) : .seconds(15) }

    init(stateDirectory: String? = nil, storageDirectory: URL? = nil, command: ProxyCommand = ProxyCommand(), monitor: Bool = true,
         servicePlist: URL = URL(fileURLWithPath: "/Library/LaunchDaemons/sh.portless.proxy.plist")) {
        self.stateDirectory = stateDirectory ?? ProcessInfo.processInfo.environment["PORTLESS_STATE_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portless").path
        self.command = command
        self.servicePlist = servicePlist
        monitorEnabled = monitor
        let storage = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortlessBar", isDirectory: true)
        configURL = storage.appendingPathComponent("proxy.json")
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let data = try? Data(contentsOf: configURL) { configuration = try JSONDecoder().decode(ProxyConfiguration.self, from: data) }
        } catch { self.error = "Could not read the proxy configuration: \(error.localizedDescription)"; readError = self.error }
        lanMode = configuration?.lan ?? false
        restartMonitor()
    }

    deinit { monitor?.cancel() }

    func setMenuOpen(_ open: Bool) {
        guard menuOpen != open else { return }
        menuOpen = open
        restartMonitor()
    }

    private func restartMonitor() {
        guard monitorEnabled else { return }
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.pollingInterval ?? .seconds(15)
                try? await Task.sleep(for: interval)
            }
        }
    }

    @discardableResult
    func refresh() async -> Snapshot? {
        let task: Task<Snapshot, Error>
        let ownsTask = refreshTask == nil
        if let existing = refreshTask { task = existing }
        else {
            let state = stateDirectory
            task = Task.detached { try Snapshot.read(directory: state) }
            refreshTask = task
        }
        defer { if ownsTask { refreshTask = nil } }
        await refreshInstallation()
        let snapshot: Snapshot
        do {
            snapshot = try await task.value
        } catch {
            readError = "Could not read Portless: \(error.localizedDescription)"
            self.error = readError
            return nil
        }
        do {
            if Task.isCancelled { return nil }
            routes = snapshot.routes
            proxyRunning = snapshot.proxyRunning
            if snapshot.proxyRunning, let config = snapshot.configuration, config != configuration { try remember(config) }
            lanMode = (snapshot.proxyRunning ? snapshot.configuration : configuration)?.lan ?? false
            if error == readError { error = nil }
            readError = nil
            return snapshot
        } catch {
            readError = "Could not save the proxy configuration: \(error.localizedDescription)"
            self.error = readError
            return nil
        }
    }

    func refreshInstallation(force: Bool = false) async {
        guard force || Date().timeIntervalSince(installationCheckedAt) >= 15 else { return }
        let task: Task<(issue: String?, supportsLAN: Bool?), Never>
        if let existing = installationTask { task = existing }
        else {
            let command = command
            let directory = stateDirectory
            task = Task { await command.installation(directory: directory) }
            installationTask = task
        }
        let installation = await task.value
        installationIssue = installation.issue
        supportsLAN = installation.supportsLAN
        installationCheckedAt = Date()
        installationTask = nil
    }

    private func remember(_ config: ProxyConfiguration) throws {
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        configuration = config
    }

    private func run(_ arguments: [String], environment: [String: String] = [:]) async throws {
        let result = try await command.run(arguments, directory: stateDirectory, environment: environment)
        if result.status != 0 {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PortlessError.message(message.isEmpty ? "Portless exited with status \(result.status). Check it in Terminal and try again." : message)
        }
    }

    private func settled(within seconds: TimeInterval, _ done: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            await refresh()
            if done() { return true }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        return false
    }

    private func rootOwnedProxy(_ pid: Int32?) async throws -> Bool {
        // Socket inspection of another user's proxy may require elevation.
        // The same verifier runs inside the authorized command before stopping it.
        if let pid, kill(pid, 0) != 0 && errno == EPERM { return true }
        guard let pid, await Integration.verifyProxy(pid: pid, directory: stateDirectory) else {
            throw PortlessError.message("Portless's saved PID \(pid ?? 0) does not identify a Portless proxy. No process was stopped. Check the running proxy and its state directory in Terminal before trying again.")
        }
        return false
    }

    func open(_ hostname: String) {
        if let url = Integration.url(hostname: hostname, directory: stateDirectory, fallback: configuration) { NSWorkspace.shared.open(url) }
    }

    func setProxyRunning(_ enabled: Bool) async {
        guard !transitioning else { return }
        requestedProxyState = enabled
        transitioning = true
        error = nil
        readError = nil
        defer { requestedProxyState = nil; transitioning = false }
        do {
            // A monitoring refresh and a lifecycle action share one coherent read.
            guard let snapshot = await refresh() else {
                throw PortlessError.message(error ?? "Could not read Portless state.")
            }
            if let installationIssue { throw PortlessError.message(installationIssue) }
            if snapshot.proxyRunning == enabled { return }
            let state = stateDirectory
            // State files left by a killed proxy must not override the mode chosen while disconnected.
            let config = (snapshot.configuration ?? configuration)?.settingLAN(lanMode)
            if enabled && config?.lan == true && supportsLAN == false { throw PortlessError.message(Self.unsupportedLANMessage) }
            let rootOwned = enabled ? false : try await rootOwnedProxy(snapshot.proxyPID)
            let arguments = enabled ? (config?.startArguments ?? ["proxy", "start"]) : ["proxy", "stop"]
            let environment = enabled ? (config?.startEnvironment ?? [:]) : [:]
            if (enabled && (config?.port ?? 65535) < 1024) || rootOwned {
                try await command.runAsAdministrator(arguments, directory: state, verifyingPID: enabled ? nil : snapshot.proxyPID,
                                                     environment: environment)
            } else {
                try await run(arguments, environment: environment)
            }
            if try await settled(within: 10, { proxyRunning == enabled }) { return }
            throw PortlessError.message("The proxy did not \(enabled ? "start" : "stop"). Check Portless in Terminal and try again.")
        } catch { self.error = error.localizedDescription; readError = nil }
        await refresh()
    }

    func setLANMode(_ enabled: Bool) async {
        guard !transitioning else { return }
        requestedLANMode = enabled
        transitioning = true
        switchingLAN = true
        error = nil
        readError = nil
        defer { requestedLANMode = nil; proxyToggleDuringLANChange = nil; transitioning = false; switchingLAN = false }
        do {
            guard let snapshot = await refresh() else {
                throw PortlessError.message(error ?? "Could not read Portless state.")
            }
            // A mode change restarts an enabled proxy. Keep the user's switch
            // setting visible while polling still tracks the real stop/start.
            proxyToggleDuringLANChange = snapshot.proxyRunning
            if let installationIssue { throw PortlessError.message(installationIssue) }
            if lanMode == enabled { return }
            if supportsLAN == false { throw PortlessError.message(Self.unsupportedLANMessage) }
            guard snapshot.proxyRunning, let running = snapshot.configuration else {
                // Nothing to restart. The next connect starts in the remembered mode.
                guard let configuration else { throw PortlessError.message("Connect the proxy once before changing LAN mode.") }
                try remember(configuration.settingLAN(enabled))
                lanMode = enabled
                return
            }
            let state = stateDirectory
            let target = running.settingLAN(enabled)
            let install = ProxyConfiguration.serviceInstall(plist: servicePlist, directory: state, lan: enabled)
            if let install {
                // launchd restarts the proxy with the flags in its plist, so only
                // Portless's installer can change the mode of a startup service.
                var installer = command
                if let executable = install.executable { installer.executable = executable }
                try await installer.runAsAdministrator(install.arguments, directory: state, environment: install.environment)
            } else if try await rootOwnedProxy(snapshot.proxyPID) || target.port < 1024 {
                try await command.runAsAdministrator(target.startArguments, directory: state, verifyingPID: snapshot.proxyPID,
                                                     restarting: true, environment: target.startEnvironment)
            } else {
                // A running proxy cannot change mode.
                let pid = snapshot.proxyPID
                try await run(["proxy", "stop"])
                // Portless only signals the proxy; the port is free once the process is gone.
                guard try await settled(within: 10, { !proxyRunning && pid.map { kill($0, 0) != 0 } ?? true }) else {
                    throw PortlessError.message("The proxy did not stop. Check Portless in Terminal and try again.")
                }
                try await run(target.startArguments, environment: target.startEnvironment)
            }
            if try await settled(within: install == nil ? 10 : 20, { proxyRunning && lanMode == enabled }) { return }
            throw PortlessError.message(enabled ? "LAN mode did not turn on. The installed Portless may be too old for LAN mode."
                                        : "LAN mode did not turn off. Check Portless in Terminal and try again.")
        } catch { self.error = error.localizedDescription; readError = nil }
        await refresh()
    }
}
