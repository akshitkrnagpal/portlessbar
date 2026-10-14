import AppKit
import XCTest
@testable import PortlessBar

private actor ProbeGate {
    private var continuations: [String: CheckedContinuation<NearbyRoute?, Never>] = [:]
    private(set) var calls = 0

    func run(_ endpoint: BonjourEndpoint) async -> NearbyRoute? {
        calls += 1
        return await withCheckedContinuation { continuations[endpoint.hostname] = $0 }
    }

    func finish(_ endpoint: BonjourEndpoint) {
        continuations.removeValue(forKey: endpoint.hostname)?.resume(returning:
            NearbyRoute(url: endpoint.url(scheme: "https")!, address: endpoint.addresses[0]))
    }

    func finishAll() {
        let waiting = continuations.values
        continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: nil) }
    }
}

final class NearbyDiscoveryTests: XCTestCase {
    private func endpoint(_ name: String = "web.local", port: Int = 1355, address: String = "192.168.1.165") -> BonjourEndpoint {
        BonjourEndpoint(hostname: name, port: port, addresses: [address])!
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out waiting for discovery", file: file, line: line)
    }

    func testEndpointUsesAdvertisedHostAndProxyPort() throws {
        let remote = try XCTUnwrap(BonjourEndpoint(hostname: "API.Web.LOCAL.", port: 1355, addresses: ["192.168.1.165"]))
        XCTAssertEqual(remote.url(scheme: "https")?.absoluteString, "https://api.web.local:1355")
        XCTAssertEqual(endpoint(port: 443).url(scheme: "https")?.absoluteString, "https://web.local")
        XCTAssertEqual(endpoint(port: 80).url(scheme: "http")?.absoluteString, "http://web.local")
        XCTAssertNil(BonjourEndpoint(hostname: "web.localhost", port: 1355, addresses: ["192.168.1.165"]))
        XCTAssertNil(BonjourEndpoint(hostname: "web.local", port: 0, addresses: ["192.168.1.165"]))
        XCTAssertNil(BonjourEndpoint(hostname: "web.local", port: 1355, addresses: []))
    }

    func testPortlessHeaderMustComeFromSuccessfulProbe() {
        XCTAssertTrue(NearbyProbe.identifiesPortless(CommandResult(status: 0, output: "HTTP/2 404\r\nX-Portless: 1\r\n")))
        XCTAssertFalse(NearbyProbe.identifiesPortless(CommandResult(status: 0, output: "HTTP/1.1 200 OK\r\nServer: router\r\n")))
        XCTAssertFalse(NearbyProbe.identifiesPortless(CommandResult(status: 0, output: "X-Portless: 10\r\n")))
        XCTAssertFalse(NearbyProbe.identifiesPortless(CommandResult(status: 7, output: "X-Portless: 1\r\n")))
    }

    func testSchemeProbeFallsBackToHTTPAndPinsAdvertisedAddress() async throws {
        let endpoint = endpoint(port: 8080)
        let route = await NearbyProbe.find(endpoint, run: { arguments in
            XCTAssertTrue(arguments.contains("web.local:8080:192.168.1.165"))
            XCTAssertTrue(arguments.contains("Host: portlessbar-discovery.invalid"))
            XCTAssertFalse(arguments.contains("--location"), "Discovery must not follow redirects to unrelated hosts.")
            return arguments.last!.hasPrefix("https:") ? CommandResult(status: 35, output: "TLS failed")
                : CommandResult(status: 0, output: "HTTP/1.1 404 Not Found\r\nx-portless: 1\r\n")
        })
        XCTAssertEqual(route?.url.absoluteString, "http://web.local:8080")
        XCTAssertEqual(route?.address, "192.168.1.165")
        let router = await NearbyProbe.find(endpoint, run: { _ in CommandResult(status: 0, output: "Server: router\r\n") })
        XCTAssertNil(router)
    }

    @MainActor
    func testOwnMachineAdvertisementsAreExcludedWithoutHidingSameNamedRemoteApps() async throws {
        let discovery = NearbyDiscovery(enabled: false, probe: { endpoint in
            NearbyRoute(url: endpoint.url(scheme: "https")!, address: endpoint.addresses[0])
        }, localAddresses: { ["192.168.1.95"] })
        defer { discovery.stop() }
        discovery.update(endpoint(address: "192.168.1.95"), for: "local")
        discovery.update(endpoint(address: "127.0.0.1"), for: "loopback")
        discovery.update(endpoint(address: "::1"), for: "ipv6-loopback")
        discovery.update(endpoint(), for: "remote")
        try await waitUntil { discovery.routes.count == 1 }
        XCTAssertEqual(discovery.routes[0].address, "192.168.1.165")
        discovery.update(endpoint(), for: "same-service-other-interface")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(discovery.routes.count, 1, "Identical URLs and addresses should appear only once.")
        discovery.remove("remote")
        XCTAssertEqual(discovery.routes.count, 1, "Another advertisement still owns this route.")
        discovery.remove("same-service-other-interface")
        XCTAssertTrue(discovery.routes.isEmpty)
    }

