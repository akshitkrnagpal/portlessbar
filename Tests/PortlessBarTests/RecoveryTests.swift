import XCTest
import Darwin
@testable import PortlessBar

private final class Prompts: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String] = []
    var scripts: [String] { lock.withLock { sources } }
    func record(_ source: String) { lock.withLock { sources.append(source) } }
}

final class RecoveryTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testValidRoutesSurviveMalformedNeighborsAndMissingPID() throws {
        let root = try temporaryDirectory()
        let registry = Data("""
        [{"hostname":"api.localhost","port":3000},
         {"hostname":"evil/path","port":-1,"pid":0},
         {"hostname":"web.localhost","port":3001,"pid":42},
         {"hostname":true,"port":3002}]
        """.utf8)
        let file = root.appendingPathComponent("routes.json")
        try registry.write(to: file)
        XCTAssertEqual(try Integration.readRoutes(directory: root.path).map(\.hostname), ["api.localhost", "web.localhost"])
        XCTAssertEqual(try Data(contentsOf: file), registry)
    }

    @MainActor
    func testRegistryErrorClearsAfterRecovery() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("routes.json")
        try Data("broken JSON".utf8).write(to: file)
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"), monitor: false)
        await store.refresh()
        XCTAssertNotNil(store.error)
        try Data("[]".utf8).write(to: file)
        await store.refresh()
        XCTAssertNil(store.error)
    }

    func testMissingCLIHasActionableError() async throws {
        let root = try temporaryDirectory()
        do {
            _ = try await ProxyCommand(executable: ["portlessbar-missing-cli-713"]).run(["proxy", "start"], directory: root.path)
            XCTFail("Missing CLI should throw an installation error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Install the Portless CLI"), error.localizedDescription)
        }
    }

    @MainActor
    func testMissingCLIIsReportedBeforeLifecycleChanges() async throws {
        let root = try temporaryDirectory()
        let command = ProxyCommand(executable: [root.appendingPathComponent("missing-portless").path])
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"), command: command, monitor: false)
        await store.refresh()
        XCTAssertTrue(try XCTUnwrap(store.installationIssue).contains("Install the Portless CLI"))
        await store.setProxyRunning(true)
        XCTAssertEqual(store.error, store.installationIssue)
        await store.setLANMode(true)
        XCTAssertEqual(store.error, store.installationIssue)
        XCTAssertFalse(store.proxyRunning)
        XCTAssertFalse(store.lanMode)
    }

    @MainActor
    func testReusedPIDNeverStopsAnUnrelatedProcess() async throws {
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try observeProxy(pid: getpid(), in: state)
        let command = ProxyCommand(executable: ["/usr/bin/true"])
        let store = ServerStore(stateDirectory: state.path, storageDirectory: root.appendingPathComponent("app"), command: command,
                                monitor: false, servicePlist: root.appendingPathComponent("missing.plist"))
        await store.setProxyRunning(false)
        XCTAssertTrue(try XCTUnwrap(store.error).contains("No process was stopped"))
        XCTAssertTrue(store.proxyRunning)
        await store.setLANMode(true)
        XCTAssertTrue(try XCTUnwrap(store.error).contains("No process was stopped"))
        XCTAssertFalse(store.lanMode)
        XCTAssertTrue(store.proxyRunning)
    }

    @MainActor
    func testUnsupportedLANModeIsRejectedBeforeStoppingProxy() async throws {
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        let script = root.appendingPathComponent("portless/dist/cli.js")
        let node = root.appendingPathComponent("portless/bin/node")
        for directory in [state, script.deletingLastPathComponent(), node.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try observeProxy(pid: getpid(), in: state)
        try Data("#!/usr/bin/env node\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let unexpected = root.appendingPathComponent("unexpected-command")
        try Data(("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo v24.0.0; elif [ \"$2\" = \"--help\" ]; then echo 'portless proxy start --https'; else touch "
                  + Integration.quote(unexpected.path) + "; exit 77; fi\n").utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let command = ProxyCommand(executable: [script.path])
        let store = ServerStore(stateDirectory: state.path, storageDirectory: root.appendingPathComponent("app"), command: command, monitor: false)
        await store.setLANMode(true)
        XCTAssertEqual(store.supportsLAN, false)
        XCTAssertEqual(store.error, ServerStore.unsupportedLANMessage)
        XCTAssertTrue(store.proxyRunning)
        XCTAssertFalse(store.lanMode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unexpected.path))
    }

    func testReconnectKeepsEqualsValuesAndFutureFlags() {
        let args = ["--port=1355", "--https", "--foreground", "--state-dir", "/tmp/state",
                    "--tld=dev", "--tld", "test", "--cert=/tmp/cert", "--key", "/tmp/key",
                    "--ip=192.168.1.8", "--wildcard", "--future=value", "--future-pair", "value"]
        XCTAssertEqual(ProxyConfiguration.reconnectExtras(args),
                       ["--tld", "dev", "--tld", "test", "--cert", "/tmp/cert", "--key", "/tmp/key",
                        "--ip", "192.168.1.8", "--wildcard", "--future=value", "--future-pair", "value"])
    }

    func testLANModeRewritesReconnectFlags() {
        let lan = ProxyConfiguration(port: 443, tls: true, extras: ["--lan", "--ip=192.168.1.8", "--tld", "local", "--tld", "test",
                                                                    "--lan-ip-auto", "192.168.1.8", "--wildcard", "--future-pair", "value"])
        XCTAssertTrue(lan.lan)
        XCTAssertEqual(lan.settingLAN(false).extras, ["--tld", "test", "--wildcard", "--future-pair", "value"])
        XCTAssertEqual(lan.settingLAN(true).extras, ["--ip", "192.168.1.8", "--lan-ip-auto", "192.168.1.8", "--wildcard", "--future-pair", "value", "--lan"])
        XCTAssertTrue(ProxyConfiguration(port: 443, tls: true, extras: ["--ip", "192.168.1.8"]).lan)
        XCTAssertEqual(ProxyConfiguration(port: 443, tls: true, extras: ["--ip", "192.168.1.8", "--tld=local"]).settingLAN(false).extras, [])
        let local = ProxyConfiguration(port: 1355, tls: false, extras: ["--tld=dev", "--tld", "test", "--wildcard", "--future=value"])
        XCTAssertFalse(local.lan)
        XCTAssertEqual(local.settingLAN(false), ProxyConfiguration(port: 1355, tls: false, extras: ["--tld", "dev", "--tld", "test", "--wildcard", "--future=value"]))
        XCTAssertEqual(local.settingLAN(true).extras, ["--wildcard", "--future=value", "--lan"])
    }

    func testStartCarriesExplicitLANMode() async throws {
        let root = try temporaryDirectory()
        let node = root.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(atPath: node.path, withDestinationPath: "/usr/bin/true")
        // A shell-exported value must not decide the mode of a remembered configuration.
        var command = ProxyCommand(executable: ["/bin/sh", "-c", "echo \"${PORTLESS_LAN-unset} [${PORTLESS_LAN_IP-unset}] $*\"", "portless"],
                                   environment: ["PORTLESS_LAN": "1", "PORTLESS_LAN_IP": "192.168.1.8", "PATH": root.path])
        let prompts = Prompts()
        command.authorize = { prompts.record($0) }
        let local = ProxyConfiguration(port: 1355, tls: false)
        let lan = local.settingLAN(true)
        XCTAssertEqual(lan.startArguments, ["proxy", "start", "-p", "1355", "--no-tls", "--lan"])
        let started = try await command.run(local.startArguments, directory: root.path, environment: local.startEnvironment)
        XCTAssertEqual(started.output, "0 [] proxy start -p 1355 --no-tls\n")
        try await command.runAsAdministrator(local.startArguments, directory: root.path, environment: local.startEnvironment)
        try await command.runAsAdministrator(lan.startArguments, directory: root.path, environment: lan.startEnvironment)
        XCTAssertTrue(prompts.scripts[0].contains("'PORTLESS_LAN=0' 'PORTLESS_LAN_IP='"))
        XCTAssertFalse(prompts.scripts[0].contains("'--lan'"))
        XCTAssertTrue(prompts.scripts[1].contains("'--lan'"))
        XCTAssertFalse(prompts.scripts[1].contains("'PORTLESS_LAN="))
    }

    private func servicePlist(in root: URL, stateDirectory: String, cli: [String] = ["/missing/node", "/missing/portless/dist/cli.js"]) throws -> URL {
        let plist = root.appendingPathComponent("sh.portless.proxy.plist")
        let service: [String: Any] = [
            "Label": "sh.portless.proxy", "KeepAlive": true,
            "ProgramArguments": cli + ["proxy", "start", "--foreground", "--port", "443", "--https", "--lan", "--skip-trust"],
            "EnvironmentVariables": ["PORTLESS_STATE_DIR": stateDirectory, "PORTLESS_PORT": "443", "PORTLESS_HTTPS": "1",
                                     "PORTLESS_LAN": "1", "PORTLESS_WILDCARD": "0", "PORTLESS_TLD": "local", "PORTLESS_SYNC_HOSTS": "0"]
        ]
        try PropertyListSerialization.data(fromPropertyList: service, format: .xml, options: 0).write(to: plist)
        return plist
    }

    /// A runtime and script that only need to exist, standing in for an installed service's CLI.
    private func installedCLI(in root: URL) throws -> [String] {
        let node = root.appendingPathComponent("service/node")
        let script = root.appendingPathComponent("service/portless/dist/cli.js")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: node.path, withDestinationPath: "/usr/bin/true")
        try Data().write(to: script)
        return [node.path, script.path]
    }

    func testServiceReinstallKeepsInstalledOptionsForMatchingStateDirectory() throws {
        let root = try temporaryDirectory()
        let cli = try installedCLI(in: root)
        let plist = try servicePlist(in: root, stateDirectory: "/Users/me/.portless", cli: cli)
        let off = try XCTUnwrap(ProxyConfiguration.serviceInstall(plist: plist, directory: "/Users/me/.portless", lan: false))
        XCTAssertEqual(off.executable, cli, "The reinstall must not repoint the service to another Portless build")
        XCTAssertEqual(off.arguments, ["service", "install", "-p", "443", "--https", "--state-dir", "/Users/me/.portless"])
        XCTAssertEqual(off.environment, ["PORTLESS_LAN": "0", "PORTLESS_LAN_IP": "", "PORTLESS_SYNC_HOSTS": "0"])
        let on = try XCTUnwrap(ProxyConfiguration.serviceInstall(plist: plist, directory: "/Users/me/.portless", lan: true))
        XCTAssertEqual(on.arguments, ["service", "install", "-p", "443", "--https", "--lan", "--state-dir", "/Users/me/.portless"])
        XCTAssertEqual(on.environment, ["PORTLESS_SYNC_HOSTS": "0"])
        XCTAssertNil(ProxyConfiguration.serviceInstall(plist: plist, directory: "/Users/other/.portless", lan: false))
        XCTAssertNil(ProxyConfiguration.serviceInstall(plist: root.appendingPathComponent("missing.plist"), directory: "/Users/me/.portless", lan: false))
        // An uninstalled runtime or script falls back to the CLI the app resolves.
        let stale = try servicePlist(in: root, stateDirectory: "/Users/me/.portless")
        XCTAssertNil(try XCTUnwrap(ProxyConfiguration.serviceInstall(plist: stale, directory: "/Users/me/.portless", lan: false)).executable)
    }

    func testRootOwnedLANProxyWithoutMarkerStaysInLANMode() throws {
        let root = try temporaryDirectory()
        try Data("443".utf8).write(to: root.appendingPathComponent("proxy.port"))
        try Data().write(to: root.appendingPathComponent("proxy.tls"))
        // Portless removes proxy.lan while it has no LAN address, and a root-owned proxy's argv is unreadable.
        try Data("local\n".utf8).write(to: root.appendingPathComponent("proxy.tld"))
        XCTAssertEqual(ProxyConfiguration.read(directory: root.path, pid: nil), ProxyConfiguration(port: 443, tls: true, extras: ["--lan"]))
        try Data("192.168.1.8".utf8).write(to: root.appendingPathComponent("proxy.lan"))
        XCTAssertEqual(ProxyConfiguration.read(directory: root.path, pid: nil), ProxyConfiguration(port: 443, tls: true, extras: ["--lan"]))
        try FileManager.default.removeItem(at: root.appendingPathComponent("proxy.lan"))
        try Data("test\n".utf8).write(to: root.appendingPathComponent("proxy.tld"))
        XCTAssertEqual(ProxyConfiguration.read(directory: root.path, pid: nil), ProxyConfiguration(port: 443, tls: true, extras: ["--tld", "test"]))
    }

    /// Makes a snapshot observe a running proxy owned by `pid`, without starting one.
    private func observeProxy(pid: Int32, in state: URL) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        addTeardownBlock { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        // Every refresh probes the port; nothing accepts, so leave room in the backlog.
        XCTAssertEqual(listen(listener, SOMAXCONN), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        try Data("\(pid)".utf8).write(to: state.appendingPathComponent("proxy.pid"))
        try Data("\(UInt16(bigEndian: address.sin_port))".utf8).write(to: state.appendingPathComponent("proxy.port"))
    }

    /// A CLI and Node runtime that only need to resolve; authorization is captured.
    private func capturedCommand(in root: URL, marker: URL, prompts: Prompts) throws -> ProxyCommand {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("node").path, withDestinationPath: "/usr/bin/true")
        var command = ProxyCommand(environment: ["PORTLESSBAR_CLI": "/usr/bin/printf", "PATH": root.path])
        command.authorize = { source in
            prompts.record(source)
            // Stand in for Portless, which writes this marker only while LAN mode is active.
            if source.contains("'--lan'") { try Data("192.168.1.8".utf8).write(to: marker) }
            else { try FileManager.default.removeItem(at: marker) }
        }
        return command
    }

    @MainActor
    func testLANSwitchRestartsRootOwnedProxyWithOnePrompt() async throws {
        guard let pid = (2..<Int32(100000)).first(where: { kill($0, 0) != 0 && errno == EPERM }) else {
            throw XCTSkip("No process owned by another user is available to stand in for a root-owned proxy.")
        }
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try observeProxy(pid: pid, in: state)
        let prompts = Prompts()
        let command = try capturedCommand(in: root, marker: state.appendingPathComponent("proxy.lan"), prompts: prompts)
        let store = ServerStore(stateDirectory: state.path, storageDirectory: root.appendingPathComponent("app"), command: command,
                                monitor: false, servicePlist: root.appendingPathComponent("missing.plist"))
        await store.setLANMode(true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.lanMode)
        XCTAssertEqual(prompts.scripts.count, 1, "Stopping and starting must share one administrator prompt")
        let on = try XCTUnwrap(prompts.scripts.first)
        let verified = try XCTUnwrap(on.range(of: "'--verify-portless-proxy' '\(pid)'"))
        let stopped = try XCTUnwrap(on.range(of: "'proxy' 'stop'"))
        let waited = try XCTUnwrap(on.range(of: "/bin/kill -0 \(pid) "))
        let restarted = try XCTUnwrap(on.range(of: "'proxy' 'start'"))
        XCTAssertLessThan(verified.lowerBound, stopped.lowerBound)
        XCTAssertLessThan(stopped.lowerBound, waited.lowerBound)
        XCTAssertLessThan(waited.lowerBound, restarted.lowerBound)
        XCTAssertTrue(on[restarted.upperBound...].contains("'--lan'"))
        await store.setLANMode(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        XCTAssertEqual(prompts.scripts.count, 2)
        let off = prompts.scripts[1]
        XCTAssertLessThan(try XCTUnwrap(off.range(of: "'proxy' 'stop'")).lowerBound, try XCTUnwrap(off.range(of: "'proxy' 'start'")).lowerBound)
        XCTAssertTrue(off.contains("'PORTLESS_LAN=0' 'PORTLESS_LAN_IP='"))
        XCTAssertFalse(off.contains("'--lan'"))
    }

    @MainActor
    func testLANSwitchReinstallsStartupService() async throws {
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try observeProxy(pid: getpid(), in: state)
        let marker = state.appendingPathComponent("proxy.lan")
        try Data("192.168.1.8".utf8).write(to: marker)
        let prompts = Prompts()
        let command = try capturedCommand(in: root, marker: marker, prompts: prompts)
        let cli = try installedCLI(in: root)
        let store = ServerStore(stateDirectory: state.path, storageDirectory: root.appendingPathComponent("app"), command: command,
                                monitor: false, servicePlist: try servicePlist(in: root, stateDirectory: state.path, cli: cli))
        await store.refresh()
        XCTAssertTrue(store.lanMode)
        await store.setLANMode(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        XCTAssertEqual(prompts.scripts.count, 1)
        let script = try XCTUnwrap(prompts.scripts.first)
        // The installed runtime runs both the watchdog and the installed script.
        XCTAssertTrue(script.contains(Integration.quote(cli[0]) + " '-e' "))
        XCTAssertTrue(script.contains((cli + ["service", "install", "-p", "443", "--https", "--state-dir", state.path]).map(Integration.quote).joined(separator: " ")))
        XCTAssertTrue(script.contains("'PATH=" + root.appendingPathComponent("service").path + ":"))
        XCTAssertTrue(script.contains("'PORTLESS_LAN=0' 'PORTLESS_LAN_IP=' 'PORTLESS_SYNC_HOSTS=0'"))
        XCTAssertFalse(script.contains("/usr/bin/printf"))
        // launchd would bring a stopped proxy straight back in the old mode.
        XCTAssertFalse(script.contains("'proxy' 'stop'"))
    }

    @MainActor
    func testCancelledLANSwitchKeepsTheRunningMode() async throws {
        guard let pid = (2..<Int32(100000)).first(where: { kill($0, 0) != 0 && errno == EPERM }) else {
            throw XCTSkip("No process owned by another user is available to stand in for a root-owned proxy.")
        }
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try observeProxy(pid: pid, in: state)
        let prompts = Prompts()
        var command = try capturedCommand(in: root, marker: state.appendingPathComponent("proxy.lan"), prompts: prompts)
        command.authorize = { source in
            prompts.record(source)
            throw PortlessError.message("Connection change cancelled.")
        }
        let store = ServerStore(stateDirectory: state.path, storageDirectory: root.appendingPathComponent("app"), command: command,
                                monitor: false, servicePlist: root.appendingPathComponent("missing.plist"))
        await store.setLANMode(true)
        XCTAssertEqual(prompts.scripts.count, 1)
        XCTAssertEqual(store.error, "Connection change cancelled.")
        XCTAssertFalse(store.lanMode)
        XCTAssertTrue(store.proxyRunning)
        XCTAssertFalse(store.transitioning)
        XCTAssertFalse(store.switchingLAN)
    }

    @MainActor
    func testConnectUsesModeChosenWhileDisconnectedOverStaleStateFiles() async throws {
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        let storage = root.appendingPathComponent("app")
        for directory in [state, storage] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // A killed LAN proxy leaves its port, pid and LAN markers behind.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        try Data("\(exited.processIdentifier)".utf8).write(to: state.appendingPathComponent("proxy.pid"))
        try Data("1355".utf8).write(to: state.appendingPathComponent("proxy.port"))
        try Data("local\n".utf8).write(to: state.appendingPathComponent("proxy.tld"))
        try Data("192.168.1.8".utf8).write(to: state.appendingPathComponent("proxy.lan"))
        try JSONEncoder().encode(ProxyConfiguration(port: 1355, tls: false, extras: ["--lan"])).write(to: storage.appendingPathComponent("proxy.json"))
        let started = root.appendingPathComponent("started")
        let record = "echo \"${PORTLESS_LAN-unset} $*\" > \(Integration.quote(started.path)); echo 'recorded'; exit 1"
        let command = ProxyCommand(executable: ["/bin/sh", "-c", record, "portless"])
        let store = ServerStore(stateDirectory: state.path, storageDirectory: storage, command: command, monitor: false)
        XCTAssertTrue(store.lanMode)
        await store.setLANMode(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
        await store.setProxyRunning(true)
        XCTAssertEqual(store.error, "recorded")
        XCTAssertEqual(try String(contentsOf: started, encoding: .utf8), "0 proxy start -p 1355 --no-tls\n")
    }

    @MainActor
    func testLANSwitchWhileDisconnectedOnlyRemembersTheMode() async throws {
        let root = try temporaryDirectory()
        let storage = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let file = storage.appendingPathComponent("proxy.json")
        try JSONEncoder().encode(ProxyConfiguration(port: 1355, tls: false, extras: ["--tld", "test"])).write(to: file)
        // Installation is present, but any lifecycle command or elevation would fail.
        let cli = root.appendingPathComponent("portless")
        try Data("#!/bin/sh\nexit 77\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        var command = ProxyCommand(executable: [cli.path])
        command.authorize = { _ in throw PortlessError.message("Unexpected administrator prompt") }
        let store = ServerStore(stateDirectory: root.path, storageDirectory: storage, command: command, monitor: false)
        XCTAssertFalse(store.lanMode)
        await store.setLANMode(true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.lanMode)
        XCTAssertFalse(store.proxyRunning)
        XCTAssertEqual(try JSONDecoder().decode(ProxyConfiguration.self, from: Data(contentsOf: file)),
                       ProxyConfiguration(port: 1355, tls: false, extras: ["--lan"]))
        XCTAssertTrue(ServerStore(stateDirectory: root.path, storageDirectory: storage, command: command, monitor: false).lanMode)
        await store.setLANMode(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        XCTAssertEqual(try JSONDecoder().decode(ProxyConfiguration.self, from: Data(contentsOf: file)), ProxyConfiguration(port: 1355, tls: false))
        let fresh = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("fresh"), command: command, monitor: false)
        await fresh.setLANMode(true)
        XCTAssertEqual(fresh.error, "Connect the proxy once before changing LAN mode.")
        XCTAssertFalse(fresh.lanMode)
    }

    func testCommandTimeoutTerminatesProcess() async throws {
        let root = try temporaryDirectory()
        var command = ProxyCommand(executable: ["/bin/sleep"])
        command.timeout = 0.1
        let start = Date()
        do {
            _ = try await command.run(["10"], directory: root.path)
            XCTFail("The command should time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testCommandCancellationAndConcurrentCompletion() async throws {
        let root = try temporaryDirectory()
        let task = Task { try await ProxyCommand(executable: ["/bin/sleep"]).run(["10"], directory: root.path) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("The command should be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let result = try await ProxyCommand(executable: ["/usr/bin/printf"]).run(["clean output"], directory: root.path)
                    XCTAssertEqual(result.status, 0)
                    XCTAssertEqual(result.output, "clean output")
                }
            }
            try await group.waitForAll()
        }
    }

    @MainActor
    func testCommandErrorSurvivesSuccessfulRegistryRead() async throws {
        let root = try temporaryDirectory()
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"),
                                command: ProxyCommand(executable: ["/usr/bin/false"]), monitor: false)
        await store.setProxyRunning(true)
        XCTAssertNotNil(store.error)
        await store.refresh()
        XCTAssertNotNil(store.error, "Polling must not dismiss an action failure before it can be read")
    }

    @MainActor
    func testAppleScriptWaitDoesNotBlockMainActor() async throws {
        let start = Date()
        let script = Task { try await Authorization.execute("delay 1") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8, "The UI actor must remain available while AppleScript runs")
        try await script.value
    }

    @MainActor
    func testFailureMentioningSudoDoesNotRequestElevation() async throws {
        let root = try temporaryDirectory()
        var command = ProxyCommand(executable: ["/bin/sh", "-c", "echo 'configuration failed; sudo is unrelated'; exit 1"])
        command.authorize = { _ in throw PortlessError.message("Unexpected administrator retry") }
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"), command: command, monitor: false)
        await store.setProxyRunning(true)
        XCTAssertEqual(store.error, "configuration failed; sudo is unrelated")
    }

    func testCLIOverrideAppliesToBothExecutionPaths() async throws {
        let root = try temporaryDirectory()
        // Authorization is captured, so the wrapper need only be resolvable.
        // Keep this unit test independent of a machine's installed Node runtime.
        let node = root.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(atPath: node.path, withDestinationPath: "/usr/bin/true")
        var command = ProxyCommand(environment: ["PORTLESSBAR_CLI": "/usr/bin/printf", "PATH": root.path])
        let result = try await command.run(["selected CLI"], directory: root.path)
        XCTAssertEqual(result.output, "selected CLI")
        command.authorize = { source in
            XCTAssertTrue(source.contains("/usr/bin/printf"))
        }
        try await command.runAsAdministrator(["selected CLI"], directory: root.path)
    }

    @MainActor
    func testMenuUsesSlowerPollingWhileClosed() throws {
        let root = try temporaryDirectory()
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root, monitor: false)
        XCTAssertEqual(store.pollingInterval, .seconds(15))
        store.setMenuOpen(true)
        XCTAssertEqual(store.pollingInterval, .seconds(2))
        store.setMenuOpen(false)
        XCTAssertEqual(store.pollingInterval, .seconds(15))
    }

    func testPNPMAndCustomNpmPrefixDiscovery() throws {
        let root = try temporaryDirectory()
        let command = ProxyCommand(environment: ["PNPM_HOME": root.path + "/pnpm", "NPM_CONFIG_PREFIX": root.path + "/npm"], homeDirectory: root.path)
        let directories = command.path.split(separator: ":").map(String.init)
        XCTAssertTrue(directories.contains(root.path + "/pnpm"))
        XCTAssertTrue(directories.contains(root.path + "/npm/bin"))
        XCTAssertTrue(directories.contains(root.path + "/.npm-global/bin"))
    }

    func testNodeBasedCLIRejectsOldRuntimeAndUsesCompatibleRuntime() async throws {
        let root = try temporaryDirectory()
        let cli = root.appendingPathComponent("prefix/bin/portless")
        let package = root.appendingPathComponent("prefix/lib/node_modules/portless")
        let script = package.appendingPathComponent("dist/cli.js")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data(#"{"name":"portless","engines":{"node":">=24"}}"#.utf8).write(to: package.appendingPathComponent("package.json"))
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: script)
        for (folder, major) in [("prefix/bin", 18), ("compatible", 24)] {
            let node = root.appendingPathComponent(folder + "/node")
            try FileManager.default.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo v\(major).0.0; else echo runtime-\(major); fi\n".utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        }
        let command = ProxyCommand(environment: ["PORTLESSBAR_CLI": cli.path, "PATH": root.path + "/compatible"], homeDirectory: root.path)
        let result = try await command.run(["proxy", "start"], directory: root.path)
        XCTAssertEqual(result.output, "runtime-24\n")
        try Data(#"{"name":"portless","engines":{"node":">=999"}}"#.utf8).write(to: package.appendingPathComponent("package.json"))
        let unavailable = await command.installationIssue()
        XCTAssertTrue(try XCTUnwrap(unavailable).contains("Node.js 999 or newer"))
    }

    func testAdministratorWatchdogTerminatesHungCLIWithoutPrompt() async throws {
        let bundled = Bundle(for: RecoveryTests.self).resourceURL?.appendingPathComponent("TestTools/node").path
        guard let node = ProcessInfo.processInfo.environment["PORTLESS_TEST_NODE"] ?? bundled,
              FileManager.default.isExecutableFile(atPath: node) else { throw XCTSkip("Prepare live test tools to test the Node watchdog.") }
        let start = Date()
        let result = try await Commands.execute(executable: node, arguments: ["-e", ProxyCommand.administratorWatchdog, "--", "0.1", "/bin/sleep", "10"], environment: ProcessInfo.processInfo.environment, timeout: 5)
        XCTAssertEqual(result.status, 124)
        XCTAssertTrue(result.output.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    @MainActor
    func testConfigurationWriteFailureIsReportedAsSaveFailure() async throws {
        let root = try temporaryDirectory()
        let storage = root.appendingPathComponent("app")
        let store = ServerStore(stateDirectory: root.path, storageDirectory: storage, monitor: false)
        // Occupy the destination with a directory to reliably fail atomic writes,
        // including when the test runner has permission to bypass mode bits.
        try FileManager.default.createDirectory(at: storage.appendingPathComponent("proxy.json"), withIntermediateDirectories: true)
        try Data("\(getpid())".utf8).write(to: root.appendingPathComponent("proxy.pid"))
        // An ephemeral local socket makes the snapshot observe an active proxy.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        try Data("\(UInt16(bigEndian: address.sin_port))".utf8).write(to: root.appendingPathComponent("proxy.port"))
        await store.refresh()
        XCTAssertTrue(store.error?.contains("Could not save the proxy configuration") == true)
    }
}
