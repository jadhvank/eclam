import AppKit
import Foundation
import OSLog
import ServiceManagement

/// "Open at Login" for the **main app** (ADR-0032).
///
/// Distinct from `HelperRegistration`, which registers the *privileged daemon*
/// via `SMAppService.daemon(plistName:)`. This registers the app bundle itself
/// via `SMAppService.mainApp`, so Electronic Clam relaunches into the menu bar
/// after a reboot/login. No plist, no helper — the OS owns the Login Items entry
/// and is the single source of truth (we never mirror it into UserDefaults; we
/// read `status` live on every render).
///
/// macOS 13+ only (`LSMinimumSystemVersion` is 13.0), same floor as the daemon
/// API already in use.
enum LoginItem {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "app")

    /// Live OS status. Flips when the user toggles the entry in System Settings →
    /// General → Login Items, so renders read it directly rather than caching.
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register/unregister the app as a login item. Idempotent — skips the call
    /// when already in the desired state so a redundant toggle can't throw.
    ///
    /// Note on `.requiresApproval`: once the user has *explicitly* disabled the
    /// entry in System Settings, `register()` will not silently force it back on
    /// (macOS honours the user's choice); `status` stays `.requiresApproval` and
    /// the caller should route the user to the Login Items pane. The same one-way
    /// trust model the daemon registration already relies on (ADR-0018).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> (SMAppService.Status, Error?) {
        let service = SMAppService.mainApp
        var thrown: Error?
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                // unregister() throws if not currently registered — guard it.
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            thrown = error
            log.error("LoginItem.setEnabled(\(enabled)) failed: \(error.localizedDescription, privacy: .public)")
        }
        return (service.status, thrown)
    }
}
