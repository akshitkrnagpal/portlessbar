import AppKit
import Carbon

@main
enum PortlessBarApp {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--verify-portless-proxy" {
            guard let pid = Int32(arguments[2]), pid > 1,
                  Integration.isPortlessProxy(Integration.arguments(pid: pid)) else { exit(1) }
            exit(0)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ServerStore()
    private let updates = UpdateStore()
    private lazy var settings = SettingsWindowController(updates: updates)
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updates.start()
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "PortlessBar")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PortlessBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = StatusMenuController(store: store, openSettings: { [weak self] in self?.settings.show() })
        statusItem.menu = statusMenu.menu
        if let button = statusItem.button {
            button.title = "p_"
            button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            button.toolTip = "PortlessBar — local servers"
            button.setAccessibilityLabel("PortlessBar servers")
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin && !ProcessInfo.processInfo.arguments.contains("--background") {
            DispatchQueue.main.async { [weak self] in self?.statusItem.button?.performClick(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
    }

    @objc private func showSettings() { settings.show() }
}
