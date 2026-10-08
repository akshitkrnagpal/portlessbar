import AppKit
import XCTest
@testable import PortlessBar

final class StatusMenuTests: XCTestCase {
    @MainActor
    func testNetworkSelectionVisiblyFadesAndSettles() async throws {
        _ = NSApplication.shared
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("Reduce Motion is enabled") }
        let row = LANModeSelector()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 270, height: 50),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = row
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        row.setNetwork(false)
        // Native controls select the clicked segment before delivering their action.
        row.selector.selectedSegment = 1
        row.setNetwork(true)
        XCTAssertEqual(row.selector.selectedSegment, 1)
        let previousRendering = try XCTUnwrap(row.subviews.compactMap { $0 as? NSImageView }.first)
        try await Task.sleep(for: .milliseconds(80))
        let opacity = try XCTUnwrap(previousRendering.layer?.presentation()?.opacity)
        XCTAssertGreaterThan(opacity, 0, "The previous selection should still be partially visible mid-transition.")
        XCTAssertLessThan(opacity, 1, "The selection should fade instead of jumping between positions.")
        row.setNetwork(true) // A polling update must leave the animation in progress.
        XCTAssertTrue(previousRendering.superview === row)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(previousRendering.superview)
        XCTAssertEqual(row.selector.selectedSegment, 1)
    }

    @MainActor
    func testProxyClickKeepsRequestedPositionUntilTheCommandFinishes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = ProxyCommand(executable: ["/bin/sh", "-c", "sleep 0.3; echo 'fixture failed'; exit 1"])
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root, command: command, monitor: false)
        let controller = StatusMenuController(store: store)
        controller.header.toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(controller.header.toggle.action), to: controller.header.toggle.target, from: controller.header.toggle))
        let deadline = Date().addingTimeInterval(2)
        while !store.transitioning && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(store.transitioning)
        XCTAssertFalse(store.proxyRunning)
        XCTAssertEqual(controller.header.toggle.state, .on, "Polling must not undo the clicked position while connecting.")
        while store.transitioning && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertFalse(store.transitioning)
        XCTAssertEqual(controller.header.toggle.state, .off, "A failed command must restore the observed state.")
        XCTAssertEqual(store.error, "fixture failed")
    }

    @MainActor
    func testMissingInstallationDisablesControlsAndOffersSetup() {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root, monitor: false)
        store.installationIssue = "Install the Portless CLI"
        let controller = StatusMenuController(store: store)
        XCTAssertEqual(controller.header.status.stringValue, "Portless unavailable")
        XCTAssertFalse(controller.header.toggle.isEnabled)
        XCTAssertFalse(controller.lan.selector.isEnabled)
        XCTAssertEqual(controller.lan.status.stringValue, "Set up Portless first")
        XCTAssertFalse(controller.menu.items.first { $0.title == "Portless setup…" }!.isHidden)
        XCTAssertTrue(controller.menu.items.first { $0.title == "Settings…" }!.isEnabled)
    }

    @MainActor
    func testUnsupportedNetworkModeKeepsProxyControlsAvailable() {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root, monitor: false)
        store.proxyRunning = true
        store.supportsLAN = false
        let controller = StatusMenuController(store: store)
        XCTAssertTrue(controller.header.toggle.isEnabled)
        XCTAssertFalse(controller.lan.selector.isEnabled)
        XCTAssertEqual(controller.lan.status.stringValue, "Update Portless for Network")
        XCTAssertFalse(controller.menu.items.first { $0.title == "Network mode setup…" }!.isHidden)
    }

    @MainActor
    func testRouteRowsUpdateWhileMenuIsOpen() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("routes.json")
        try JSONEncoder().encode([Route(hostname: "old.localhost", port: 3000, pid: 0)]).write(to: file)
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root.appendingPathComponent("app"), monitor: false)
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
    func testControlRowsAccommodateLargerFontsAndWideMenus() {
        let header = ProxyHeader()
        let defaultHeaderHeight = header.frame.height
        header.title.font = PortlessWordmark.font(size: 28)
        header.status.font = .menuFont(ofSize: 24)
        header.resizeToFit()
        header.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(header.frame.height, defaultHeaderHeight)
        XCTAssertLessThanOrEqual(header.title.frame.maxX, header.toggle.frame.minX)
        XCTAssertLessThanOrEqual(header.status.frame.maxY, header.bounds.maxY - 8)
        XCTAssertGreaterThanOrEqual(header.toggle.frame.minY, 8)
        XCTAssertLessThanOrEqual(header.toggle.frame.maxY, header.bounds.maxY - 8)
        header.frame.size.width = 600
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.toggle.frame.maxX, 588, accuracy: 1)

        let lan = LANModeSelector()
        let defaultLANHeight = lan.frame.height
        lan.status.font = .menuFont(ofSize: 24)
        lan.status.stringValue = "Restart apps to update URLs"
        lan.resizeToFit()
        lan.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(lan.frame.height, defaultLANHeight)
        XCTAssertLessThanOrEqual(lan.status.frame.maxX, lan.bounds.maxX)
        XCTAssertLessThanOrEqual(lan.status.frame.maxY, lan.bounds.maxY - 8)
        lan.frame.size.width = 600
        lan.layoutSubtreeIfNeeded()
        XCTAssertEqual(lan.selector.frame.maxX, 588, accuracy: 1)
    }

    @MainActor
    func testMenuHasOneProxyToggleAndOnlyDirectURLActions() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root, monitor: false)
        store.routes = [Route(hostname: "web.localhost", port: 4000, pid: 0), Route(hostname: "api.localhost", port: 4001, pid: 0)]
        store.proxyRunning = true
        var openedSettings = false
        let controller = StatusMenuController(store: store, openSettings: { openedSettings = true })
        XCTAssertEqual(controller.header.toggle.state, .on)
        XCTAssertEqual(controller.header.status.stringValue, "Connected")
        let rows = controller.menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(rows.map(\.title), ["api.localhost", "web.localhost"])
        XCTAssertFalse(controller.menu.showsStateColumn)
        XCTAssertTrue(rows.allSatisfy { $0.state == .off })
        XCTAssertTrue(rows.allSatisfy { $0.action != nil && $0.submenu == nil && $0.view == nil })
        XCTAssertTrue(controller.menu.items.allSatisfy { $0.submenu == nil })
        XCTAssertEqual(controller.menu.items.compactMap(\.view), [controller.header, controller.lan])
        XCTAssertFalse(controller.menu.items.contains { ["Launch at Login", "GitHub", "Support"].contains($0.title) || $0.title.contains("Start Server") || $0.title.contains("Stop Server") })
        XCTAssertFalse(controller.menu.items.contains { $0.title.contains("Made with") })
        let settings = try XCTUnwrap(controller.menu.items.first { $0.title == "Settings…" })
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertTrue(openedSettings)
    }

    @MainActor
    func testLANRowReflectsModeAndStaleRoutes() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ServerStore(stateDirectory: root.path, storageDirectory: root, monitor: false)
        func row(lan: Bool, hostname: String) -> LANModeSelector {
            store.proxyRunning = true
            store.lanMode = lan
            store.routes = [Route(hostname: hostname, port: 4000, pid: 0)]
            return StatusMenuController(store: store).lan
        }
        let off = row(lan: false, hostname: "web.localhost")
        XCTAssertEqual(off.selector.label(forSegment: 0), "This Mac")
        XCTAssertEqual(off.selector.label(forSegment: 1), "Network")
        XCTAssertEqual(off.selector.trackingMode, .selectOne)
        XCTAssertEqual(off.selector.accessibilityLabel(), "LAN mode")
        XCTAssertEqual(off.selector.selectedSegment, 0)
        XCTAssertEqual(off.status.stringValue, "This Mac only")
        let on = row(lan: true, hostname: "web.local")
        XCTAssertEqual(on.selector.selectedSegment, 1)
        XCTAssertEqual(on.status.stringValue, "Reachable on your network")
        XCTAssertEqual(row(lan: true, hostname: "web.localhost").status.stringValue, "Restart apps to update URLs")
        XCTAssertEqual(row(lan: false, hostname: "web.local").status.stringValue, "Restart apps to update URLs")
        store.proxyRunning = true
        store.transitioning = true
        store.switchingLAN = true
        let controller = StatusMenuController(store: store)
        XCTAssertEqual(controller.lan.status.stringValue, "Switching…")
        XCTAssertEqual(controller.header.status.stringValue, "Connected")
        XCTAssertFalse(controller.lan.selector.isEnabled)
        XCTAssertFalse(controller.header.toggle.isEnabled)
        XCTAssertEqual(controller.menu.items.firstIndex { $0.representedObject is String }, 3)
    }
}
