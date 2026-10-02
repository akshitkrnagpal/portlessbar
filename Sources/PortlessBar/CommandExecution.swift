import Foundation

/// Foundation's callbacks and cancellation can arrive on different threads.
/// The lock owns process launch, completion, and the continuation's lifetime.
private final class CommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let log = FileManager.default.temporaryDirectory.appendingPathComponent("PortlessBar-command-" + UUID().uuidString)
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var pendingError: Error?
    private var finished = false
    private var launched = false
    private var timeout: DispatchWorkItem?
    private var escalation: DispatchWorkItem?

    func execute(executable: String, arguments: [String], environment: [String: String], timeout seconds: TimeInterval) async throws -> CommandResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    self.start(continuation, executable: executable, arguments: arguments, environment: environment, seconds: seconds)
                }
            }
        } onCancel: { self.stop(CancellationError()) }
    }

    private func start(_ continuation: CheckedContinuation<CommandResult, Error>, executable: String, arguments: [String], environment: [String: String], seconds: TimeInterval) {
        lock.lock()
        self.continuation = continuation
        if let error = pendingError {
            lock.unlock()
            finish(error: error)
            return
        }
        do {
            guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw PortlessError.message("Could not create the Portless command log.")
            }
            handle = try FileHandle(forWritingTo: log)
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { _ in self.finish() }
            try process.run()
            launched = true
            let timer = DispatchWorkItem {
                self.stop(PortlessError.message("The Portless command timed out. Check Portless in Terminal and try again."))
            }
            timeout = timer
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(error: error)
        }
    }

    private func stop(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if pendingError == nil { pendingError = error }
        guard launched, process.isRunning else { return }
        process.terminate()
        // Wait asynchronously for termination, then escalate if SIGTERM was ignored.
        if escalation == nil {
            let timer = DispatchWorkItem { self.forceStop() }
            escalation = timer
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timer)
        }
    }

    private func forceStop() {
        lock.lock()
        defer { lock.unlock() }
        if !finished, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func finish(error: Error? = nil) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        escalation?.cancel(); escalation = nil
        process.terminationHandler = nil
        try? handle?.close(); handle = nil
        let failure = pendingError ?? error
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let status = launched ? process.terminationStatus : -1
        try? FileManager.default.removeItem(at: log)
        lock.unlock()
        if let failure { continuation.resume(throwing: failure) }
        else { continuation.resume(returning: CommandResult(status: status, output: output)) }
    }
}

enum Commands {
    static func execute(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await CommandExecution().execute(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }
}
