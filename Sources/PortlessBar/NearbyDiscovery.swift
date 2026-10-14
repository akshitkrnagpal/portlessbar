import Combine
import Darwin
import Foundation

struct NearbyRoute: Equatable, Hashable, Sendable {
    let url: URL
    let address: String

    var title: String {
        (url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
    }
}

struct BonjourEndpoint: Equatable, Sendable {
    let hostname: String
    let port: Int
    let addresses: [String]

    init?(hostname: String, port: Int, addresses: [String]) {
        let name = (hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname).lowercased()
        guard name.hasSuffix(".local"), Integration.validHostname(name), (1...65535).contains(port) else { return nil }
        let addresses = Array(Set(addresses)).sorted {
            // Portless currently publishes IPv4. Prefer it to scoped IPv6 addresses.
            if $0.contains(":") != $1.contains(":") { return !$0.contains(":") }
            return $0 < $1
        }
        guard !addresses.isEmpty else { return nil }
        self.hostname = name
        self.port = port
        self.addresses = addresses
    }

    func isLocal(addresses local: Set<String>) -> Bool {
        addresses.contains { local.contains($0) || NetworkAddress.isLoopback($0) }
    }

    func url(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = hostname
        if port != (scheme == "https" ? 443 : 80) { components.port = port }
        return components.url
    }
}

enum NetworkAddress {
    static func numeric(_ address: UnsafePointer<sockaddr>) -> String? {
        guard [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func numeric(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
        // Data does not guarantee sockaddr alignment.
        var storage = sockaddr_storage()
        guard data.count <= MemoryLayout.size(ofValue: storage) else { return nil }
        _ = withUnsafeMutableBytes(of: &storage) { destination in data.copyBytes(to: destination) }
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                guard Int(address.pointee.sa_len) <= data.count else { return nil }
                return numeric(address)
            }
        }
    }

    static func localAddresses() -> Set<String> {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(first) }
        var result = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            if let address = interface.pointee.ifa_addr, let value = numeric(address) { result.insert(value) }
            current = interface.pointee.ifa_next
        }
        return result
    }

    static func isLoopback(_ address: String) -> Bool {
        address == "::1" || address == "::" || address == "0.0.0.0" || address.hasPrefix("127.")
            || address.hasPrefix("::ffff:127.")
    }
}

enum NearbyProbe {
    typealias Runner = @Sendable ([String]) async throws -> CommandResult

    static func identifiesPortless(_ result: CommandResult) -> Bool {
        result.status == 0 && result.output.components(separatedBy: .newlines).contains { line in
            let header = line.split(separator: ":", maxSplits: 1)
            return header.count == 2 && header[0].lowercased() == "x-portless"
                && header[1].trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
    }

    static func find(_ endpoint: BonjourEndpoint) async -> NearbyRoute? {
        await find(endpoint, run: { arguments in
            try await Commands.execute(executable: "/usr/bin/curl", arguments: arguments, environment: [:], timeout: 4)
        })
    }

    static func find(_ endpoint: BonjourEndpoint, run: Runner) async -> NearbyRoute? {
        // Portless advertises _http._tcp even for HTTPS, with no scheme in its TXT record.
        for scheme in ["https", "http"] {
            guard let url = endpoint.url(scheme: scheme) else { continue }
            for address in endpoint.addresses {
                guard !Task.isCancelled else { return nil }
                let target = address.contains(":") ? "[\(address)]" : address
                let arguments = ["--disable", "--noproxy", "*", "--silent", "--head", "--insecure", "--max-time", "2",
                                 "--resolve", "\(endpoint.hostname):\(endpoint.port):\(target)",
                                 // Identify the proxy without forwarding a request to the development app.
                                 "--header", "Host: portlessbar-discovery.invalid", url.absoluteString]
                if let result = try? await run(arguments), identifiesPortless(result) {
                    return NearbyRoute(url: url, address: address)
                }
            }
        }
        return nil
    }
}

/// Browse only advertised web services. Local registry access and proxy control stay independent.
@MainActor
final class NearbyDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    typealias Probe = @Sendable (BonjourEndpoint) async -> NearbyRoute?
    @Published private(set) var routes: [NearbyRoute] = []
    @Published private(set) var error: String?
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var endpoints: [String: BonjourEndpoint] = [:]
    private var pending: [String: BonjourEndpoint] = [:]
    private var checks: [String: Task<Void, Never>] = [:]
    private var verified: [String: NearbyRoute] = [:]
    private var monitor: Task<Void, Never>?
    private let probe: Probe
    private let localAddresses: () -> Set<String>

