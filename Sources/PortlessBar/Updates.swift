import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateStore: ObservableObject {
    @Published var canCheck = false
    @Published var automaticallyChecks = true
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              !ProcessInfo.processInfo.arguments.contains("--background"),
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func check() { controller?.checkForUpdates(nil) }
}
