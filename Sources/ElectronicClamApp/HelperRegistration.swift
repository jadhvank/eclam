import AppKit
import Foundation
import OSLog
import ServiceManagement
import CryptoKit

enum HelperRegistration {
    static let plistName = "com.jadhvank.eclam.helper.plist"
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "app")
    private static let fingerprintKey = "VerifiedHelperBundleFingerprint"
    private static let pendingFingerprintKey = "PendingHelperBundleFingerprint"
    private static let upgradeFailureKey = "HelperUpgradeVerificationFailed"
    static var upgradeVerificationFailed: Bool { UserDefaults.standard.bool(forKey: upgradeFailureKey) }

    private static func saveVerifiedFingerprint(_ fingerprint: String) {
        UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
        UserDefaults.standard.removeObject(forKey: pendingFingerprintKey)
        UserDefaults.standard.set(false, forKey: upgradeFailureKey)
    }

    static func completePendingApproval() {
        guard let pending = UserDefaults.standard.string(forKey: pendingFingerprintKey),
              let fingerprint = bundledFingerprint else { return }
        _ = HelperUpgrade.finishApproval(fingerprint: fingerprint, pending: pending,
            enabled: status() == .enabled, reachable: { isHelperReachableWithRetry() },
            save: saveVerifiedFingerprint)
    }

    private static var bundledFingerprint: String? {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let helper = bundle.appendingPathComponent("Contents/MacOS/ElectronicClamHelper")
        let daemonPlist = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/" + plistName)
        guard let data = try? Data(contentsOf: helper),
              let config = try? Data(contentsOf: daemonPlist) else { return nil }
        func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return bundle.path + ":" + hash(data) + ":" + hash(config)
    }

    /// ADR-0038 — why the gate refused to register (nil ⇒ not blocked). AppDelegate reads it
    /// to show the relocation alert instead of the normal approval onboarding.
    static private(set) var installBlock: InstallLocation.Block?

    /// Register the daemon with SMAppService. ADR-0002 §5: single attempt per launch.
    static func registerIfNeeded() -> SMAppService.Status {
        // ADR-0038 — gate before register(): a quarantined/translocated bundle can't
        // spawn a privileged daemon (EX_CONFIG), so don't leave a dead BTM record.
        if let block = InstallLocation.registrationBlock(bundlePath: Bundle.main.bundlePath) {
            installBlock = block
            log.error("registration blocked (\(block.kind.rawValue, privacy: .public)): app at \(Bundle.main.bundlePath, privacy: .public) — not registering (ADR-0038)")
            return SMAppService.daemon(plistName: plistName).status   // do NOT register — avoid leaving a dead BTM record
        }
        installBlock = nil
        let service = SMAppService.daemon(plistName: plistName)
        if service.status == .enabled {
            completePendingApproval()
            // A live old daemon can survive a bundle replacement. Refresh once
            // on migration, binary change or relocation; never on every launch.
            if let fingerprint = bundledFingerprint {
                let verified = HelperUpgrade.ensureCurrent(fingerprint: fingerprint,
                    previous: UserDefaults.standard.string(forKey: fingerprintKey),
                    reachable: { isHelperReachableWithRetry() },
                    reinstall: {
                        let (status, error) = forceReregister(timeout: 10)
                        return status == .enabled && error == nil
                    },
                    save: saveVerifiedFingerprint)
                UserDefaults.standard.set(!verified, forKey: upgradeFailureKey)
                if !verified {
                    log.error("helper upgrade was not verified; receipt unchanged")
                }
                return service.status
            }
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
            if service.status == .requiresApproval, let fingerprint = bundledFingerprint {
                UserDefaults.standard.set(fingerprint, forKey: pendingFingerprintKey)
            }
            if service.status == .enabled, isHelperReachableWithRetry(),
               let fingerprint = bundledFingerprint {
                saveVerifiedFingerprint(fingerprint)
            }
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
                if s == .requiresApproval, let fingerprint = bundledFingerprint {
                    UserDefaults.standard.set(fingerprint, forKey: pendingFingerprintKey)
                }
                if s == .enabled, isHelperReachableWithRetry(), let fingerprint = bundledFingerprint {
                    saveVerifiedFingerprint(fingerprint)
                }
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
