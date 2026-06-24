import Foundation
import ServiceManagement

/// `eclam status [--json]` — read-only (never *mutates* helper/power state).
/// It does send read-only XPC probes when the helper is enabled: a liveness
/// ping (honest reachability, handoff 2026-06-24) plus the ADR-0025 hold and
/// v0.3.2 active-agents snapshots. ADR-0007 §C.
///
/// Exit: 0 ok / 2 enabled-but-unreachable (run `eclam repair`). Non-enabled
/// registration states stay 0 (read succeeded) — `HelperHealthVerdict.exit`.
enum StatusCommand: CLISubcommand {
    static func run(args: [String]) -> Int32 {
        let json = args.contains("--json")

        let reg = readRegistration()
        // ADR-0033 parity for the CLI: `.enabled` is registration *intent*, not
        // launchd reachability. Probe XPC liveness only when enabled, so a
        // dead-but-registered daemon is reported honestly (and exits 2) instead
        // of a flat "enabled"/exit 0 — the silent false positive this fixes
        // (handoff 2026-06-24). 3s absorbs the on-demand daemon's cold start
        // (HelperLiveness §timeout); a warm daemon answers instantly.
        let reachable: Bool? = (reg == .enabled)
            ? HelperLiveness.isReachable(timeout: 3.0)
            : nil
        let verdict = HelperHealth.evaluate(reg: reg, reachable: reachable)

        let sleepDisabled = readSleepDisabled()
        let agentMode = readAgentMode()
        let watched = readWatchedAgents()
        // Richer XPC roundtrips only when the helper actually answered the
        // liveness probe — no point waiting out three more timeouts on a dead
        // daemon. Falls back to the empty array (not the JSON `null`) so the
        // field shape stays stable for downstream consumers.
        let helperUsable = (reachable == true)
        let activeAgents: [String] = helperUsable
            ? (readActiveAgentsViaXPC() ?? [])
            : []
        // ADR-0025 — CLI TTL hold 잔여 (-1 forever / 0 none / >0 sec / nil unknown).
        let holdRemaining: Double? = helperUsable ? readHoldViaXPC() : nil
        // ADR-0032 — "Open at Login" 메인 앱 로그인 항목(helper 데몬 등록과 별개).
        // helper liveness 처럼 숨은 상태를 CLI 에서 관측 가능하게 — "로그인 실행이
        // 잘 안 되는 것 같다"를 추측이 아니라 `eclam status` 로 확인.
        let loginItem = readLoginItem()

        if json {
            let root: [String: Any] = [
                "helperStatus": verdict.raw,
                // nil when the helper wasn't probed (registration != enabled);
                // serializes to JSON null, matching the other optional fields.
                "helperReachable": verdict.reachable as Any,
                "loginItem": loginItem,
                "sleepDisabled": sleepDisabled as Any,
                "agentMode": agentMode,
                "watchedAgents": watched.sorted(),
                "activeAgents": activeAgents.sorted(),
                "holdRemainingSeconds": holdRemaining as Any,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: root,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            let awake: String
            if let s = sleepDisabled { awake = s ? "yes" : "no" } else { awake = "unknown" }
            let watchedStr = watched.sorted().joined(separator: ", ")
            print("helper:      \(verdict.human)")
            print("awake:       \(awake)")
            if let h = holdRemaining, h != 0 {
                print("hold:        \(h < 0 ? "no expiry (--forever)" : DurationParse.shortFormat(seconds: h) + " left") (CLI)")
            }
            print("agent mode:  \(agentMode)")
            print("watched:     \(watchedStr.isEmpty ? "(none)" : watchedStr)")
            print("login item:  \(loginItem)")
        }
        // 0 ok / 2 enabled-but-unreachable. Non-enabled states stay 0 — see
        // HelperHealthVerdict.exit (CI smoke.sh invariant).
        return verdict.exit
    }

    // MARK: - Readers

    /// SMAppService registration → framework-free `HelperReg` (so the verdict
    /// mapping in `HelperHealth` stays pure/testable). This is the *intent*
    /// half; liveness is probed separately via `HelperLiveness`.
    private static func readRegistration() -> HelperReg {
        let service = SMAppService.daemon(plistName: HelperRegistration.plistName)
        switch service.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        case .notRegistered:    return .notRegistered
        @unknown default:       return .unknown
        }
    }

    /// ADR-0032 — main-app login item status (`SMAppService.mainApp`), distinct
    /// from the helper daemon. Read-only; surfaced so "Open at Login" state is
    /// observable from the CLI (the honest-status lesson applied — a user can
    /// confirm it rather than guess "it doesn't seem to work").
    private static func readLoginItem() -> String {
        switch LoginItem.status {
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered:    return "notRegistered"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown"
        }
    }

    /// Read current `SleepDisabled` via `pmset -g`. Returns `nil` if pmset
    /// is unavailable or parsing fails — surfaced as `"unknown"` in output.
    private static func readSleepDisabled() -> Bool? {
        guard let s = Subprocess.capture("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in s.split(separator: "\n") {
            // Format: " SleepDisabled        1"
            let l = line.lowercased()
            guard l.contains("sleepdisabled") else { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if let last = parts.last {
                if last == "1" { return true }
                if last == "0" { return false }
            }
        }
        return nil
    }

    private static func readAgentMode() -> String {
        let raw = UserDefaults.standard.string(forKey: "AgentMode") ?? "strict"
        return raw.lowercased()
    }

    private static func readWatchedAgents() -> [String] {
        if let stored = UserDefaults.standard.array(forKey: "WatchedAgents") as? [String] {
            return stored
        }
        // Mirror StateStore default (v0.5 ADR-0006 §B — the documented 5).
        return AgentTrace.M1Defaults.map(\.id)
    }

    /// ADR-0025 — single-shot `currentStateWithHold`. nil on any failure.
    private static func readHoldViaXPC() -> Double? {
        let conn = NSXPCConnection(machServiceName: HelperServiceName.mach,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ElectronicClamHelperProtocol.self)
        conn.resume()
        defer { conn.invalidate() }
        let sem = DispatchSemaphore(value: 0)
        // Lock-guarded (shared LockedBox): the reply lands on an XPC queue; a
        // late reply after the 0.5s timeout must not write a value this
        // thread is concurrently reading. A plain `var` here was a data race.
        let result = LockedBox<Double?>(nil)
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
            sem.signal()
        } as? ElectronicClamHelperProtocol
        guard let proxy = proxy else { return nil }
        proxy.currentStateWithHold { _, remaining, err in
            if err == nil { result.set(remaining) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 0.5) == .timedOut { return nil }
        return result.get()
    }

    /// v0.3.2 — single-shot synchronous XPC call to fetch the helper's most
    /// recent `activeAgents` snapshot. Returns nil on any failure path; the
    /// caller treats nil as `[]` for the JSON output but never tears down the
    /// app over it (read-only command).
    private static func readActiveAgentsViaXPC() -> [String]? {
        let conn = NSXPCConnection(machServiceName: HelperServiceName.mach,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ElectronicClamHelperProtocol.self)
        conn.resume()
        defer { conn.invalidate() }
        let sem = DispatchSemaphore(value: 0)
        // Lock-guarded — same timeout-vs-late-reply race as readHoldViaXPC.
        let result = LockedBox<[String]?>(nil)
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
            sem.signal()
        } as? ElectronicClamHelperProtocol
        guard let proxy = proxy else { return nil }
        proxy.activeAgents { ids, err in
            if err == nil { result.set(ids) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 0.5) == .timedOut { return nil }
        return result.get()
    }
}
