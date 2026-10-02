import XCTest
import Darwin
@testable import PortlessBar

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

    func testReconnectKeepsEqualsValuesAndFutureFlags() {
        let args = ["--port=1355", "--https", "--foreground", "--state-dir", "/tmp/state",
                    "--tld=dev", "--tld", "test", "--cert=/tmp/cert", "--key", "/tmp/key",
                    "--ip=192.168.1.8", "--wildcard", "--future=value", "--future-pair", "value"]
        XCTAssertEqual(ProxyConfiguration.reconnectExtras(args),
                       ["--tld", "dev", "--tld", "test", "--cert", "/tmp/cert", "--key", "/tmp/key",
                        "--ip", "192.168.1.8", "--wildcard", "--future=value", "--future-pair", "value"])
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
