import AppKit
import SwiftUI

struct SettingsLink: Identifiable, Sendable {
    let title: String
    let detail: String
    enum Icon: Sendable {
        case github, x, email
        var image: Image {
            switch self {
            case .github: Self.asset("GitHubMark")
            case .x: Self.asset("XMark")
            case .email: Image(systemName: "envelope")
            }
        }
        private static func asset(_ name: String) -> Image {
            guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
                  let image = NSImage(contentsOf: url) else { return Image(systemName: "link") }
            return Image(nsImage: image)
        }
    }
    let icon: Icon
    let url: URL
    var id: String { title }

    static let links = [
        SettingsLink(title: "GitHub", detail: "akshitkrnagpal/portlessbar", icon: .github,
                  url: URL(string: "https://github.com/akshitkrnagpal/portlessbar")!),
        SettingsLink(title: "X", detail: "@akshit_io", icon: .x,
                  url: URL(string: "https://x.com/akshit_io")!),
        SettingsLink(title: "Email", detail: "hello@akshit.io", icon: .email,
                  url: URL(string: "mailto:hello@akshit.io")!)
    ]
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let login: LoginItemStore

    init(login: LoginItemStore = LoginItemStore()) {
        self.login = login
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 550),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "PortlessBarSettings")
        window.titlebarSeparatorStyle = .none
        window.toolbar = toolbar
        window.minSize = NSSize(width: 520, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PortlessBarSettings")
        window.contentViewController = NSHostingController(rootView: SettingsView(login: login))
        window.setContentSize(NSSize(width: 600, height: 550))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        login.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowDidBecomeKey(_ notification: Notification) { login.refresh() }
}

struct SettingsView: View {
    @ObservedObject var login: LoginItemStore

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
                .frame(height: 48)
                .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identity
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("General")
                        general
                    }
                    links
                    Text("Independent companion for Vercel’s Portless · Apache 2.0")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .tint(.gray)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
        .alert("Could not change Launch at Login", isPresented: Binding(
            get: { login.error != nil }, set: { if !$0 { login.error = nil } }
        )) {
            Button("OK", role: .cancel) { login.error = nil }
        } message: { Text(login.error ?? "") }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).padding(.leading, 18)
    }

    private var general: some View {
        HStack {
            Text("Launch at Login")
                .font(.system(size: 14))
            Spacer()
            Toggle("Launch at Login", isOn: Binding(
                get: { login.enabled },
                set: { value in Task { await login.setEnabled(value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(login.changing)
            .help("Open PortlessBar automatically when you log in")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var identity: some View {
        VStack(spacing: 8) {
            Text(PortlessWordmark.text).font(Font(PortlessWordmark.font(size: 26)))
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.primary.opacity(0.06), in: Capsule())
            Text("Portless in your macOS menu bar.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Links")
            VStack(spacing: 0) {
                ForEach(Array(SettingsLink.links.enumerated()), id: \.element.id) { index, link in
                    if index > 0 { Divider().padding(.horizontal, 18) }
                    Button {
                        NSWorkspace.shared.open(link.url)
                    } label: {
                        HStack(spacing: 12) {
                            link.icon.image
                                .renderingMode(.template)
                                .resizable().scaledToFit()
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(link.title)
                            Spacer(minLength: 12)
                            Text(link.detail).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 18).padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(link.url.absoluteString)
                }
            }
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var version: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return "Version \(value)"
        }
        return "Development build"
    }
}
