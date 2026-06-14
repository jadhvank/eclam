import AppKit
import Foundation
import OSLog
import ServiceManagement

enum HelperRegistration {
    static let plistName = "com.jadhvank.eclam.helper.plist"
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "app")

    /// Register the daemon with SMAppService. ADR-0002 §5: single attempt per launch.
    static func registerIfNeeded() -> SMAppService.Status {
        let service = SMAppService.daemon(plistName: plistName)
        if service.status == .enabled {
            return .enabled
        }
        do {
            try service.register()
        } catch {
            log.error("SMAppService.register failed: \(error.localizedDescription, privacy: .public)")
        }
        return service.status
    }

    /// Manual retry from the menu.
    @discardableResult
    static func retry() -> (SMAppService.Status, Error?) {
        let service = SMAppService.daemon(plistName: plistName)
        var thrown: Error?
        do {
            try service.register()
        } catch {
            thrown = error
            log.error("retry register failed: \(error.localizedDescription, privacy: .public)")
        }
        return (service.status, thrown)
    }

    /// ADR-0020 — explicit "Reinstall Helper" repair (Macchiato-style):
    /// `unregister()` then `register()` to rebuild a wedged registration.
    ///
    /// This recovers softer wedged states (e.g. a `.requiresApproval` limbo, or a
    /// stale registration left by a messy uninstall). It does **not** clear a
    /// kernel-cached LightweightCodeRequirement from an ad-hoc cdhash change —
    /// per Apple DTS, unregister/register has "no effect on that bug" — so a hard
    /// LWCR mismatch after an ad-hoc upgrade still needs a reinstall/reboot. The
    /// real fix is a stable signing identity (ADR-0020).
    @discardableResult
    static func reinstall() -> (SMAppService.Status, Error?) {
        let service = SMAppService.daemon(plistName: plistName)
        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
            } catch {
                // Non-fatal: fall through to register anyway.
                log.error("reinstall unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        var thrown: Error?
        do {
            try service.register()
        } catch {
            thrown = error
            log.error("reinstall register failed: \(error.localizedDescription, privacy: .public)")
        }
        return (service.status, thrown)
    }

    /// Pure read of the daemon's current SMAppService status — no `register`
    /// side effect. Used to reconcile `store.registration` on app activation and
    /// menu open (ADR-0018): approving or revoking the Login Item in System
    /// Settings flips this live, without a relaunch.
    static func status() -> SMAppService.Status {
        SMAppService.daemon(plistName: plistName).status
    }

    static func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
