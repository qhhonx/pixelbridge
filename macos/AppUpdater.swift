import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = true
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private weak var model: BridgeModel?
    private var started = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.automaticChecks = updater.automaticallyChecksForUpdates }
            }
        ]
    }
    func start(model: BridgeModel) {
        guard !started else { return }
        self.model = model
        started = true
        controller.startUpdater()
    }
    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
    // Finish cancellation and persist progress before Sparkle replaces and relaunches the app.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model else { return false }
        let resumeAutomatically = model.autoRunning
        model.pause()
        Task { @MainActor in
            while model.busy || model.pausing || model.scanning {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            UserDefaults.standard.set(resumeAutomatically, forKey: "automatic")
            installHandler()
        }
        return true
    }
}
