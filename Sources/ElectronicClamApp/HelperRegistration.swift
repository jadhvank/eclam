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
            // P0-b (handoff 2026-06-24) — `.enabled` is registration *intent*,
            // not launchd reachability (ADR-0033). A registered-but-dead daemon
            // stays `.enabled` forever, and the old unconditional short-circuit
            // meant a relaunch never healed it — only the menu-only `reinstall()`
            // could. Probe liveness; if it's genuinely unreachable, self-repair
            // via reinstall() so that *relaunching the app* is enough.
            if isHelperReachableWithRetry() {
                return .enabled
            }
            log.error(".enabled but helper unreachable on launch — self-repair via forceReregister (P0-b)")
            let (status, err) = forceReregister(timeout: 10)
            if let err = err {
                log.error("P0-b self-repair did not settle: \(err.localizedDescription, privacy: .public)")
            } else {
                log.info("P0-b self-repair → \(String(describing: status), privacy: .public)")
            }
            return status
        }
        do {
            try service.register()
        } catch {
            log.error("SMAppService.register failed: \(error.localizedDescription, privacy: .public)")
        }
        return service.status
    }

    /// Two liveness windows before declaring a `.enabled` helper dead (P0-b).
    ///
    /// The helper is an on-demand daemon, so this first connect cold-starts it.
    /// A healthy daemon answers the first window (warm: instant; cold: typically
    /// sub-second); a wedged one fails its XPC error handler fast. The retry
    /// only matters for a pathologically slow cold start — it keeps that from
    /// being misread as death and churning the registration (invariant #4:
    /// approve once) on every launch. Worst case (a daemon that accepts the
    /// connection but never replies) is bounded by 2× the probe timeout.
    private static func isHelperReachableWithRetry() -> Bool {
        if HelperLiveness.isReachable(timeout: 3.0) { return true }
        return HelperLiveness.isReachable(timeout: 3.0)
    }

    /// Robust re-registration that rides out the BTM/launchd settle window.
    ///
    /// Live finding (2026-06-24): `register()` *immediately* after `unregister()`
    /// fails with "Operation not permitted" — BTM/launchd hasn't finished tearing
    /// the old registration down yet. A `register()` seconds later succeeds. This
    /// reproduced in BOTH the GUI app and the CLI, so it is a *timing* property,
    /// not a GUI-context requirement; the one-shot `reinstall()` (unregister then
    /// immediate register) therefore stranded the helper in `.notRegistered`.
    ///
    /// So: unregister once (only if currently registered), then retry
    /// `register()` with a fixed backoff until the daemon is registered again
    /// (`.enabled`/`.requiresApproval`) or `timeout` elapses. Returns the final
    /// status and the last register error (nil on success). Synchronous — the
    /// caller blocks for up to ~`timeout`; only invoked on the rare dead-helper
    /// path, so the launch/CLI cost is bounded and paid only when broken.
    @discardableResult
    static func forceReregister(timeout: TimeInterval) -> (SMAppService.Status, Error?) {
        let service = SMAppService.daemon(plistName: plistName)
        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
            } catch {
                log.error("forceReregister unregister failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var lastErr: Error?
        repeat {
            do {
                try service.register()
                let s = service.status
                if s == .enabled || s == .requiresApproval { return (s, nil) }
            } catch {
                lastErr = error   // expected EPERM until BTM settles; keep retrying
            }
            Thread.sleep(forTimeInterval: 0.6)
        } while Date() < deadline
        log.error("forceReregister: register did not settle within \(Int(timeout), privacy: .public)s")
        return (service.status, lastErr)
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
    /// ⚠️ SUPERSEDED by `forceReregister(timeout:)` (ADR-0036) — do not call.
    /// This one-shot version registers *immediately* after unregister, which
    /// EPERMs until BTM/launchd settles and strands the helper in
    /// `.notRegistered` (live-confirmed 2026-06-24). Kept only so the historical
    /// references above resolve; both call sites (P0-b, the menu) now use the
    /// retrying `forceReregister`.
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
