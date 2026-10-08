import XCTest
import Darwin
import PortlessSystem
@testable import PortlessBar

final class IntegrationTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PortlessBarTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func unusedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PortlessError.message("Could not create test socket") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw PortlessError.message("Could not reserve test port") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard result == 0 else { throw PortlessError.message("Could not read test port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    func testProxyURLsRespectTLSAndCustomPort() throws {
        let state = try temporaryDirectory()
        try Data("1355".utf8).write(to: state.appendingPathComponent("proxy.port"))
        XCTAssertEqual(Integration.url(hostname: "api.example.test", directory: state.path)?.absoluteString, "http://api.example.test:1355")
        try Data().write(to: state.appendingPathComponent("proxy.tls"))
        XCTAssertEqual(Integration.url(hostname: "api.example.test", directory: state.path)?.absoluteString, "https://api.example.test:1355")
        try Data("443".utf8).write(to: state.appendingPathComponent("proxy.port"))
        XCTAssertEqual(Integration.url(hostname: "api.example.test", directory: state.path)?.absoluteString, "https://api.example.test")
        try FileManager.default.removeItem(at: state.appendingPathComponent("proxy.port"))
        try FileManager.default.removeItem(at: state.appendingPathComponent("proxy.tls"))
        XCTAssertEqual(Integration.url(hostname: "api.example.test", directory: state.path, fallback: ProxyConfiguration(port: 1355, tls: true))?.absoluteString, "https://api.example.test:1355")
    }

    func testMalformedRegistryFailsWithoutChangingFile() throws {
        let state = try temporaryDirectory()
        let file = state.appendingPathComponent("routes.json")
        let malformed = Data("[{broken JSON".utf8)
        try malformed.write(to: file)
        XCTAssertThrowsError(try Integration.readRoutes(directory: state.path))
        XCTAssertEqual(try Data(contentsOf: file), malformed)
    }

    func testProxyInspectionRejectsAppsAndUnrelatedProcesses() {
        XCTAssertFalse(Integration.isPortlessProxy(Integration.arguments(pid: getpid())))
        XCTAssertFalse(Integration.isPortlessProxy(["node", "/usr/local/lib/node_modules/portless/dist/cli.js", "myapp", "npm", "run", "dev"]))
        XCTAssertFalse(Integration.isPortlessProxy(["node", "/usr/local/lib/node_modules/portless/dist/cli.js", "myapp", "proxy", "start"]))
        XCTAssertTrue(Integration.isPortlessProxy(["node", "/usr/local/lib/node_modules/portless/dist/cli.js", "proxy", "start", "--foreground"]))
    }

    func testVersionedPackageAndExpiredFNMAliases() throws {
        let root = try temporaryDirectory()
        let package = root.appendingPathComponent("cache/portless@0.15.6")
        let script = package.appendingPathComponent("dist/cli.js")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)
        try Data(#"{"name":"portless","bin":{"portless":"./dist/cli.js"}}"#.utf8)
            .write(to: package.appendingPathComponent("package.json"))
        XCTAssertTrue(Integration.isPortlessProxy(["bun", script.path, "proxy", "start"]))
        let runtime = root.appendingPathComponent("installation/bin/node")
        try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: runtime)
        try FileManager.default.createSymbolicLink(at: runtime.deletingLastPathComponent().appendingPathComponent("portless"), withDestinationURL: script)
        let expired = root.appendingPathComponent("fnm_multishells/old-shell/bin/portless")
        XCTAssertTrue(Integration.isPortlessProxy([runtime.path, expired.path, "proxy", "start"]))
        XCTAssertFalse(Integration.isPortlessProxy([runtime.path, root.appendingPathComponent("unknown/bin/portless").path, "proxy", "start"]))
        // A still-existing alias to an unrelated script must not fall back to the runtime's CLI.
        try FileManager.default.createDirectory(at: expired.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: expired)
        XCTAssertFalse(Integration.isPortlessProxy([runtime.path, expired.path, "proxy", "start"]))
        try Data(#"{"name":"other-package","bin":{"portless":"./dist/cli.js"}}"#.utf8)
            .write(to: package.appendingPathComponent("package.json"))
        XCTAssertFalse(Integration.isPortlessProxy(["bun", script.path, "proxy", "start"]))
    }

