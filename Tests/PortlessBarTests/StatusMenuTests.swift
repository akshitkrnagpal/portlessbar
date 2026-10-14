import AppKit
import XCTest
@testable import PortlessBar

final class StatusMenuTests: XCTestCase {
    @MainActor
    private func store(command: ProxyCommand = ProxyCommand()) -> ServerStore {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ServerStore(stateDirectory: root.path, storageDirectory: root, command: command, monitor: false)
    }

    @MainActor
    func testProxySwitchReflectsRequestedStateAndFailure() async throws {
        let store = store(command: ProxyCommand(executable: ["/bin/sh", "-c", "sleep 0.3; echo 'fixture failed'; exit 1"]))
        let controller = StatusMenuController(store: store)
        XCTAssertEqual(controller.header.toggle.state, .off)
        controller.header.toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.header.toggle.action), to: controller.header.toggle.target, from: controller.header.toggle))
        let deadline = Date().addingTimeInterval(2)
        while !store.transitioning && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(store.transitioning)
        XCTAssertEqual(controller.header.toggle.state, .on)
        XCTAssertFalse(controller.header.toggle.isEnabled)
        while store.transitioning && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(controller.header.toggle.state, .off)
        XCTAssertEqual(store.error, "fixture failed")
        store.proxyRunning = true
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(controller.header.toggle.state, .on)
    }

    @MainActor
    func testMissingInstallationDisablesLifecycleAndOffersSettings() {
        let store = store()
        store.installationIssue = "Install the Portless CLI"
        let controller = StatusMenuController(store: store)
        XCTAssertFalse(controller.header.toggle.isEnabled)
        XCTAssertFalse(controller.menu.items.first { $0.title == "Portless setup…" }!.isHidden)
        XCTAssertTrue(controller.menu.items.first { $0.title == "Portless settings…" }!.isEnabled)
    }

    @MainActor
    func testUnsupportedNetworkModeKeepsLifecycleAvailable() {
        let store = store()
        store.proxyRunning = true
        store.supportsLAN = false
        let controller = StatusMenuController(store: store)
        XCTAssertTrue(controller.header.toggle.isEnabled)
        XCTAssertEqual(controller.header.toggle.state, .on)
        XCTAssertFalse(controller.menu.items.first { $0.title == "Network mode setup…" }!.isHidden)
    }

    @MainActor
    func testRouteRowsUpdateWhileMenuIsOpen() async throws {
        let store = store()
        let root = URL(fileURLWithPath: store.stateDirectory)
        let file = root.appendingPathComponent("routes.json")
        try JSONEncoder().encode([Route(hostname: "old.localhost", port: 3000, pid: 0)]).write(to: file)
        await store.refresh()
        let controller = StatusMenuController(store: store)
        controller.menuWillOpen(controller.menu)
        try await Task.sleep(for: .milliseconds(50))
        try JSONEncoder().encode([Route(hostname: "new.localhost", port: 3001, pid: 0)]).write(to: file)
        await store.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.menu.items.compactMap { $0.representedObject as? String }, ["new.localhost"])
        controller.menuDidClose(controller.menu)
        XCTAssertEqual(store.pollingInterval, .seconds(15))
    }

    @MainActor
    func testMenuHasLeftAlignedWordmarkAndSeparateSettingsActions() throws {
        let store = store()
        store.routes = [Route(hostname: "web.localhost", port: 4000, pid: 0), Route(hostname: "api.localhost", port: 4001, pid: 0)]
        var openedSettings = false
        var openedPortlessSettings = false
        let controller = StatusMenuController(store: store, openSettings: { openedSettings = true },
                                              openPortlessSettings: { openedPortlessSettings = true })
        XCTAssertEqual(controller.menu.items.compactMap(\.view), [controller.header])
        controller.header.frame.size.width = 400
        controller.header.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.header.title.frame.minX, 14, accuracy: 1)
        let rows = controller.menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(rows.map(\.title), ["api.localhost", "web.localhost"])
        XCTAssertEqual(controller.menu.index(of: rows[0]), 4)
        XCTAssertEqual(controller.menu.items.filter(\.isSectionHeader).map(\.title), ["On this device"])
        XCTAssertFalse(controller.menu.showsStateColumn)
        XCTAssertTrue(rows.allSatisfy { $0.action != nil && $0.submenu == nil && $0.view == nil })
        XCTAssertEqual(controller.menu.items[1].title, "Portless settings…")
        XCTAssertFalse(controller.menu.items.contains { $0.title == "Portless" || $0.title == "Start Portless" || $0.title == "Stop Portless" })
        let portless = try XCTUnwrap(controller.menu.items.first { $0.title == "Portless settings…" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(portless.action), to: portless.target, from: portless))
        XCTAssertTrue(openedPortlessSettings)
        XCTAssertFalse(openedSettings)
        let settings = try XCTUnwrap(controller.menu.items.first { $0.title == "PortlessBar settings…" })
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertTrue(openedSettings)
    }
}
