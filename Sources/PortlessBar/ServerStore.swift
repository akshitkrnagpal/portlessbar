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
        if Integration.isPortlessProxy(args), let proxy = args.firstIndex(of: "proxy") {
            result.extras = reconnectExtras(Array(args.dropFirst(proxy + 2)))
        } else {
            let tlds: [String]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: directory + "/proxy.tlds")),
               let values = try? JSONDecoder().decode([String].self, from: data) { tlds = values }
            else if let raw = try? String(contentsOfFile: directory + "/proxy.tld", encoding: .utf8) {
                tlds = [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
            } else { tlds = [] }
            for tld in tlds where !tld.isEmpty { result.extras += ["--tld", tld] }
        }
        if FileManager.default.fileExists(atPath: directory + "/proxy.lan"), !result.extras.contains("--lan") {
            result.extras.append("--lan")
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
            throw PortlessError.message("Install the Portless CLI (npm install -g portless), or set PORTLESSBAR_CLI to its absolute path before launching PortlessBar.")
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
            path = URL(fileURLWithPath: selected).deletingLastPathComponent().path + ":" + path
        }
        return (resolved, Array(executable.dropFirst()), path)
    }

    func run(_ arguments: [String], directory: String) async throws -> CommandResult {
        try Task.checkCancellation()
        let prepared = try await prepare()
        var environment = environment
        environment["PATH"] = prepared.path
        environment["PORTLESS_STATE_DIR"] = directory
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        return try await Commands.execute(executable: prepared.executable, arguments: prepared.arguments + arguments,
                                          environment: environment, timeout: timeout)
    }

    func runAsAdministrator(_ arguments: [String], directory: String, verifyingPID: Int32? = nil) async throws {
        // Resolve the CLI as the user. Never run their login-shell startup files as root.
        let prepared = try await prepare()
        let resolved = prepared.executable
        var command = ""
        if let pid = verifyingPID {
            // A root-owned proxy's argv isn't readable through sysctl as a normal user.
            // Validate it inside the authorized command before delegating to Portless.
            let script = executable.count > 1 ? executable[1] : resolved
            var patterns = ["*'/portless/dist/cli.js proxy start'*", "*'/portless/dist/cli.mjs proxy start'*"]
            if Integration.isPortless(["node", script]) {
                let aliases = Set([script, URL(fileURLWithPath: script).resolvingSymlinksInPath().path])
                patterns += aliases.sorted().map { "*" + Integration.quote($0 + " proxy start") + "*" }
            }
            command = "case \"$(/bin/ps -p \(pid) -o command=)\" in \(patterns.joined(separator: "|"))) ;; *) echo 'The proxy process changed. Try again.'; exit 1;; esac; "
        }
        let nodeDirectory = resolve("node", path: prepared.path).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let privilegedPath = [nodeDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .compactMap { $0 }.joined(separator: ":")
        let env = ["PATH=" + privilegedPath, "HOME=" + home, "SUDO_USER=" + NSUserName(), "SUDO_UID=" + String(getuid()), "SUDO_GID=" + String(getgid()), "PORTLESS_STATE_DIR=" + directory, "NO_COLOR=1", "TERM=dumb"]
        let invocation = [resolved] + prepared.arguments + arguments
        let bounded: [String]
        if let node = resolve("node", path: prepared.path) {
            bounded = [node, "-e", Self.administratorWatchdog, "--", String(timeout)] + invocation
        } else { throw PortlessError.message("A Node.js runtime is required to safely run the administrator command.") }
        command += (["/usr/bin/env"] + env + bounded).map(Integration.quote).joined(separator: " ")
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
    @Published var error: String?
    let stateDirectory: String
    private let command: ProxyCommand
    private let configURL: URL
    private var configuration: ProxyConfiguration?
    private var monitor: Task<Void, Never>?
    private var refreshTask: Task<Snapshot, Error>?
    private var readError: String?
    private let monitorEnabled: Bool
    private var menuOpen = false
    var pollingInterval: Duration { menuOpen ? .seconds(2) : .seconds(15) }

    init(stateDirectory: String? = nil, storageDirectory: URL? = nil, command: ProxyCommand = ProxyCommand(), monitor: Bool = true) {
        self.stateDirectory = stateDirectory ?? ProcessInfo.processInfo.environment["PORTLESS_STATE_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portless").path
        self.command = command
        monitorEnabled = monitor
        let storage = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortlessBar", isDirectory: true)
        configURL = storage.appendingPathComponent("proxy.json")
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let data = try? Data(contentsOf: configURL) { configuration = try JSONDecoder().decode(ProxyConfiguration.self, from: data) }
        } catch { self.error = "Could not read the proxy configuration: \(error.localizedDescription)"; readError = self.error }
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
            if snapshot.proxyRunning, let config = snapshot.configuration, config != configuration {
                try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
                configuration = config
            }
            if error == readError { error = nil }
            readError = nil
            return snapshot
        } catch {
            readError = "Could not save the proxy configuration: \(error.localizedDescription)"
            self.error = readError
            return nil
        }
    }

    func open(_ hostname: String) {
        if let url = Integration.url(hostname: hostname, directory: stateDirectory, fallback: configuration) { NSWorkspace.shared.open(url) }
    }

    func setProxyRunning(_ enabled: Bool) async {
        guard !transitioning else { return }
        transitioning = true
        error = nil
        readError = nil
        defer { transitioning = false }
        do {
            // A monitoring refresh and a lifecycle action share one coherent read.
            guard let snapshot = await refresh() else {
                throw PortlessError.message(error ?? "Could not read Portless state.")
            }
            if snapshot.proxyRunning == enabled { return }
            let state = stateDirectory
            if !enabled, let pid = snapshot.proxyPID {
                let args = Integration.arguments(pid: pid)
                if !args.isEmpty && !Integration.isPortlessProxy(args) {
                    throw PortlessError.message("The registered process is not a Portless proxy. No process was stopped.")
                }
            }
            let config = snapshot.configuration ?? configuration
            let arguments = enabled ? (config?.startArguments ?? ["proxy", "start"]) : ["proxy", "stop"]
            let rootOwned = snapshot.proxyPID.map { kill($0, 0) != 0 && errno == EPERM } ?? false
            if (enabled && (config?.port ?? 65535) < 1024) || (!enabled && rootOwned) {
                try await command.runAsAdministrator(arguments, directory: state, verifyingPID: enabled ? nil : snapshot.proxyPID)
            } else {
                let result = try await command.run(arguments, directory: state)
                if result.status != 0 {
                    let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw PortlessError.message(message.isEmpty ? "Portless exited with status \(result.status). Check it in Terminal and try again." : message)
                }
            }
            let deadline = Date().addingTimeInterval(10)
            repeat {
                await refresh()
                if proxyRunning == enabled { return }
                try await Task.sleep(for: .milliseconds(250))
            } while Date() < deadline
            throw PortlessError.message("The proxy did not \(enabled ? "start" : "stop"). Check Portless in Terminal and try again.")
        } catch { self.error = error.localizedDescription; readError = nil }
        await refresh()
    }
}
