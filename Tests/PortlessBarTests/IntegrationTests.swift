import XCTest
import Darwin
import AppKit
import Combine
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

    func testPackageMetadataRecognizesArbitraryLayoutsAndRejectsUnrelatedScripts() throws {
        let root = try temporaryDirectory()
        let package = root.appendingPathComponent("arbitrary-storage-" + UUID().uuidString)
        let script = package.appendingPathComponent("nested/tools/entry.mjs")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: script)
        let metadata = package.appendingPathComponent("package.json")
        try Data(#"{"name":"portless","bin":{"portless":"./nested/tools/entry.mjs"}}"#.utf8).write(to: metadata)
        XCTAssertEqual(Integration.portlessScript(script.path), script)
        XCTAssertTrue(Integration.isPortlessProxy(["bun", script.path, "proxy", "start"]))
        XCTAssertFalse(Integration.isPortlessProxy(["node", script.path, "myapp", "proxy", "start"]))
        XCTAssertFalse(Integration.isPortlessProxy(Integration.arguments(pid: getpid())))
        try Data(#"{"name":"portless","bin":"./nested/tools/entry.mjs"}"#.utf8).write(to: metadata)
        XCTAssertEqual(Integration.portlessScript(script.path), script)
        let unrelated = script.deletingLastPathComponent().appendingPathComponent("unrelated.js")
        try Data().write(to: unrelated)
        XCTAssertNil(Integration.portlessScript(unrelated.path))
        try Data(#"{"name":"other-package","bin":"./nested/tools/entry.mjs"}"#.utf8).write(to: metadata)
        XCTAssertNil(Integration.portlessScript(script.path))
        // A familiar folder name alone must not identify an unrelated package.
        let familiar = root.appendingPathComponent("portless/dist/cli.js")
        try FileManager.default.createDirectory(at: familiar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: familiar)
        XCTAssertNil(Integration.portlessScript(familiar.path))
        try FileManager.default.removeItem(at: script)
        XCTAssertNil(Integration.portlessScript(script.path))
    }

    func testProxyInspectionAcceptsInstalledCLISymlink() throws {
        let root = try temporaryDirectory()
        let cli = root.appendingPathComponent("node_modules/portless/dist/cli.js")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: cli)
        try Data(#"{"name":"portless","bin":{"portless":"./dist/cli.js"}}"#.utf8)
            .write(to: cli.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json"))
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

    private func httpFixture(host: String = "127.0.0.1", header: String = "", redirect: String = "", replacingPID: URL? = nil, replaceListener: Bool = false) async throws -> (process: Process, port: Int) {
        let (_, node) = try liveTools()
        let port = try unusedPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", """
        const [port,host,header,redirect,pidFile,replaceListener]=process.argv.slice(1);
        const http=require('http');
        const server=http.createServer((req,res)=>{
            if(pidFile) require('fs').writeFileSync(pidFile,'999999999');
            if(header) res.setHeader('X-Portless',header);
            if(redirect) {res.statusCode=302;res.setHeader('Location',redirect);}
            if(replaceListener==='1') {
                server.close();
                http.createServer((req,res)=>res.end()).listen(Number(port),host,()=>res.end());
            } else {res.end();}
        });
        server.listen(Number(port),host);
        """, String(port), host, header, redirect, replacingPID?.path ?? "", replaceListener ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while pb_listener(process.processIdentifier, Int32(port), host == "::1" ? 1 : 0) == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(pb_listener(process.processIdentifier, Int32(port), host == "::1" ? 1 : 0), 0)
        return (process, port)
    }

    private func writeProxyState(_ directory: URL, pid: Int32, port: Int) throws {
        try Data(String(pid).utf8).write(to: directory.appendingPathComponent("proxy.pid"))
        try Data(String(port).utf8).write(to: directory.appendingPathComponent("proxy.port"))
    }

    func testProxyVerificationRejectsOrdinaryHTTPAndWrongHeader() async throws {
        let state = try temporaryDirectory()
        for header in ["", "0", "11"] {
            let fixture = try await httpFixture(header: header)
            try writeProxyState(state, pid: fixture.process.processIdentifier, port: fixture.port)
            let verified = await Integration.verifyProxy(pid: fixture.process.processIdentifier, directory: state.path)
            XCTAssertFalse(verified)
        }
    }

    func testProxyVerificationRequiresPIDToOwnTheRespondingSocket() async throws {
        let state = try temporaryDirectory()
        let ordinary = try await httpFixture()
        let portless = try await httpFixture(header: "1")
        try writeProxyState(state, pid: ordinary.process.processIdentifier, port: portless.port)
        let wrongOwner = await Integration.verifyProxy(pid: ordinary.process.processIdentifier, directory: state.path)
        XCTAssertFalse(wrongOwner, "A Portless response on another process's port cannot validate the saved PID.")
        let wrongPID = await Integration.verifyProxy(pid: portless.process.processIdentifier, directory: state.path)
        XCTAssertFalse(wrongPID, "The requested PID must match the state directory.")
        try writeProxyState(state, pid: portless.process.processIdentifier, port: portless.port)
        let valid = await Integration.verifyProxy(pid: portless.process.processIdentifier, directory: state.path)
        XCTAssertTrue(valid)
    }

    func testProxyVerificationSupportsIPv6AndDoesNotFollowRedirects() async throws {
        let state = try temporaryDirectory()
        let portless = try await httpFixture(host: "::1", header: "1")
        try writeProxyState(state, pid: portless.process.processIdentifier, port: portless.port)
        let ipv6 = await Integration.verifyProxy(pid: portless.process.processIdentifier, directory: state.path)
        XCTAssertTrue(ipv6)
        let redirect = try await httpFixture(redirect: "http://[::1]:\(portless.port)/")
        try writeProxyState(state, pid: redirect.process.processIdentifier, port: redirect.port)
        let redirected = await Integration.verifyProxy(pid: redirect.process.processIdentifier, directory: state.path)
        XCTAssertFalse(redirected)
    }

    func testProxyVerificationRejectsStateChangesDuringTheProbe() async throws {
        let state = try temporaryDirectory()
        let fixture = try await httpFixture(header: "1", replacingPID: state.appendingPathComponent("proxy.pid"))
        try writeProxyState(state, pid: fixture.process.processIdentifier, port: fixture.port)
        let verified = await Integration.verifyProxy(pid: fixture.process.processIdentifier, directory: state.path)
        XCTAssertFalse(verified)
    }

    func testProxyVerificationRejectsListenerReplacementDuringTheProbe() async throws {
        let state = try temporaryDirectory()
        let fixture = try await httpFixture(header: "1", replaceListener: true)
        try writeProxyState(state, pid: fixture.process.processIdentifier, port: fixture.port)
        let verified = await Integration.verifyProxy(pid: fixture.process.processIdentifier, directory: state.path)
        XCTAssertFalse(verified, "The same PID and port must still refer to the listener that was probed.")
    }

    @MainActor
    func testLiveProxySurvivesRemovalOfFNMShellAlias() async throws {
        try await checkLiveProxySurvivesRemovalOfAlias("fnm_multishells/old-shell/bin")
    }

    @MainActor
    func testLiveProxySurvivesRemovalOfBunAlias() async throws {
        try await checkLiveProxySurvivesRemovalOfAlias(".bun/bin")
    }

    @MainActor
    func testLiveProxySurvivesRemovalOfArbitraryAlias() async throws {
        try await checkLiveProxySurvivesRemovalOfAlias("custom-layout-" + UUID().uuidString + "/commands")
    }

    @MainActor
    func testLiveTLSProxySurvivesRemovalOfItsPackageAndAlias() async throws {
        try await checkLiveProxySurvivesRemovalOfAlias("custom-layout-" + UUID().uuidString + "/commands", removePackage: true)
    }

    @MainActor
    private func checkLiveProxySurvivesRemovalOfAlias(_ aliasDirectory: String, removePackage: Bool = false) async throws {
        let (cli, node) = try liveTools()
        let root = try temporaryDirectory()
        let state = root.appendingPathComponent("state")
        let bin = root.appendingPathComponent("installation/bin")
        let shell = root.appendingPathComponent(aliasDirectory)
        for directory in [state, bin, shell] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let runtime = bin.appendingPathComponent("runtime-" + UUID().uuidString)
        try FileManager.default.copyItem(atPath: node, toPath: runtime.path)
        // The installed CLI is deliberately outside the runtime directory.
        let stable = root.appendingPathComponent("available-cli")
        let alias = shell.appendingPathComponent("arbitrary-cli-name")
        try FileManager.default.createSymbolicLink(atPath: stable.path, withDestinationPath: cli)
        let package = root.appendingPathComponent("removed-package-" + UUID().uuidString)
        if removePackage {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: cli).deletingLastPathComponent().deletingLastPathComponent(), to: package)
        }
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: removePackage ? package.appendingPathComponent("dist/cli.js").path : cli)
        var environment = ProcessInfo.processInfo.environment
        environment["PORTLESS_STATE_DIR"] = state.path
        environment["PORTLESS_SYNC_HOSTS"] = "0"
        environment["PORTLESS_LAN"] = "0"
        environment["PORTLESS_LAN_IP"] = ""
        let port = try unusedPort()
        let started = try await Commands.execute(executable: runtime.path,
                                                arguments: [alias.path, "proxy", "start"] + (removePackage ? ["--https", "--skip-trust"] : ["--no-tls"]) + ["--tld", "test", "-p", String(port)], environment: environment)
        XCTAssertEqual(started.status, 0, started.output)
        defer {
            if let text = try? String(contentsOfFile: state.path + "/proxy.pid", encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { kill(pid, SIGTERM) }
        }
        let pid = try XCTUnwrap(Snapshot.read(directory: state.path).proxyPID)
        try FileManager.default.removeItem(at: shell.deletingLastPathComponent())
        if removePackage { try FileManager.default.removeItem(at: package) }
        let identity = await Integration.verifyProxy(pid: pid, directory: state.path)
        XCTAssertTrue(identity)
        XCTAssertTrue(try XCTUnwrap(ProxyConfiguration.read(directory: state.path, pid: pid)).extras.contains("test"), "Reconnect options must survive a missing CLI.")
        let verifier = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL!
            : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/debug/PortlessBar")
        let verified = try await Commands.execute(executable: verifier.path, arguments: ["--verify-portless-proxy", String(pid), state.path], environment: environment)
        XCTAssertEqual(verified.status, 0, verified.output)
        let rejected = try await Commands.execute(executable: verifier.path, arguments: ["--verify-portless-proxy", String(getpid()), state.path], environment: environment)
        XCTAssertEqual(rejected.status, 1, "The administrator verifier must reject unrelated processes.")
        let command = ProxyCommand(executable: [node, stable.path], environment: environment)
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
        await store.setProxyRunning(true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.proxyRunning)
        await store.setProxyRunning(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.proxyRunning)
    }

    @MainActor
    func testLiveLANSwitchPreservesMainToggleAndRemembersDisconnectedMode() async throws {
        _ = NSApplication.shared
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
        let controller = StatusMenuController(store: store)
        func flushMenuUpdates() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        var toggleStates: [NSControl.StateValue] = []
        var lanSelections: [Int] = []
        let observation = store.objectWillChange.sink {
            // Combine does not promise subscriber order. A second queue turn
            // observes after the menu's queued update, as a user sees it.
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    if store.switchingLAN {
                        toggleStates.append(controller.header.toggle.state)
                        lanSelections.append(controller.lan.selector.selectedSegment)
                    }
                }
            }
        }
        defer { observation.cancel() }
        let marker = state.appendingPathComponent("proxy.lan").path
        await store.setProxyRunning(true)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        await flushMenuUpdates()
        toggleStates.removeAll()
        lanSelections.removeAll()
        await store.setLANMode(true)
        // LAN mode needs a LAN address and mDNS publishing, which build machines may lack.
        guard store.lanMode else { throw XCTSkip("LAN mode is unavailable here: \(store.error ?? "no error")") }
        XCTAssertNil(store.error)
        XCTAssertTrue(store.proxyRunning)
        XCTAssertFalse(toggleStates.isEmpty)
        XCTAssertTrue(toggleStates.allSatisfy { $0 == .on }, "Changing the mode must keep an enabled main toggle on throughout the restart.")
        XCTAssertTrue(lanSelections.allSatisfy { $0 == 1 }, "The selector must keep the requested Network position throughout the restart.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        await flushMenuUpdates()
        toggleStates.removeAll()
        lanSelections.removeAll()
        await store.setLANMode(false)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.lanMode)
        XCTAssertTrue(store.proxyRunning)
        XCTAssertTrue(toggleStates.allSatisfy { $0 == .on }, "Returning to local mode must also keep the main toggle on.")
        XCTAssertTrue(lanSelections.allSatisfy { $0 == 0 }, "The selector must keep the requested This Mac position throughout the restart.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        await store.setProxyRunning(false)
        await flushMenuUpdates()
        toggleStates.removeAll()
        await store.setLANMode(true)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.proxyRunning, "Changing the mode must not connect a disconnected proxy.")
        XCTAssertTrue(toggleStates.allSatisfy { $0 == .off })
        await flushMenuUpdates()
        XCTAssertEqual(controller.header.toggle.state, .off)
        await store.setProxyRunning(true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.lanMode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        await store.setProxyRunning(false)
        await store.setLANMode(false)
        await flushMenuUpdates()
        XCTAssertEqual(controller.header.toggle.state, .off)
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
