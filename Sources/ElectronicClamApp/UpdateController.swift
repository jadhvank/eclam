import AppKit
import Sparkle

/// ADR-0041: Sparkle owns download verification, installation and restart UI.
/// CLI dispatch never initializes this singleton or starts an update check.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        UpdatePreferences.migrate()
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates
            ?? UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks") }
        set {
            start()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }
}