    @MainActor
    func testRemovedServiceCannotReappearFromAnInFlightProbe() async throws {
        let gate = ProbeGate()
        let discovery = NearbyDiscovery(enabled: false, probe: { await gate.run($0) }, localAddresses: { [] })
        defer { discovery.stop() }
        let remote = endpoint()
        discovery.update(remote, for: "service")
        try await waitUntil { await gate.calls == 1 }
        discovery.remove("service")
        await gate.finish(remote)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(discovery.routes.isEmpty)
    }

    @MainActor
    func testChangedEndpointDiscardsTheOldProbe() async throws {
        let gate = ProbeGate()
        let discovery = NearbyDiscovery(enabled: false, probe: { await gate.run($0) }, localAddresses: { [] })
        defer { discovery.stop() }
        let old = endpoint()
        let new = endpoint(port: 8443, address: "192.168.1.166")
        discovery.update(old, for: "service")
        try await waitUntil { await gate.calls == 1 }
        discovery.update(new, for: "service")
        await gate.finish(old)
        try await waitUntil { await gate.calls == 2 }
        XCTAssertTrue(discovery.routes.isEmpty)
        await gate.finish(new)
        try await waitUntil { discovery.routes.first?.address == "192.168.1.166" }
        XCTAssertEqual(discovery.routes.first?.url.port, 8443)
    }

    @MainActor
    func testVerificationConcurrencyIsBounded() async throws {
        let gate = ProbeGate()
        let discovery = NearbyDiscovery(enabled: false, probe: { await gate.run($0) }, localAddresses: { [] })
        let endpoints = (0..<6).map { endpoint("app\($0).local") }
        for endpoint in endpoints { discovery.update(endpoint, for: endpoint.hostname) }
        try await waitUntil { await gate.calls == 4 }
        try await Task.sleep(for: .milliseconds(25))
        let calls = await gate.calls
        XCTAssertEqual(calls, 4)
        await gate.finish(endpoints[0])
        try await waitUntil { await gate.calls == 5 }
        discovery.stop()
        await gate.finishAll()
    }

    @MainActor
    func testNearbyMenuRowsStayAvailableWhenLocalProxyIsOff() async throws {
        _ = NSApplication.shared
        let discovery = NearbyDiscovery(enabled: false, probe: { endpoint in
            NearbyRoute(url: endpoint.url(scheme: "https")!, address: endpoint.addresses[0])
        }, localAddresses: { [] })
        defer { discovery.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root, monitor: false, nearby: discovery)
        store.routes = [Route(hostname: "local.localhost", port: 4000)]
        let controller = StatusMenuController(store: store)
        discovery.update(endpoint(), for: "remote")
        try await waitUntil { controller.menu.items.contains { $0.representedObject is NearbyRoute } }
        XCTAssertFalse(store.proxyRunning)
        XCTAssertFalse(store.lanMode)
        let row = try XCTUnwrap(controller.menu.items.first { $0.representedObject is NearbyRoute })
        XCTAssertEqual(row.title, "web.local:1355")
        XCTAssertEqual((row.representedObject as? NearbyRoute)?.url.absoluteString, "https://web.local:1355")
        XCTAssertTrue(row.isEnabled)
        XCTAssertNotNil(row.action)
        XCTAssertTrue(controller.menu.items.contains { $0.title == "Nearby apps" })
        XCTAssertLessThan(controller.menu.items.firstIndex { $0.title == "local.localhost" }!, controller.menu.index(of: row))
        store.routes = []
        try await waitUntil { controller.menu.items.contains { $0.title == "No local servers registered" } }
        XCTAssertTrue(controller.menu.items.contains { $0 === row })
        discovery.remove("remote")
        try await waitUntil { !controller.menu.items.contains { $0.representedObject is NearbyRoute } }
        XCTAssertFalse(controller.menu.items.contains { $0.title == "Nearby apps" })
    }

    @MainActor
    func testLiveBonjourDiscovery() async throws {
        guard ProcessInfo.processInfo.environment["PORTLESS_TEST_BONJOUR"] == "1" else {
            throw XCTSkip("Set PORTLESS_TEST_BONJOUR=1 on a network with a remote Portless LAN proxy")
        }
        let discovery = NearbyDiscovery()
        defer { discovery.stop() }
        let deadline = Date().addingTimeInterval(12)
        while discovery.routes.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(discovery.error)
        XCTAssertFalse(discovery.routes.isEmpty)
        for route in discovery.routes { print("Discovered \(route.url.absoluteString) at \(route.address)") }
    }
}
