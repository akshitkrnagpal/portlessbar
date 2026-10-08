import Foundation
import PortlessSystem

struct Route: Codable, Sendable, Equatable {
    var hostname: String
    var port: Int
    var pid: Int32?
    var tailscaleUrl: String?
    var ngrokUrl: String?
}

enum PortlessError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Integration {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func arguments(pid: Int32) -> [String] {
        var buffer = [CChar](repeating: 0, count: 262144)
        var size = buffer.count
        guard pb_arguments(pid, &buffer, &size) == 0, size > 4 else { return [] }
        let data = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        let count = data.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard count > 0, count < 4096 else { return [] }
        var cursor = 4
        // KERN_PROCARGS2: argc, executable path, NUL padding, then argc arguments.
        while cursor < data.count && data[cursor] != 0 { cursor += 1 }
        while cursor < data.count && data[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<count {
            let start = cursor
            while cursor < data.count && data[cursor] != 0 { cursor += 1 }
            guard cursor < data.count else { return [] }
            result.append(String(decoding: data[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        // argv can retain a package-manager alias after its symlink has disappeared.
        // The kernel still knows the actual runtime used by the live process.
        var executable = [CChar](repeating: 0, count: 4096)
        if pb_executable(pid, &executable, executable.count) > 0 {
            result[0] = String(decoding: executable.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        if result.count > 1, let script = portlessScript(result[1]) {
            result[1] = script.path
        }
        return result
    }

    static func portlessScript(_ path: String) -> URL? {
        let script = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        // Package metadata identifies the entry point independently of the
        // installer's directory layout, package folder name, or bin symlink.
        var packageRoot = script.deletingLastPathComponent()
        while packageRoot.path != "/" {
            defer { packageRoot.deleteLastPathComponent() }
            guard let data = try? Data(contentsOf: packageRoot.appendingPathComponent("package.json")),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  package["name"] as? String == "portless" else { continue }
            let bin = package["bin"] as? String ?? (package["bin"] as? [String: String])?["portless"]
            if bin.map({ packageRoot.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() == script }) == true { return script }
        }
        return nil
    }

    static func isPortless(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let executable = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().lastPathComponent
        guard ["node", "nodejs", "bun", "portless"].contains(executable) else { return false }
        if executable == "portless" { return true }
        // npm and Bun launch the CLI through bin symlinks; argv retains that link.
        return portlessScript(arguments[1]) != nil
    }

    static func isPortlessProxy(_ arguments: [String]) -> Bool {
        guard isPortless(arguments) else { return false }
        return proxyStartIndex(arguments) != nil
    }

    // Only used to recover reconnect options; process authorization uses the
    // live protocol and socket owner, never a guess about these arguments.
    static func proxyStartIndex(_ arguments: [String]) -> Int? {
        [1, 2].first { arguments.indices.contains($0 + 1) && arguments[$0] == "proxy" && arguments[$0 + 1] == "start" }
    }

    static func verifyProxy(pid: Int32, directory: String) async -> Bool {
        func state() -> ProxyConfiguration? {
            guard let raw = try? String(contentsOfFile: directory + "/proxy.pid", encoding: .utf8),
                  Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) == pid else { return nil }
            return ProxyConfiguration.read(directory: directory, pid: nil)
        }
        guard pid > 1, let configuration = state() else { return false }
        for ipv6: Int32 in [0, 1] {
            let listener = pb_listener(pid, Int32(configuration.port), ipv6)
            guard listener != 0 else { continue }
            let host = ipv6 == 0 ? "127.0.0.1" : "[::1]"
            let url = "\(configuration.tls ? "https" : "http")://\(host):\(configuration.port)/"
            // Match Portless's own HEAD probe. Disable user curl config, proxy
            // routing and redirects; trust local TLS only for this identity probe.
            guard let result = try? await Commands.execute(executable: "/usr/bin/curl",
                arguments: ["--disable", "--noproxy", "*", "--silent", "--head", "--insecure", "--max-time", "2", url],
                environment: [:], timeout: 3), result.status == 0 else { continue }
            let portless = result.output.components(separatedBy: .newlines).contains { line in
                let header = line.split(separator: ":", maxSplits: 1)
                return header.count == 2 && header[0].lowercased() == "x-portless"
                    && header[1].trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            }
            if portless && state() == configuration && pb_listener(pid, Int32(configuration.port), ipv6) == listener { return true }
        }
        return false
    }

    static func readRoutes(directory: String) throws -> [Route] {
        let file = URL(fileURLWithPath: directory).appendingPathComponent("routes.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        // Decode records independently so a new or malformed record cannot hide
        // unrelated registrations. The registry remains strictly read-only.
        struct Record: Decodable {
            let route: Route?
            init(from decoder: Decoder) throws {
                route = try? decoder.singleValueContainer().decode(Route.self)
            }
        }
        return try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)).compactMap(\.route).filter {
            validHostname($0.hostname) && (1...65535).contains($0.port) && ($0.pid ?? 0) >= 0
        }
    }

    static func validHostname(_ value: String) -> Bool {
        value.count <= 253 && value.contains(".") && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
            $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func url(hostname: String, directory: String, fallback: ProxyConfiguration? = nil) -> URL? {
        func marker(_ name: String) -> String? {
            try? String(contentsOfFile: directory + "/" + name, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let storedPort = Int(marker("proxy.port") ?? "")
        let tls = storedPort == nil ? (fallback?.tls ?? false) : FileManager.default.fileExists(atPath: directory + "/proxy.tls")
        let port = storedPort ?? fallback?.port ?? (tls ? 443 : 80)
        var components = URLComponents()
        components.scheme = tls ? "https" : "http"
        components.host = hostname
        if port != (tls ? 443 : 80) { components.port = port }
        return components.url
    }
}
