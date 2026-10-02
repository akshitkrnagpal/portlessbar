import XCTest
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
        var command = ProxyCommand(environment: ["PORTLESSBAR_CLI": "/usr/bin/printf"])
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
}