    init(enabled: Bool = true, probe: @escaping Probe = NearbyProbe.find,
         localAddresses: @escaping () -> Set<String> = NetworkAddress.localAddresses) {
        self.probe = probe
        self.localAddresses = localAddresses
        super.init()
        if enabled { start() }
    }

    deinit { monitor?.cancel() }

    private func start() {
        for type in ["_http._tcp.", "_https._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .main, forMode: .common)
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        for browser in browsers { browser.stop(); browser.delegate = nil }
        browsers.removeAll()
        for service in services.values { service.stop(); service.delegate = nil }
        services.removeAll()
        endpoints.removeAll()
        pending.removeAll()
        for task in checks.values { task.cancel() }
        verified.removeAll()
        publish()
    }

    func refresh() {
        // Retry after macOS grants Local Network access or a browsing error clears.
        if error != nil {
            error = nil
            for (browser, type) in zip(browsers, ["_http._tcp.", "_https._tcp."]) {
                browser.stop()
                browser.searchForServices(ofType: type, inDomain: "local.")
            }
        }
        let local = localAddresses()
        verified = verified.filter { !local.contains($0.value.address) && !NetworkAddress.isLoopback($0.value.address) }
        publish()
        for service in services.values { service.stop(); service.resolve(withTimeout: 5) }
    }

    private func id(_ service: NetService) -> String {
        "\(service.domain)|\(service.type)|\(service.name)".lowercased()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = id(service)
        guard services[key] == nil else { return }
        services[key] = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = id(service)
        services[key]?.stop()
        services[key]?.delegate = nil
        services[key] = nil
        remove(key)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        error = "Could not discover nearby apps (error \(code)). Check PortlessBar's Local Network access in System Settings → Privacy & Security → Local Network."
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        let key = id(service)
        guard services[key] === service else { return }
        guard let host = service.hostName,
              let endpoint = BonjourEndpoint(hostname: host, port: service.port,
                                             addresses: (service.addresses ?? []).compactMap(NetworkAddress.numeric)) else {
            remove(key)
            return
        }
        update(endpoint, for: key)
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services[id(service)] === service else { return }
        remove(id(service))
    }

    // These entry points also let tests cover removals, local filtering and asynchronous verification.
    func update(_ endpoint: BonjourEndpoint, for key: String) {
        guard !endpoint.isLocal(addresses: localAddresses()) else { remove(key); return }
        if endpoints[key] != endpoint { verified[key] = nil; publish() }
        endpoints[key] = endpoint
        pending[key] = endpoint
        startChecks()
    }

    func remove(_ key: String) {
        endpoints[key] = nil
        pending[key] = nil
        checks[key]?.cancel()
        verified[key] = nil
        publish()
    }

    private func startChecks() {
        // Avoid launching an unbounded number of curl processes on a busy network.
        while checks.count < 4, let (key, endpoint) = pending.first(where: { checks[$0.key] == nil }) {
            pending[key] = nil
            let probe = probe
            checks[key] = Task { [weak self] in
                let route = await probe(endpoint)
                guard let self else { return }
                self.checks[key] = nil
                if !Task.isCancelled, self.endpoints[key] == endpoint {
                    self.verified[key] = endpoint.isLocal(addresses: self.localAddresses()) ? nil : route
                    self.publish()
                }
                self.startChecks()
            }
        }
    }

    private func publish() {
        let next = Array(Set(verified.values)).sorted {
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.address < $1.address
        }
        if routes != next { routes = next }
    }
}
