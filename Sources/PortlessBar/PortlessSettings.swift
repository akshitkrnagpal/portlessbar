import AppKit
import Darwin
import SwiftUI

struct PortlessSettingsDraft: Equatable {
    var port: String
    var tls: Bool
    var lan: Bool
    var ip: String
    var domains: String
    var wildcard: Bool
    var certificate: String
    var privateKey: String
    private var preservedExtras: [String]

    init(_ configuration: ProxyConfiguration) {
        port = String(configuration.port)
        tls = configuration.tls
        lan = configuration.lan
        ip = ""
        domains = ""
        wildcard = false
        certificate = ""
        privateKey = ""
        preservedExtras = []
        let tokens = ProxyConfiguration.reconnectExtras(configuration.extras)
        var tlds: [String] = []
        var cursor = 0
        while cursor < tokens.count {
            let flag = tokens[cursor]
            if ["--ip", "--tld", "--cert", "--key", "--lan-ip-auto"].contains(flag), tokens.indices.contains(cursor + 1) {
                let value = tokens[cursor + 1]
                switch flag {
                case "--ip": ip = value
                case "--tld": if value != "local" { tlds.append(value) }
                case "--cert": certificate = value
                case "--key": privateKey = value
                default: break // A detected address should stay automatic.
                }
                cursor += 2
            } else {
                if flag == "--wildcard" { wildcard = true }
                else if flag != "--lan" { preservedExtras.append(flag) }
                cursor += 1
            }
        }
        domains = tlds.isEmpty ? "localhost" : tlds.joined(separator: ", ")
    }

    func configuration() throws -> ProxyConfiguration {
        guard let number = Int(port), (1...65535).contains(number) else {
            throw PortlessError.message("Enter a port between 1 and 65535.")
        }
        var extras = preservedExtras
        if lan {
            extras.append("--lan")
            let address = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty {
                var ipv4 = in_addr()
                var ipv6 = in6_addr()
                guard inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 else {
                    throw PortlessError.message("Enter a valid LAN IP address, or leave it blank for automatic detection.")
                }
                extras += ["--ip", address]
            }
        } else {
            let names = domains.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard !names.isEmpty, names.allSatisfy({ name in
                name != "local" && name.utf8.count <= 253 && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                    !$0.isEmpty && $0.utf8.count <= 63 && $0.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
                }
            }) else { throw PortlessError.message("Enter domains separated by commas, such as localhost, test, or dev.example.com. Use Network mode for .local.") }
            var seen = Set<String>()
            for name in names where seen.insert(name).inserted { extras += ["--tld", name] }
        }
        if wildcard { extras.append("--wildcard") }
        if tls {
            let cert = certificate.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cert.isEmpty == key.isEmpty else { throw PortlessError.message("Choose both a certificate and its private key, or leave both blank for Portless’s local CA.") }
            for (flag, path) in [("--cert", cert), ("--key", key)] where !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                var directory: ObjCBool = false
                guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &directory),
                      !directory.boolValue, FileManager.default.isReadableFile(atPath: expanded) else {
                    throw PortlessError.message("Choose a readable file for \(flag).")
                }
                extras += [flag, expanded]
            }
        }
        return ProxyConfiguration(port: number, tls: tls, extras: extras,
                                  environmentOverrides: ["PORTLESS_WILDCARD": wildcard ? "1" : "0"])
    }
}

@MainActor
final class PortlessSettingsWindowController: NSWindowController {
    private let store: ServerStore

