import ServiceManagement
import Combine

@MainActor
protocol LoginItemManaging: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openLoginItemsSettings()
}

@MainActor
final class SystemLoginItem: LoginItemManaging {
    private let service = SMAppService.mainApp
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws {
        // Keep the framework receiver on the main actor, including with older SDKs
        // that do not annotate SMAppService as Sendable.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemStore: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var changing = false
    @Published var error: String?
    private let service: any LoginItemManaging

    var enabled: Bool { status == .enabled }

    init(service: any LoginItemManaging = SystemLoginItem()) {
        self.service = service
        refresh()
    }

    func refresh() { status = service.status }

    func setEnabled(_ enabled: Bool) async {
        guard !changing else { return }
        changing = true
        error = nil
        defer { refresh(); changing = false }
        do {
            if enabled {
                switch service.status {
                case .enabled: return
                case .requiresApproval: service.openLoginItemsSettings()
                default:
                    try service.register()
                    if service.status == .requiresApproval { service.openLoginItemsSettings() }
                }
            } else if service.status != .notRegistered {
                try await service.unregister()
            }
        } catch { self.error = error.localizedDescription }
    }
}