    func testProxyInspectionAcceptsInstalledCLISymlink() throws {
        let root = try temporaryDirectory()
        let cli = root.appendingPathComponent("node_modules/portless/dist/cli.js")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: cli)
        let link = root.appendingPathComponent("bin/portless")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        XCTAssertTrue(Integration.isPortlessProxy(["node", link.path, "proxy", "start", "--foreground"]))
        XCTAssertFalse(Integration.isPortlessProxy(["node", link.path, "myapp", "npm", "run", "dev"]))
        let unrelated = root.appendingPathComponent("unrelated.js")
        try Data().write(to: unrelated)
        let unrelatedLink = root.appendingPathComponent("other/portless")
        try FileManager.default.createDirectory(at: unrelatedLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unrelatedLink, withDestinationURL: unrelated)
        XCTAssertFalse(Integration.isPortlessProxy(["node", unrelatedLink.path, "proxy", "start"]))
    }

    @MainActor
    func testRemovedRoutesDisappearWithoutAHistoryCatalog() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("routes.json")
        try JSONEncoder().encode([Route(hostname: "web.localhost", port: 4999, pid: 0)]).write(to: file)
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"), monitor: false)
        await store.refresh()
        XCTAssertEqual(store.routes.map(\.hostname), ["web.localhost"])
        try Data("[]".utf8).write(to: file)
        await store.refresh()
        XCTAssertTrue(store.routes.isEmpty)
    }

    private func liveTools() throws -> (cli: String, node: String) {
        let tools = Bundle(for: IntegrationTests.self).resourceURL?.appendingPathComponent("TestTools")
        let bundledNode = tools?.appendingPathComponent("node").path
        let bundledCLI = tools?.appendingPathComponent("portless/dist/cli.js").path
        let hasBundledTools = bundledNode.map { FileManager.default.isExecutableFile(atPath: $0) } == true
            && bundledCLI.map { FileManager.default.fileExists(atPath: $0) } == true
        guard let cli = hasBundledTools ? bundledCLI : ProcessInfo.processInfo.environment["PORTLESS_TEST_CLI"],
              let node = hasBundledTools ? bundledNode : ProcessInfo.processInfo.environment["PORTLESS_TEST_NODE"] else {
            throw XCTSkip("Set PORTLESS_TEST_CLI and PORTLESS_TEST_NODE to run the live proxy test.")
        }
        return (cli, node)
    }

    @MainActor
    func testLiveProxySurvivesRemovalOfFNMShellAlias() async throws {
        let (cli, node) = try liveTools()
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        let bin = root.appendingPathComponent("installation/bin")
        let shell = root.appendingPathComponent("fnm_multishells/old-shell/bin")
        for directory in [state, bin, shell] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let runtime = bin.appendingPathComponent("node")
        try FileManager.default.copyItem(atPath: node, toPath: runtime.path)
        let stable = bin.appendingPathComponent("portless")
        let alias = shell.appendingPathComponent("portless")
        for link in [stable, alias] { try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: cli) }
        var environment = ProcessInfo.processInfo.environment
        environment["PORTLESS_STATE_DIR"] = state.path
        environment["PORTLESS_SYNC_HOSTS"] = "0"
        environment["PORTLESS_LAN"] = "0"
        environment["PORTLESS_LAN_IP"] = ""
        let port = try unusedPort()
        let started = try await Commands.execute(executable: runtime.path,
                                                arguments: [alias.path, "proxy", "start", "--no-tls", "-p", String(port)], environment: environment)
        XCTAssertEqual(started.status, 0, started.output)
        defer {
            if let text = try? String(contentsOfFile: state.path + "/proxy.pid", encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { kill(pid, SIGTERM) }
        }
        let pid = try XCTUnwrap(Snapshot.read(directory: state.path).proxyPID)
        try FileManager.default.removeItem(at: shell.deletingLastPathComponent())
        XCTAssertTrue(Integration.isPortlessProxy(Integration.arguments(pid: pid)))
        let verifier = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL!
            : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/PortlessBar")
        let verified = try await Commands.execute(executable: verifier.path, arguments: ["--verify-portless-proxy", String(pid)], environment: environment)
        XCTAssertEqual(verified.status, 0, verified.output)
        let rejected = try await Commands.execute(executable: verifier.path, arguments: ["--verify-portless-proxy", String(getpid())], environment: environment)
        XCTAssertEqual(rejected.status, 1, "The administrator verifier must reject unrelated processes.")
        let command = ProxyCommand(executable: [runtime.path, stable.path], environment: environment)
        let store = ServerStore(stateDirectory: state.path, storageDirectory: root.appendingPathComponent("app"), command: command,
                                monitor: false, servicePlist: root.appendingPathComponent("missing.plist"))
        await store.setLANMode(true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.lanMode)
        await store.setLANMode(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        await store.setProxyRunning(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.proxyRunning)
    }

    @MainActor
    func testLiveLANSwitchRestartsProxyAndRemembersModeWhileDisconnected() async throws {
        let (cli, node) = try liveTools()
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer {
            if let text = try? String(contentsOfFile: state.path + "/proxy.pid", encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { kill(pid, SIGTERM) }
        }
        let installedCLI = root.appendingPathComponent("bin/portless")
        try FileManager.default.createDirectory(at: installedCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installedCLI, withDestinationURL: URL(fileURLWithPath: cli))
        var command = ProxyCommand(executable: [node, installedCLI.path])
        command.environment["PORTLESS_HTTPS"] = "0"
        command.environment["PORTLESS_PORT"] = String(try unusedPort())
        command.environment["PORTLESS_SYNC_HOSTS"] = "0"
        for name in ["PORTLESS_LAN", "PORTLESS_LAN_IP", "PORTLESS_TLD"] { command.environment.removeValue(forKey: name) }
        let store = ServerStore(stateDirectory: state.path, storageDirectory: root.appendingPathComponent("app"), command: command,
                                monitor: false, servicePlist: root.appendingPathComponent("missing.plist"))
        let marker = state.appendingPathComponent("proxy.lan").path
        await store.setProxyRunning(true)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        await store.setLANMode(true)
        // LAN mode needs a LAN address and mDNS publishing, which build machines may lack.
        guard store.lanMode else { throw XCTSkip("LAN mode is unavailable here: \(store.error ?? "no error")") }
        XCTAssertNil(store.error)
        XCTAssertTrue(store.proxyRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        await store.setLANMode(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        XCTAssertTrue(store.proxyRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        await store.setProxyRunning(false)
        await store.setLANMode(true)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.proxyRunning, "Changing the mode must not connect a disconnected proxy.")
        await store.setProxyRunning(true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.lanMode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        await store.setProxyRunning(false)
        await store.setLANMode(false)
        await store.setProxyRunning(true)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        await store.setProxyRunning(false)
        XCTAssertFalse(store.proxyRunning)
    }

    @MainActor
    func testLiveProxyToggleKeepsAppsRunningAndRestoresConfiguration() async throws {
        let (cli, node) = try liveTools()
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let fixturePort = try unusedPort()
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: node)
        fixture.arguments = ["-e", "require('http').createServer((req,res)=>res.end('PortlessBar test')).listen(\(fixturePort),'127.0.0.1');"]
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate() }
            if let text = try? String(contentsOfFile: state.path + "/proxy.pid", encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { kill(pid, SIGTERM) }
        }
        let deadline = Date().addingTimeInterval(5)
        while pb_listening(Int32(fixturePort)) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(pb_listening(Int32(fixturePort)), 1)
        let proxyPort = try unusedPort()
        let route = Route(hostname: "portlessbar-test.localhost", port: fixturePort, pid: fixture.processIdentifier)
        try JSONEncoder().encode([route]).write(to: state.appendingPathComponent("routes.json"))
        let installedCLI = root.appendingPathComponent("bin/portless")
        try FileManager.default.createDirectory(at: installedCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installedCLI, withDestinationURL: URL(fileURLWithPath: cli))
        var command = ProxyCommand(executable: [node, installedCLI.path])
        command.environment["PORTLESS_HTTPS"] = "0"
        command.environment["PORTLESS_PORT"] = String(proxyPort)
        command.environment["PORTLESS_SYNC_HOSTS"] = "0"
        let storage = root.appendingPathComponent("app")
        let store = ServerStore(stateDirectory: state.path, storageDirectory: storage, command: command, monitor: false)
        await store.setProxyRunning(true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.proxyRunning)
        XCTAssertEqual(Integration.url(hostname: route.hostname, directory: state.path)?.absoluteString, "http://portlessbar-test.localhost:\(proxyPort)")
        let response = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(proxyPort)")!)
        XCTAssertNotNil(response.1 as? HTTPURLResponse)
        await store.setProxyRunning(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.proxyRunning)
        XCTAssertTrue(fixture.isRunning, "Turning off the proxy must not terminate development servers.")
        XCTAssertEqual(pb_listening(Int32(fixturePort)), 1)
        XCTAssertEqual(store.routes, [route])
        command.environment.removeValue(forKey: "PORTLESS_PORT")
        command.environment.removeValue(forKey: "PORTLESS_HTTPS")
        let reopened = ServerStore(stateDirectory: state.path, storageDirectory: storage, command: command, monitor: false)
        await reopened.setProxyRunning(true)
        XCTAssertNil(reopened.error)
        XCTAssertTrue(reopened.proxyRunning)
        XCTAssertEqual(ProxyConfiguration.read(directory: state.path, pid: nil)?.port, proxyPort)
        XCTAssertEqual(ProxyConfiguration.read(directory: state.path, pid: nil)?.tls, false)
        await reopened.setProxyRunning(false)
        XCTAssertFalse(reopened.proxyRunning)
    }
}
