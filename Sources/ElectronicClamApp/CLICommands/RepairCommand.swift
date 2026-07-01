import Foundation
import ServiceManagement

/// `eclam repair` — recover a wedged/unreachable helper by relaunching the app,
/// so its registration runs in the GUI session context (handoff 2026-06-24,
/// ADR-0036 §P1-b revision).
///
/// Why this does NOT call SMAppService itself: `register()` is "Operation not
/// permitted" (EPERM) from a headless CLI invocation — daemon (re)registration
/// needs the GUI app's Background-Task-Management session, which a Terminal
/// subprocess lacks. Live-confirmed 2026-06-24: from the *same* wedged state, a
/// GUI-context `register()` succeeds while the CLI one fails. The earlier
/// version called `reinstall()` (unregister → register) here; the unregister
/// succeeded but the register EPERM'd, **stranding the helper in
/// `.notRegistered`** — strictly worse than the dead-but-`.enabled` it started
/// from. So this command never mutates SMAppService; it relaunches the app whose
/// `registerIfNeeded()` / P0-b self-repair run in the context that works, then
/// verifies the helper answers XPC.
enum RepairCommand: CLISubcommand {
    static func run(args: [String]) -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            print(helpText)
            return 0
        }
        if let extra = args.first {
            CLIStderr.print("eclam repair: unexpected argument '\(extra)' (repair takes no arguments).")
            return 1
        }

        // ADR-0039 — split-brain(중복본) 점검. 자동 삭제는 하지 않는다(번들 삭제는
        // 비가역) — /Applications 밖 복사본을 짚어주고 사용자가 직접 지우게 한다.
        let copies = BundleScan.copies()
        if copies.count > 1 {
            print("eclam repair: multiple installs detected (split-brain risk). Keep only the one in /Applications and remove the rest:")
            for c in copies where !c.inApplications {
                print("  \(c.shortVersion ?? "?")  \(c.path)")
            }
        }

        // 1) Already healthy? Don't disturb a working app — a relaunch would
        //    briefly drop any active keep-awake hold.
        let reg = SMAppService.daemon(plistName: HelperRegistration.plistName).status
        if reg == .enabled, HelperLiveness.isReachable(timeout: 3.0) {
            print("eclam repair: helper already registered and reachable — nothing to do.")
            return 0
        }

        // 2) Relaunch the app so registration happens in its GUI session.
        guard let appPath = appBundlePath() else {
            CLIStderr.print("eclam repair: cannot locate ElectronicClam.app. Open the app manually "
                + "and use Settings > General > Reinstall Helper.")
            return 2
        }
        print("eclam repair: relaunching Electronic Clam to repair the helper in its app context…")
        // Graceful quit (no-op if not running) — same path the app uses on quit,
        // so any held sleep is restored cleanly. Then relaunch the bundle.
        _ = Subprocess.capture("/usr/bin/osascript", ["-e", "quit app \"ElectronicClam\""])
        Thread.sleep(forTimeInterval: 1.5)
        _ = Subprocess.capture("/usr/bin/open", [appPath])

        // 3) Wait for the relaunched app to register + the daemon to answer. The
        //    relaunch path runs P0-b's liveness probes then forceReregister
        //    (which retries register across the BTM settle window), so budget
        //    generously: launch + ~6s probe + ~10s re-register + daemon start.
        let deadline = Date().addingTimeInterval(35)
        var reachable = false
        while Date() < deadline {
            if HelperLiveness.isReachable(timeout: 2.0) { reachable = true; break }
            Thread.sleep(forTimeInterval: 1.0)
        }

        if reachable {
            print("eclam repair: helper is reachable again.")
            return 0
        }

        // Still down → most likely needs approval, or a stale launch requirement.
        let post = SMAppService.daemon(plistName: HelperRegistration.plistName).status
        if post == .requiresApproval {
            CLIStderr.print("eclam repair: the helper needs approval. Open System Settings > General > "
                + "Login Items & Extensions, enable Electronic Clam, then re-run `eclam repair`.")
            return 3
        }
        CLIStderr.print("eclam repair: still unreachable after relaunch. Open Electronic Clam and use "
            + "Settings > General > Reinstall Helper; if it persists, restart your Mac (ADR-0020).")
        // ADR-0039 — 최후수단 안내(자동 실행 금지: sudo + 전역 영향). 죽은 BTM 레코드가
        // 이미 제거된 복사본에 묶여 있으면 resetbtm 만 먹혔던 2026-07-01 사건의 복구 경로.
        CLIStderr.print("If it persists, a stale background record may be bound to a removed copy. "
            + "Last resort: 'sudo sfltool resetbtm', then reboot and reopen Electronic Clam "
            + "(this resets ALL apps' login items).")
        return 2
    }

    /// The `.app` bundle to relaunch. `eclam` is a symlink into the bundle, so
    /// `Bundle.main` usually resolves to the `.app`; fall back to truncating at
    /// `.app` (when it resolves to `Contents/MacOS`), then to the conventional
    /// install path.
    private static func appBundlePath() -> String? {
        let b = Bundle.main.bundlePath
        if b.hasSuffix(".app") { return b }
        if let r = b.range(of: ".app") { return String(b[..<r.upperBound]) }
        let fallback = "/Applications/ElectronicClam.app"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    private static let helpText = """
    usage: eclam repair

    Recover a registered-but-unreachable helper by relaunching Electronic Clam,
    so its registration runs in the GUI session context (CLI re-registration is
    blocked by macOS — EPERM). Verifies the helper answers XPC afterward.

    Exit: 0 reachable / 2 still unreachable (try Settings > Reinstall Helper, or a
          reboot) / 3 needs approval.
    """
}