    init(store: ServerStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Portless settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 480, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PortlessBarProxySettings")
        super.init(window: window)
        if !window.setFrameUsingName("PortlessBarProxySettings") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        // Reopening an already visible window preserves unsaved edits.
        if window?.isVisible != true {
            let frame = window?.frame
            window?.contentViewController = NSHostingController(rootView: PortlessSettingsView(store: store, close: { [weak self] in self?.close() }))
            if let frame { window?.setFrame(frame, display: false) }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct PortlessSettingsView: View {
    @ObservedObject var store: ServerStore
    @State private var draft: PortlessSettingsDraft
    @State private var validationError: String?
    @State private var advanced = false
    private let close: () -> Void

    init(store: ServerStore, close: @escaping () -> Void) {
        self.store = store
        self.close = close
        _draft = State(initialValue: PortlessSettingsDraft(store.editableConfiguration))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Portless settings")
                .font(.system(size: 14, weight: .semibold))
                .frame(height: 46).frame(maxWidth: .infinity)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("Connection") {
                            row("Available on", help: "--lan · This device uses loopback; Network uses .local over mDNS.") {
                                Picker("Available on", selection: $draft.lan) {
                                    Text("This device").tag(false)
                                    Text("Network").tag(true)
                                }.labelsHidden().pickerStyle(.segmented).frame(width: 220, alignment: .trailing)
                                    .disabled(store.supportsLAN == false)
                            }
                            Divider()
                            row("HTTPS", help: "--https / --no-tls") {
                                Toggle("HTTPS", isOn: $draft.tls).labelsHidden().toggleStyle(.switch)
                                    .onChange(of: draft.tls) { old, enabled in
                                        if draft.port == (old ? "443" : "80") { draft.port = enabled ? "443" : "80" }
                                    }
                            }
                            Divider()
                            row("Proxy port", help: "-p / --port · Ports below 1024 may require administrator approval.") {
                                TextField("443", text: $draft.port).frame(width: 90)
                            }
                            if draft.lan {
                                Divider()
                                row("LAN IP address", help: "--ip · Blank follows network changes automatically.") {
                                    TextField("Automatic", text: $draft.ip).frame(width: 220)
                                }
                            }
                        }
                        section("Routing") {
                            if !draft.lan {
                                row("Domains", help: "--tld · Separate multiple domains with commas.") {
                                    TextField("localhost, test", text: $draft.domains).frame(width: 220)
                                }
                                Divider()
                            }
                            row("Wildcard subdomains", help: "--wildcard · Unregistered subdomains fall back to the parent app.") {
                                Toggle("Wildcard subdomains", isOn: $draft.wildcard).labelsHidden().toggleStyle(.switch)
                            }
                        }
                        Text(draft.lan ? "Apps use .local on your network. Restart your apps after changing modes to update their URLs."
                             : "Apps use these domains on this Mac. The first domain is used for app URLs.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12)
                        if store.supportsLAN == false {
                            Text("Update Portless to use Network mode.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12)
                        }
                        DisclosureGroup("Advanced", isExpanded: $advanced) {
                            VStack(alignment: .leading, spacing: 14) {
                                section("TLS certificate") {
                                    fileRow("Certificate", value: $draft.certificate, help: "--cert")
                                    Divider()
                                    fileRow("Private key", value: $draft.privateKey, help: "--key")
                                }.disabled(!draft.tls)
                                Text("Leave both blank to use Portless’s local CA.").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text("Portless runs in the background here. Use --foreground in Terminal for debugging. --state-dir applies to service install; this app uses the state directory below.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(store.stateDirectory).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Link("All Portless commands and flags ↗", destination: URL(string: "https://portless.sh/commands")!)
                                    .font(.system(size: 12))
                            }.padding(.top, 10)
                        }.font(.system(size: 12, weight: .medium))
                            .id("advanced")
                    }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
                }
                .onChange(of: advanced) { _, expanded in
                    guard expanded else { return }
                    // Wait for the expanded content to lay out before targeting it.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scroll.scrollTo("advanced", anchor: .top)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message = validationError ?? store.error ?? store.installationIssue {
                    Text(message).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Text(store.proxyRunning ? "Saving restarts Portless." : "Applied next time you start Portless.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button(store.proxyRunning ? "Save & Restart" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.transitioning || store.installationIssue != nil)
                }
            }.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
        .controlSize(.small)
        .disabled(store.transitioning)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.leading, 12)
            VStack(spacing: 0, content: content)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row<Control: View>(_ title: String, help: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            control()
        }.padding(.horizontal, 12).padding(.vertical, 10).help(help)
    }

    private func fileRow(_ title: String, value: Binding<String>, help: String) -> some View {
        row(title, help: help) {
            TextField("Portless default", text: value).frame(width: 170)
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
            } label: { Image(systemName: "folder") }.help("Choose \(title.lowercased()) file")
        }
    }

    private func save() {
        do {
            let configuration = try draft.configuration()
            validationError = nil
            Task { if await store.applyConfiguration(configuration) { close() } }
        } catch { validationError = error.localizedDescription }
    }
}
