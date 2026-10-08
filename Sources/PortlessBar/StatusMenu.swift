import AppKit
import Combine
import QuartzCore

enum PortlessWordmark {
    static let text = "portlessbar"
    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

@MainActor
final class ProxyHeader: NSView {
    let title: NSTextField
    let status = NSTextField(labelWithString: "Disconnected")
    let toggle = NSSwitch()

    init(title text: String = PortlessWordmark.text, font: NSFont? = nil, label: String = "Portless proxy") {
        title = NSTextField(labelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 50))
        autoresizingMask = [.width]
        let menuSize = NSFont.menuFont(ofSize: 0).pointSize
        title.font = font ?? PortlessWordmark.font(size: menuSize + 1)
        // Native rows without a checkmark column start their text at 16pt.
        // Label cells add 2pt of their own inset to this frame.
        status.font = .menuFont(ofSize: max(11, menuSize - 1))
        status.textColor = .secondaryLabelColor
        toggle.setAccessibilityLabel(label)
        for view in [title, status, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            status.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12)
        ])
        resizeToFit()
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(270, max(title.intrinsicContentSize.width, status.intrinsicContentSize.width) + toggle.intrinsicContentSize.width + 38),
               height: max(50, title.intrinsicContentSize.height + status.intrinsicContentSize.height + 19,
                           toggle.intrinsicContentSize.height + 16))
    }
    func resizeToFit() {
        invalidateIntrinsicContentSize()
        frame.size = NSSize(width: max(frame.width, intrinsicContentSize.width), height: intrinsicContentSize.height)
    }
    func setConnected(_ connected: Bool) {
        let state: NSControl.StateValue = connected ? .on : .off
        // Reassigning a clicked switch's state interrupts its native animation.
        guard toggle.state != state else { return }
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            toggle.state = state
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            toggle.animator().state = state
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class SelectionSnapshot: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class LANModeSelector: NSView {
    let selector = NSSegmentedControl(labels: ["This Mac", "Network"], trackingMode: .selectOne, target: nil, action: nil)
    let status = NSTextField(labelWithString: "This Mac only")
    private var presentedSegment: Int?
    private var selectionOverlay: NSImageView?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 50))
        autoresizingMask = [.width]
        selector.segmentDistribution = .fillEqually
        selector.setAccessibilityLabel("LAN mode")
        status.font = .menuFont(ofSize: max(11, NSFont.menuFont(ofSize: 0).pointSize - 1))
        status.textColor = .secondaryLabelColor
        for view in [selector, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            selector.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            selector.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            selector.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: selector.leadingAnchor),
            status.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 5),
            status.trailingAnchor.constraint(lessThanOrEqualTo: selector.trailingAnchor),
            status.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
        resizeToFit()
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(270, max(selector.intrinsicContentSize.width, status.intrinsicContentSize.width) + 26),
               height: max(50, selector.intrinsicContentSize.height + status.intrinsicContentSize.height + 21))
    }
    func resizeToFit() {
        invalidateIntrinsicContentSize()
        frame.size = NSSize(width: max(frame.width, intrinsicContentSize.width), height: intrinsicContentSize.height)
    }
    func setNetwork(_ network: Bool) {
        let segment = network ? 1 : 0
        let previous = presentedSegment
        presentedSegment = segment
        guard previous != segment else {
            if selector.selectedSegment != segment { selector.selectedSegment = segment }
            return
        }
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
        // AppKit does not animate selectedSegment. Fade the previous native
        // rendering into the new selection, including when a click already
        // changed selectedSegment before the model received the action.
        guard let previous, window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            selector.selectedSegment = segment
            return
        }
        layoutSubtreeIfNeeded()
        selector.selectedSegment = previous
        guard let bitmap = selector.bitmapImageRepForCachingDisplay(in: selector.bounds) else {
            selector.selectedSegment = segment
            return
        }
        selector.cacheDisplay(in: selector.bounds, to: bitmap)
        selector.selectedSegment = segment
        let image = NSImage(size: selector.bounds.size)
        image.addRepresentation(bitmap)
        let overlay = SelectionSnapshot(frame: selector.frame)
        overlay.wantsLayer = true
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.setAccessibilityElement(false)
        addSubview(overlay, positioned: .above, relativeTo: selector)
        selectionOverlay = overlay
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                overlay.removeFromSuperview()
                if self?.selectionOverlay === overlay { self?.selectionOverlay = nil }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Native proxy controls and URL rows, with one entry point to settings.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let header = ProxyHeader()
    let lan = LANModeSelector()
    private let store: ServerStore
    private let openSettings: () -> Void
    private var subscription: AnyCancellable?
    private var errorItem: NSMenuItem!
    private let emptyItem = NSMenuItem(title: "No servers registered", action: nil, keyEquivalent: "")

    init(store: ServerStore, openSettings: @escaping () -> Void = {}) {
        self.store = store
        self.openSettings = openSettings
        super.init()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.delegate = self
        header.toggle.target = self
        header.toggle.action = #selector(toggleProxy(_:))
        lan.selector.target = self
        lan.selector.action = #selector(selectLANMode(_:))
        rebuild()
        subscription = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.updateState() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        store.setMenuOpen(true)
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
        for view in [header, lan] as [NSView] {
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.separator())
        errorItem = item("Portless Error…", action: #selector(showError))
        menu.addItem(errorItem)
        menu.addItem(item("Settings…", action: #selector(showSettings), key: ","))
        menu.addItem(item("Quit PortlessBar", action: #selector(quit), key: "q"))
        updateState()
    }

    private func updateRoutes() {
        let names = Set(store.routes.map(\.hostname)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let rows = menu.items.filter { $0.representedObject is String }
        let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.representedObject as! String, $0) })
        for row in rows where !names.contains(row.title) { menu.removeItem(row) }
        if menu.items.contains(emptyItem), !names.isEmpty { menu.removeItem(emptyItem) }
        for (offset, name) in names.enumerated() {
            let row = existing[name] ?? item(name, action: #selector(openServer(_:)))
            row.representedObject = name
            row.toolTip = "Open in browser"
            let position = offset + 3
            if menu.index(of: row) != position {
                if menu.index(of: row) >= 0 { menu.removeItem(row) }
                menu.insertItem(row, at: position)
            }
        }
        if names.isEmpty, !menu.items.contains(emptyItem) {
            emptyItem.isEnabled = false
            menu.insertItem(emptyItem, at: 3)
        }
    }

    private func updateState() {
        header.setConnected(store.proxyToggleOn)
        header.toggle.isEnabled = !store.transitioning && store.installationIssue == nil
        header.status.stringValue = store.installationIssue != nil ? "Portless unavailable" : store.transitioning && !store.switchingLAN
            ? (store.proxyToggleOn ? "Connecting…" : "Disconnecting…")
            : (store.proxyToggleOn ? "Connected" : "Disconnected")
        lan.setNetwork(store.lanSelectionOn)
        lan.selector.isEnabled = !store.transitioning && store.installationIssue == nil && store.supportsLAN != false && store.canChooseLANMode
        // Running apps keep the hostname they registered with until they restart.
        let stale = store.routes.contains { $0.hostname.hasSuffix(".local") != store.lanMode }
        lan.status.stringValue = store.installationIssue != nil ? "Set up Portless first"
            : store.supportsLAN == false ? "Update Portless for Network"
            : !store.canChooseLANMode ? "Connect the proxy first"
            : store.switchingLAN ? "Switching…"
            : stale ? "Restart apps to update URLs"
            : (store.lanMode ? "Reachable on your network" : "This Mac only")
        errorItem?.title = store.installationIssue != nil ? "Portless setup…" : store.supportsLAN == false ? "Network mode setup…" : "Portless Error…"
        errorItem?.isHidden = store.error == nil && store.installationIssue == nil && store.supportsLAN != false
        updateRoutes()
        header.resizeToFit()
        lan.resizeToFit()
        menu.update()
    }

    @objc private func toggleProxy(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        Task { await store.setProxyRunning(enabled) }
    }
    @objc private func selectLANMode(_ sender: NSSegmentedControl) {
        let enabled = sender.selectedSegment == 1
        Task { await store.setLANMode(enabled) }
    }
    @objc private func openServer(_ item: NSMenuItem) {
        if let hostname = item.representedObject as? String { store.open(hostname) }
    }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showError() {
        guard let message = store.error ?? store.installationIssue ?? (store.supportsLAN == false ? ServerStore.unsupportedLANMessage : nil) else { return }
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
