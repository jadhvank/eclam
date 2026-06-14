import Foundation
import OSLog

/// ADR-0008 — remote-control activity detector.
///
/// Polls a forgiving set of signals every 5 seconds and publishes the union
/// to `StateStore`. The activity rolls into `shouldKeepAwake` (gated by the
/// `RemoteCountsAsActivity` user toggle).
///
/// Signal priority (any positive ⇒ active):
///   1. `/usr/bin/pmset -g assertions` — `NetworkClientActive`,
///      `PreventSystemSleep` w/ NetworkClient / ScreenSharing / ARD owner.
///   2. `/usr/bin/who` — remote user (IPv4/IPv6 in parens).
///   3. `tailscale status --json` — only if a tailscale CLI is on the path.
///   4. `pgrep -f "screensharingd|ARDAgent|chrome_remote_desktop|anydesk|teamviewer"`.
///
/// 60s grace per ADR-0006 §C alignment: once active, the watcher waits 60s
/// of empty polls before going inactive to absorb flap.
final class RemoteWatcher {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "remote")
    private let pollInterval: TimeInterval = 5
    private let inactiveGrace: TimeInterval = 60

    private let store: StateStore
    private var timer: Timer?

    /// 폴링 subprocess(pmset/who/tailscale/pgrep)를 메인 스레드에서 떼어내는
    /// 전용 직렬 큐. 시스템 포화·hung 마운트로 명령이 블록돼도 메인 런루프는
    /// 계속 돌아 heartbeat 가 굶지 않고 watchdog 오발(작업 중 맥 재움)을 막는다.
    /// `tick()` 의 모든 인스턴스 가변 상태(`lastActiveAt`/`lastChannels`/
    /// `lastAgentActiveAt`)는 이 큐에서만 접근하므로 직렬화로 경쟁이 없다.
    /// 이 큐는 `StateStore` 를 **읽지 않는다**(P1): 필요한 값은 메인에서 떠서
    /// `tick(timeout:agentsActive:)` 인자로 받는다 — 메인의 `Set<String>`
    /// 재할당과 경쟁하던 backing-buffer use-after-free 를 차단한다.
    /// store 갱신은 `StateStore.setRemote` 가 내부에서 메인으로 마샬한다.
    private let pollQueue = DispatchQueue(label: "com.jadhvank.eclam.remote.poll")

    /// Last time a poll observed a non-empty channel set. (pollQueue 전용)
    private var lastActiveAt: Date?
    /// Last channel set we surfaced; preserved during the grace window. (pollQueue 전용)
    private var lastChannels: Set<String> = []
    /// ADR-0016 — last time any agent was active, for SSH idle gating. `nil`
    /// means "never seen" ⇒ treated as infinitely idle (tty idle alone governs).
    /// (pollQueue 전용)
    private var lastAgentActiveAt: Date?

    init(store: StateStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            // 타이머 클로저는 메인 런루프에서 돈다 — 여기서 StateStore 스냅샷을
            // 떠서 백그라운드 큐로 넘긴다. pollQueue 는 StateStore 를 읽지 않아
            // 메인의 쓰기와 경쟁하지 않는다(P1: Set<String> retain/release race).
            // 그리고 메인은 절대 subprocess 로 블록되지 않는다.
            guard let self else { return }
            let timeout = self.store.remoteIdleTimeoutMin
            let agentsActive = !self.store.activeAgents.isEmpty
            self.pollQueue.async { self.tick(timeout: timeout, agentsActive: agentsActive) }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        log.info("RemoteWatcher started (poll=\(self.pollInterval, privacy: .public)s)")
        // 초기 kick — start() 는 메인에서 호출되므로 여기서 store 를 읽어도 안전.
        let timeout = store.remoteIdleTimeoutMin
        let agentsActive = !store.activeAgents.isEmpty
        pollQueue.async { [weak self] in self?.tick(timeout: timeout, agentsActive: agentsActive) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        store.setRemote(active: false, channels: [])
        log.info("RemoteWatcher stopped")
    }

    // MARK: - Tick

    /// `timeout` 와 `agentsActive` 는 메인 스레드(타이머 클로저 / `start()`)에서
    /// 미리 떠 온 `StateStore` 스냅샷이다. 이 메서드는 `pollQueue` 에서 도는데,
    /// `StateStore` 를 직접 읽으면 메인의 쓰기(`Set<String>` 재할당)와 경쟁해
    /// backing-buffer use-after-free 가 날 수 있어(P1) 인자로만 받는다.
    private func tick(timeout: Int, agentsActive: Bool) {
        // ADR-0016: 0 ⇒ the channel is off entirely.
        if timeout == 0 {
            resetGrace()
            store.setRemote(active: false, channels: [])
            return
        }

        // GUI / daemon / VPN channels never expire on idle: macOS itself asserts
        // PreventSystemSleep while a GUI session is connected, and we can't tell
        // whether a remote viewer is idle.
        var nonSSH: Set<String> = []
        nonSSH.formUnion(pmsetAssertionChannels())
        nonSSH.formUnion(tailscaleChannels())
        nonSSH.formUnion(daemonChannels())
        nonSSH.formUnion(remoteControlChannels())

        let (sshPresent, sshIdleMin) = whoRemote()
        let now = Date()
        if agentsActive { lastAgentActiveAt = now }

        if !nonSSH.isEmpty {
            var channels = nonSSH
            if sshPresent { channels.insert("ssh") }
            markBusy(now: now, channels: channels, idleMin: nil)
            return
        }

        // SSH-only path — governed by the idle knob (ADR-0016).
        if sshPresent {
            if timeout == StateStore.remoteIdleNever {
                markBusy(now: now, channels: ["ssh"], idleMin: nil)
                return
            }
            // "Idle" = the more recent of last tty input and last agent work.
            // A remote build keeps us awake (agent signal) even with a silent tty.
            let agentIdleMin = lastAgentActiveAt.map { now.timeIntervalSince($0) / 60 } ?? .infinity
            let effectiveIdle = min(agentIdleMin, sshIdleMin)
            if effectiveIdle >= Double(timeout) {
                log.info("remote SSH idle \(Int(effectiveIdle), privacy: .public)m ≥ \(timeout, privacy: .public)m — released")
                resetGrace()
                store.setRemote(active: false, channels: [])
                return
            }
            markBusy(now: now, channels: ["ssh"], idleMin: Int(effectiveIdle))
            return
        }

        // No remote channel at all — existing 60s flap grace.
        if let stamp = lastActiveAt, now.timeIntervalSince(stamp) < inactiveGrace {
            store.setRemote(active: true, channels: lastChannels)
            return
        }
        resetGrace()
        store.setRemote(active: false, channels: [])
    }

    private func markBusy(now: Date, channels: Set<String>, idleMin: Int?) {
        // Log only on a channel-set transition (markBusy fires every active tick).
        // Surfaces *which* signal is holding the Mac awake — useful when debugging
        // "why is it staying awake?" (e.g. `claude-remote` / `codex-remote` / `ssh`).
        if channels != lastChannels {
            log.info("remote active — channels: \(channels.sorted().joined(separator: ","), privacy: .public)")
        }
        lastActiveAt = now
        lastChannels = channels
        store.setRemote(active: true, channels: channels, idleMin: idleMin)
    }

    private func resetGrace() {
        lastActiveAt = nil
        lastChannels = []
    }

    // MARK: - Signal 1 — pmset assertions

    private func pmsetAssertionChannels() -> Set<String> {
        guard let text = Subprocess.capture("/usr/bin/pmset", ["-g", "assertions"],
                                            timeoutSeconds: 4) else { return [] }
        var found: Set<String> = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Lines like:
            //   pid 123(screensharingd): [...] NetworkClientActive named: "..."
            //   pid 456(ARDAgent): [...] PreventSystemSleep named: "..."
            //   pid 789(launchd): [...] PreventUserIdleSystemSleep named: "com.apple.NetworkSharing"
            // We grep loosely — false positives here just mean "stay awake",
            // which is the safe direction for a remote-session detector.
            let lower = line.lowercased()
            if lower.contains("networkclientactive") {
                found.insert("pmset:NetworkClient")
            }
            if lower.contains("preventsystemsleep") || lower.contains("preventuseridlesystemsleep") {
                if lower.contains("screensharing") {
                    found.insert("pmset:ScreenSharing")
                }
                if lower.contains("apple remote desktop") || lower.contains("ardagent") {
                    found.insert("pmset:ARD")
                }
                if lower.contains("networkclient") || lower.contains("com.apple.networksharing") {
                    found.insert("pmset:NetworkClient")
                }
            }
        }
        return found
    }

    // MARK: - Signal 2 — who (SSH idle-aware, ADR-0016)

    /// Whether any remote (SSH/ARD) login is present and, if so, the smallest
    /// tty idle time across those sessions (minutes). `who -u` columns are:
    ///   name  line  <Mon>  <day>  <HH:MM>  <idle>  <pid>  (host)
    /// The login date is always three tokens, so <idle> sits at index 5 of the
    /// whitespace split of everything before `(host)`. <idle> is `.` (active in
    /// the last minute), `HH:MM`, or `old` (>24h). Verified against macOS (BSD)
    /// `who -u`, including non-English locales (e.g. `6월  9 10:00`).
    private func whoRemote() -> (present: Bool, minIdleMin: Double) {
        guard let text = Subprocess.capture("/usr/bin/who", ["-u"],
                                            timeoutSeconds: 4) else { return (false, .infinity) }
        var present = false
        var minIdle = Double.infinity
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard let open = line.lastIndex(of: "("),
                  let close = line.lastIndex(of: ")"),
                  open < close else { continue }
            let host = String(line[line.index(after: open)..<close]).lowercased()
            if host.isEmpty || host == "console" || host == "tty" || host.hasPrefix(":0") { continue }
            guard looksRemoteHost(host) else { continue }
            present = true
            let toks = line[..<open].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let idle = toks.count >= 6 ? parseIdleMinutes(toks[5]) : 0
            minIdle = min(minIdle, idle)
        }
        guard present else { return (false, .infinity) }
        return (true, minIdle.isFinite ? minIdle : 0)
    }

    /// `.` ⇒ 0, `old` ⇒ a day, `HH:MM` ⇒ minutes. Anything unparseable is
    /// treated as busy (0) — the safe direction for a keep-awake detector.
    private func parseIdleMinutes(_ tok: String) -> Double {
        if tok == "." { return 0 }
        if tok.lowercased() == "old" { return 24 * 60 }
        let parts = tok.split(separator: ":")
        if parts.count == 2, let h = Double(parts[0]), let m = Double(parts[1]) {
            return h * 60 + m
        }
        return 0
    }

    private func looksRemoteHost(_ s: String) -> Bool {
        // IPv4: at least two dots and digits between.
        let dots = s.filter { $0 == "." }.count
        if dots >= 2 && s.contains(where: { $0.isNumber }) { return true }
        // IPv6: contains colon and hex.
        if s.contains(":") { return true }
        // Hostname-like: contains a dot and at least one letter.
        if dots >= 1 && s.contains(where: { $0.isLetter }) { return true }
        return false
    }

    // MARK: - Signal 3 — tailscale

    private static let tailscaleCandidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    private func tailscaleChannels() -> Set<String> {
        guard let bin = Self.tailscaleCandidates.first(where: { fileExists($0) }) else {
            return []
        }
        // tailscale CLI 는 tailscaled 와 소켓 IPC 하는 단일 프로세스(자식 포크
        // 없음)라 SIGKILL 회수로 충분. hung daemon/네트워크로 `status --json`
        // 이 무한 대기할 수 있는 가장 위험한 폴링 명령이라 타임아웃은 보수적
        // 으로 5s.
        guard let text = Subprocess.capture(bin, ["status", "--json"],
                                            timeoutSeconds: 5) else { return [] }
        // Minimal parse: look for any "RxBytes":nonzero or any peer with
        // "Active": true in the past minute. Forgiving — if any peer key
        // appears with an "Active": true we count it.
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // Self must be online for the channel to mean anything.
        if let me = any["Self"] as? [String: Any], (me["Online"] as? Bool) == false {
            return []
        }
        // Walk Peer dict; if any peer is currently active, count one channel.
        if let peers = any["Peer"] as? [String: Any] {
            for (_, peerAny) in peers {
                guard let peer = peerAny as? [String: Any] else { continue }
                if (peer["Active"] as? Bool) == true {
                    return ["tailscale"]
                }
            }
        }
        return []
    }

    // MARK: - Signal 4 — known daemon processes

    private static let daemonPattern =
        "screensharingd|ARDAgent|chrome_remote_desktop|anydesk|teamviewer"

    private func daemonChannels() -> Set<String> {
        guard let text = Subprocess.capture("/usr/bin/pgrep", ["-f", Self.daemonPattern],
                                            timeoutSeconds: 4) else { return [] }
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.isEmpty { return [] }
        return ["daemon"]
    }

    // MARK: - Signal 5 — agent remote-control daemons (ADR-0031)

    /// A coding agent driven via remote control (e.g. from the phone) is itself a
    /// remote-control surface, so we surface it on the remote channel rather than
    /// as a plain local agent. Detection is argv-only — no transcript contents —
    /// via the pure `ClaudeRemoteDetect` / `CodexRemoteDetect` classifiers (the
    /// Electron desktop apps and always-on backends are filtered out there).
    /// Treated like the other `nonSSH` channels (no idle expiry): while the
    /// host/worker/daemon process lives, the channel is active (subject only to
    /// the remote idle knob's 0 = off). A single `ps` scan feeds both detectors;
    /// `-ww` disables argv truncation so the long worker/daemon cmdlines survive.
    private func remoteControlChannels() -> Set<String> {
        guard let text = Subprocess.capture("/bin/ps", ["-axww", "-o", "command"],
                                            timeoutSeconds: 4) else { return [] }
        var channels: Set<String> = []
        if ClaudeRemoteDetect.isRemoteControlActive(psCommandOutput: text) {
            channels.insert("claude-remote")
        }
        if CodexRemoteDetect.isRemoteControlActive(psCommandOutput: text) {
            channels.insert("codex-remote")
        }
        return channels
    }

    // MARK: - Helpers

    private func fileExists(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0
    }

    // runCapture — Subprocess.capture로 통합 (TODO P2).
    // 기존 fileExists 선행 체크는 Process.run() throw 시 nil 반환으로 동일하게 커버됨.
}
