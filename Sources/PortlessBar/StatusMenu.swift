import AppKit
import Combine

enum PortlessWordmark {
    static let text = "portlessbar"
    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

@MainActor
final class ProxyHeader: NSView {
    let title = NSTextField(labelWithString: PortlessWordmark.text)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 44))
        autoresizingMask = [.width]
        title.font = PortlessWordmark.font(size: NSFont.menuFont(ofSize: 0).pointSize + 3)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Native proxy controls and URL rows, with one entry point to settings.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let header = ProxyHeader()
    let proxyItem = NSMenuItem(title: "Start portless", action: nil, keyEquivalent: "")
    private let store: ServerStore
    private let openSettings: () -> Void
    private let openPortlessSettings: () -> Void
    private var subscription: AnyCancellable?
    private var errorItem: NSMenuItem!
    private let emptyItem = NSMenuItem(title: "No servers registered", action: nil, keyEquivalent: "")
    private let routesEnd = NSMenuItem.separator()
    private var serverItems: [NSMenuItem] = []
    private var displayedLocal: [String]?
    private var displayedNearby: [NearbyRoute]?

    init(store: ServerStore, openSettings: @escaping () -> Void = {}, openPortlessSettings: @escaping () -> Void = {}) {
        self.store = store
        self.openSettings = openSettings
        self.openPortlessSettings = openPortlessSettings
        super.init()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.delegate = self
        proxyItem.target = self
        proxyItem.action = #selector(toggleProxy)
        rebuild()
        subscription = Publishers.Merge(store.objectWillChange, store.nearby.objectWillChange).sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.updateState() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        store.setMenuOpen(true)
        store.nearby.refresh()
        Task { await store.refreshInstallation(force: true); await store.refresh() }
    }
    func menuDidClose(_ menu: NSMenu) { store.setMenuOpen(false) }

    private func item(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        return item
    }

    private func rebuild() {
        menu.removeAllItems()
        serverItems = []
        displayedLocal = nil
        displayedNearby = nil
        let logo = NSMenuItem()
        logo.view = header
        menu.addItem(logo)
        menu.addItem(proxyItem)
        menu.addItem(item("Portless settings…", action: #selector(showPortlessSettings)))
        menu.addItem(.separator())
        menu.addItem(routesEnd)
        errorItem = item("Portless Error…", action: #selector(showError))
        menu.addItem(errorItem)
        menu.addItem(item("PortlessBar settings…", action: #selector(showSettings), key: ","))
        menu.addItem(item("Quit PortlessBar", action: #selector(quit), key: "q"))
        updateState()
    }

    private func updateRoutes() {
        let names = Set(store.routes.map(\.hostname)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let nearby = store.nearby.routes
        guard names != displayedLocal || nearby != displayedNearby else { return }
        let localRows = Dictionary(uniqueKeysWithValues: serverItems.compactMap { row in
            (row.representedObject as? String).map { ($0, row) }
        })
        let networkRows = Dictionary(uniqueKeysWithValues: serverItems.compactMap { row in
            (row.representedObject as? NearbyRoute).map { ($0, row) }
        })
        for row in serverItems { menu.removeItem(row) }
        serverItems = []
        displayedLocal = names
        displayedNearby = nearby

        if !names.isEmpty {
            serverItems.append(.sectionHeader(title: "On this device"))
            for name in names {
                let row = localRows[name] ?? item(name, action: #selector(openServer(_:)))
                row.representedObject = name
                row.toolTip = "Open in browser"
                serverItems.append(row)
            }
        }
        if !nearby.isEmpty {
            if !serverItems.isEmpty { serverItems.append(.separator()) }
            serverItems.append(.sectionHeader(title: "On this network"))
            for route in nearby {
                let row = networkRows[route] ?? item(route.title, action: #selector(openNearbyServer(_:)))
                row.representedObject = route
                row.toolTip = "\(route.url.absoluteString)\n\(route.address)"
                serverItems.append(row)
            }
        }
        if serverItems.isEmpty {
            emptyItem.isEnabled = false
            serverItems = [emptyItem]
        }
        for row in serverItems { menu.insertItem(row, at: menu.index(of: routesEnd)) }
    }

    private func updateState() {
        proxyItem.title = store.transitioning
            ? (store.proxyToggleOn ? "Starting portless…" : "Stopping portless…")
            : (store.proxyRunning ? "Stop portless" : "Start portless")
        proxyItem.isEnabled = !store.transitioning && store.installationIssue == nil
        errorItem?.title = store.installationIssue != nil ? "Portless setup…" : store.supportsLAN == false ? "Network mode setup…" : "Portless Error…"
        errorItem?.isHidden = store.error == nil && store.installationIssue == nil && store.supportsLAN != false && store.nearby.error == nil
        updateRoutes()
        menu.update()
    }

    @objc private func toggleProxy() {
        let enabled = !store.proxyRunning
        Task { await store.setProxyRunning(enabled) }
    }
    @objc private func showPortlessSettings() { openPortlessSettings() }
    @objc private func openServer(_ item: NSMenuItem) {
        if let hostname = item.representedObject as? String { store.open(hostname) }
    }
    @objc private func openNearbyServer(_ item: NSMenuItem) {
        if let route = item.representedObject as? NearbyRoute { NSWorkspace.shared.open(route.url) }
    }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showError() {
        guard let message = store.error ?? store.installationIssue ?? store.nearby.error ?? (store.supportsLAN == false ? ServerStore.unsupportedLANMessage : nil) else { return }
        let alert = NSAlert()
        alert.messageText = "Portless needs attention"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if store.installationIssue != nil || store.supportsLAN == false { alert.addButton(withTitle: "Installation guide") }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/vercel-labs/portless#install")!)
        }
        store.error = nil
        updateState()
    }
}
