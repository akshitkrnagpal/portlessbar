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
        // argv can retain an FNM shell alias after its symlink has disappeared.
        // The kernel still knows the actual runtime used by the live process.
        var executable = [CChar](repeating: 0, count: 4096)
        if pb_executable(pid, &executable, executable.count) > 0 {
            result[0] = String(decoding: executable.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        if result.count > 1, let script = portlessScript(result[1], runtime: result[0]) {
            result[1] = script.path
        }
        return result
    }

    static func portlessScript(_ path: String, runtime: String? = nil) -> URL? {
        let original = URL(fileURLWithPath: path)
        let script = original.resolvingSymlinksInPath()
        func recognized(_ file: URL) -> Bool {
            if file.path.hasSuffix("/portless/dist/cli.js") || file.path.hasSuffix("/portless/dist/cli.mjs") { return true }
            // Bun and other installers can store packages under versioned names.
            let packageRoot = file.deletingLastPathComponent().deletingLastPathComponent()
            guard let data = try? Data(contentsOf: packageRoot.appendingPathComponent("package.json")),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  package["name"] as? String == "portless" else { return false }
            let bin = package["bin"] as? String ?? (package["bin"] as? [String: String])?["portless"]
            return bin.map { packageRoot.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath() == file } ?? false
        }
        if recognized(script) { return script }
        // Never reinterpret an existing, unrelated script as Portless.
        guard !FileManager.default.fileExists(atPath: original.path),
              original.pathComponents.contains("fnm_multishells"), original.path.hasSuffix("/bin/portless"),
              let runtime else { return nil }
        let installed = URL(fileURLWithPath: runtime).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("portless").resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: installed.path) && recognized(installed) ? installed : nil
    }

    static func isPortless(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let executable = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().lastPathComponent
        guard ["node", "nodejs", "bun", "portless"].contains(executable) else { return false }
        if executable == "portless" { return true }
        // npm and Bun launch the CLI through bin symlinks; argv retains that link.
        return portlessScript(arguments[1], runtime: arguments[0]) != nil
    }

    static func isPortlessProxy(_ arguments: [String]) -> Bool {
        guard isPortless(arguments) else { return false }
        let executable = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath().lastPathComponent
        let proxy = executable == "portless" ? 1 : 2
        return arguments.indices.contains(proxy + 1) && arguments[proxy] == "proxy" && arguments[proxy + 1] == "start"
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
