import XCTest
@testable import PortlessBar

final class PortlessSettingsTests: XCTestCase {
    func testDraftKeepsUnknownOptionsAndRoundTripsEditableFlags() throws {
        let original = ProxyConfiguration(port: 1355, tls: false,
                                          extras: ["--tld=dev.example.com", "--tld", "test", "--wildcard", "--future", "value"])
        var draft = PortlessSettingsDraft(original)
        XCTAssertEqual(draft.domains, "dev.example.com, test")
        draft.wildcard = false
        let saved = try draft.configuration()
        XCTAssertEqual(saved.startArguments, ["proxy", "start", "-p", "1355", "--no-tls", "--future", "value", "--tld", "dev.example.com", "--tld", "test"])
        XCTAssertEqual(saved.startEnvironment["PORTLESS_WILDCARD"], "0")
        draft.lan = true
        draft.ip = "192.168.1.42"
        XCTAssertEqual(try draft.configuration().extras, ["--future", "value", "--lan", "--ip", "192.168.1.42"])
    }

    func testDomainsAreCheckedAgainstInstalledCLICompatibility() {
        XCTAssertThrowsError(try ProxyCommand.validateDomains(["dev.example.com"], version: "0.15.3"))
        XCTAssertThrowsError(try ProxyCommand.validateDomains(["localhost", "test"], version: "0.15.0"))
        XCTAssertNoThrow(try ProxyCommand.validateDomains(["localhost", "test"], version: "0.15.3"))
        XCTAssertNoThrow(try ProxyCommand.validateDomains(["dev.example.com", "test"], version: "0.15.5"))
    }

    func testInvalidInputIsRejectedBeforeLifecycleChanges() throws {
        var draft = PortlessSettingsDraft(ProxyConfiguration(port: 443, tls: true))
        for value in ["0", "65536", "abc"] {
            draft.port = value
            XCTAssertThrowsError(try draft.configuration())
        }
        draft.port = "1355"
        for value in ["", "test,", "bad/path", "-test", "local", "a..test"] {
            draft.domains = value
            XCTAssertThrowsError(try draft.configuration(), value)
        }
        draft.domains = "localhost"
        draft.certificate = "/does/not/exist.pem"
        XCTAssertThrowsError(try draft.configuration())
        draft.certificate = ""
        draft.lan = true
        draft.ip = "not an IP"
        XCTAssertThrowsError(try draft.configuration())
        draft.ip = ""
        XCTAssertNoThrow(try draft.configuration())
    }

    @MainActor
    func testSavingWhileStoppedPersistsWithoutRunningCLIAndOverridesStaleState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A stopped proxy can leave its previous port behind.
        try Data("1234".utf8).write(to: root.appendingPathComponent("proxy.port"))
        let log = root.appendingPathComponent("invoked")
        let command = ProxyCommand(executable: ["/bin/sh", "-c", "echo \"$*\" > " + Integration.quote(log.path) + "; echo 'fixture'; exit 1", "portless"])
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"), command: command, monitor: false)
        let target = try PortlessSettingsDraft(ProxyConfiguration(port: 5678, tls: false)).configuration()
        let saved = await store.applyConfiguration(target)
        XCTAssertTrue(saved)
        XCTAssertFalse(store.proxyRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        let fresh = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"), command: command, monitor: false)
        XCTAssertEqual(fresh.editableConfiguration, target)
        await fresh.setProxyRunning(true)
        let arguments = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(arguments.contains("-p 5678 --no-tls"), arguments)
        XCTAssertFalse(arguments.contains("1234"), arguments)
    }

    func testServiceReinstallUsesAllEditedSettingsAndRetainsInstalledRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("node")
        let cli = root.appendingPathComponent("cli.js")
        try FileManager.default.createSymbolicLink(atPath: runtime.path, withDestinationPath: "/usr/bin/true")
        try Data().write(to: cli)
        let plist = root.appendingPathComponent("service.plist")
        let service: [String: Any] = ["ProgramArguments": [runtime.path, cli.path, "proxy", "start", "--foreground", "-p", "443", "--https"],
                                     "EnvironmentVariables": ["PORTLESS_STATE_DIR": root.path, "PORTLESS_SYNC_HOSTS": "0"]]
        try PropertyListSerialization.data(fromPropertyList: service, format: .xml, options: 0).write(to: plist)
        let target = try PortlessSettingsDraft(ProxyConfiguration(port: 5678, tls: false, extras: ["--tld", "test", "--wildcard"])).configuration()
        let install = try XCTUnwrap(ProxyConfiguration.serviceInstall(plist: plist, directory: root.path, lan: false, target: target))
        XCTAssertEqual(install.executable, [runtime.path, cli.path])
        XCTAssertEqual(install.arguments, ["service", "install", "-p", "5678", "--no-tls", "--tld", "test", "--wildcard", "--state-dir", root.path])
        XCTAssertEqual(install.environment["PORTLESS_SYNC_HOSTS"], "0")
    }
}
