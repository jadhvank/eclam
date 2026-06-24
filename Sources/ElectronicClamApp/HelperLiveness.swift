import Foundation

/// Single-shot, synchronous XPC liveness probe for the privileged helper.
///
/// `SMAppService.status == .enabled` reflects registration *intent*, not whether
/// launchd actually loaded a daemon that answers XPC (ADR-0033). This confirms
/// reachability by sending the universal `currentState` selector — implemented
/// by every helper generation, so it doubles as a pure liveness ping (mirrors
/// `HelperBridge.probeLiveness`, the app-side equivalent).
///
/// Shared by the CLI seam introduced for the honest-status fix (handoff
/// 2026-06-24): `eclam status` (honest report), `HelperRegistration`
/// (self-repair gate), and `eclam repair` (post-reinstall verification).
enum HelperLiveness {
    /// `true` ⇒ the helper answered within `timeout`. `false` ⇒ XPC error
    /// (connection invalid / no proxy) or no reply before the deadline.
    ///
    /// The helper is an on-demand LaunchDaemon (`MachServices`, no `KeepAlive`),
    /// so the first connect cold-starts the process. Pass a `timeout` generous
    /// enough to absorb that cold start — `OnCommand` uses 3s for the same
    /// reason. A too-short bound would misreport a healthy-but-cold daemon as
    /// unreachable (and, in `registerIfNeeded`, trigger a needless reinstall).
    static func isReachable(timeout: TimeInterval) -> Bool {
        let conn = NSXPCConnection(machServiceName: HelperServiceName.mach,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ElectronicClamHelperProtocol.self)
        conn.resume()
        defer { conn.invalidate() }

        let sem = DispatchSemaphore(value: 0)
        // Lock-guarded (shared LockedBox): the reply and the error handler land
        // on XPC queues; after the timeout this thread reads while a late
        // callback may still write. A plain `var` here would be a data race —
        // the same hazard the other one-shot CLI RPCs guard against.
        let reachable = LockedBox(false)
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in
            sem.signal()   // connection-level failure ⇒ reachable stays false
        }) as? ElectronicClamHelperProtocol else {
            return false
        }
        proxy.currentState { _, _ in
            // Any reply at all — even an error payload — proves the daemon is
            // alive and answering. Liveness is reachability, not the value.
            reachable.set(true)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return false }
        return reachable.get()
    }
}
