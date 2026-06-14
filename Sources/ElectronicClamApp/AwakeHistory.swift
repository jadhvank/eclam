import Darwin
import Foundation
import OSLog

/// ADR-0013 — Awake history.
///
/// Records one `AwakeEpisode` per contiguous "keep-awake on" streak: when it
/// started, how long the lid was closed (clamshell) during it, and — when it
/// ends — *why* it ended (thermal / battery / manual / remote-network-lost / …).
///
/// This is pure app-side observation. It never touches the helper, XPC, or the
/// power state; it only watches `StateStore` transitions surfaced by the
/// convergence engine (`AppDelegate.convergeNow`). Persisted locally to
/// Application Support so the log survives relaunch and reboot.

/// Owns the episode log + the in-flight episode. Single-threaded: every entry
/// point is invoked on the main thread (convergence engine + Settings pane).
final class AwakeHistoryStore {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "history")
    private static let maxEpisodes = 50

    /// Ended episodes, oldest first.
    private(set) var episodes: [AwakeEpisode] = []
    /// The ongoing episode, if currently awake.
    private(set) var current: AwakeEpisode?
    /// When the lid last closed during the current episode (nil ⇒ lid open).
    private var lidClosedSince: Date?
    /// Snapshot of what was holding awake on the previous `awake==true` tick;
    /// used to attribute the end reason on the falling edge.
    private var lastHolders: Holders?

    private struct Holders {
        var manualToggle: Bool
        var remoteActive: Bool
        var agentsActive: Bool
        var agentDetail: String?
        var remoteDetail: String?
    }

    /// ADR-0028 — 에피소드 전환 탭. 시작 원인·종료 사유 귀속이 끝난 뒤
    /// 불린다 (TelegramNotifier 가 유일한 구독자; 메인 스레드).
    /// History 는 여전히 순수 관찰자 — 구독자가 무엇을 하든 관여하지 않는다.
    var onEpisodeStart: ((AwakeEpisode) -> Void)?
    var onEpisodeEnd: ((AwakeEpisode) -> Void)?

    init() { load() }

    // MARK: - Observation (called from AppDelegate.convergeNow, main thread)

    /// Feed the current converged state. Detects rising/falling awake edges and
    /// accumulates clamshell time on lid edges.
    func observe(awake: Bool, lidClosed: Bool, store: StateStore, now: Date = Date()) {
        if awake {
            if current == nil {
                startEpisode(store: store, lidClosed: lidClosed, now: now)
            } else {
                updateLid(closed: lidClosed, now: now)
                lastHolders = snapshot(store)
            }
        } else if current != nil {
            updateLid(closed: false, now: now)   // flush any open lid interval
            let (reason, detail) = attribute(store: store)
            endEpisode(reason: reason, detail: detail, now: now)
        }
    }

    /// Close the ongoing episode as `appQuit` (called from applicationWillTerminate).
    func noteAppQuit(now: Date = Date()) {
        guard current != nil else { return }
        updateLid(closed: false, now: now)
        endEpisode(reason: .appQuit, detail: nil, now: now)
    }

    /// Instance convenience — delegates to the pure `AwakeStats.summarize`
    /// (분리 이유: 테스트 harness 단독 컴파일 — AwakeEpisode.swift 참고).
    func weeklySummary(now: Date = Date()) -> WeeklySummary {
        return AwakeStats.summarize(episodes: episodes,
                                    current: liveCurrent(now: now),
                                    since: now.addingTimeInterval(-7 * 24 * 3600),
                                    now: now)
    }

    // MARK: - Reads (Settings pane)

    /// Live view of the ongoing episode, with the in-progress lid interval folded in.
    func liveCurrent(now: Date = Date()) -> AwakeEpisode? {
        guard var c = current else { return nil }
        if let since = lidClosedSince { c.clamshellSeconds += now.timeIntervalSince(since) }
        return c
    }

    /// Rows for the log table: ongoing episode first, then ended episodes newest-first.
    func displayRows(now: Date = Date()) -> [AwakeEpisode] {
        var rows: [AwakeEpisode] = []
        if let live = liveCurrent(now: now) { rows.append(live) }
        rows.append(contentsOf: episodes.reversed())
        return rows
    }

    /// Clear the past log. Keeps the ongoing episode (it represents "now").
    func clear() {
        episodes.removeAll()
        save()
    }

    // MARK: - Episode lifecycle

    private func startEpisode(store: StateStore, lidClosed: Bool, now: Date) {
        let cause: AwakeStartCause
        var detail: String?
        if store.manualToggle {
            cause = .manual
        } else if store.remoteCountsAsActivity && store.remoteActive {
            cause = .remote
            detail = store.remoteChannels.sorted().joined(separator: ",")
        } else if !store.activeAgents.isEmpty {
            cause = .agent
            detail = store.activeAgents.sorted().joined(separator: ",")
        } else {
            cause = .unknown
        }
        let started = store.keepAwakeSince ?? now
        current = AwakeEpisode(startedAt: started, startCause: cause, startDetail: detail)
        // Seed from the observation time, not the (possibly backdated)
        // `keepAwakeSince` start: we only *know* the lid is closed now.
        // Seeding from `started` credited lid-closed time we never measured,
        // overstating clamshellSeconds.
        lidClosedSince = lidClosed ? now : nil
        lastHolders = snapshot(store)
        log.info("episode start cause=\(cause.rawValue, privacy: .public)")
        if let c = current { onEpisodeStart?(c) }
    }

    private func endEpisode(reason: AwakeEndReason, detail: String?, now: Date) {
        guard var c = current else { return }
        c.endedAt = now
        c.endReason = reason
        c.endDetail = detail
        episodes.append(c)
        if episodes.count > Self.maxEpisodes {
            episodes.removeFirst(episodes.count - Self.maxEpisodes)
        }
        current = nil
        lidClosedSince = nil
        lastHolders = nil
        save()
        log.info("episode end reason=\(reason.rawValue, privacy: .public) clamshell=\(Int(c.clamshellSeconds), privacy: .public)s")
        onEpisodeEnd?(c)
    }

    private func updateLid(closed: Bool, now: Date) {
        guard current != nil else { return }
        if closed {
            if lidClosedSince == nil { lidClosedSince = now }
        } else if let since = lidClosedSince {
            current?.clamshellSeconds += now.timeIntervalSince(since)
            lidClosedSince = nil
        }
    }

    private func snapshot(_ store: StateStore) -> Holders {
        Holders(
            manualToggle: store.manualToggle,
            remoteActive: store.remoteActive,
            agentsActive: !store.activeAgents.isEmpty,
            agentDetail: store.activeAgents.isEmpty ? nil : store.activeAgents.sorted().joined(separator: ","),
            remoteDetail: store.remoteChannels.isEmpty ? nil : store.remoteChannels.sorted().joined(separator: ","))
    }

    // MARK: - End-reason attribution (priority order)

    private func attribute(store: StateStore) -> (AwakeEndReason, String?) {
        let prev = lastHolders
        // 1) The user turned the manual hold off *this tick* (manualToggle
        //    flipped true→false — only the user's click does that; a safety
        //    release leaves manualToggle untouched). Unambiguous user intent
        //    wins even when a safety release lands in the same converge tick:
        //    checking `safetyRelease` first mislabeled such a simultaneous
        //    toggle-off as a safety trip. The left-click toggle also sets
        //    manualOverrideOff for a plain manual session (ADR-0014), so this
        //    must stay above the force-sleep branch — otherwise every ordinary
        //    toggle-off would read "force sleep".
        if prev?.manualToggle == true && !store.manualToggle { return (.manualOff, nil) }
        // 2) Force-sleep: the user clicked away an *auto* signal (an agent/remote
        //    was holding, no manual toggle) — manualOverrideOff suppressed it.
        //    Only the click path sets that flag, so it too is a this-tick user
        //    action and precedes the safety attribution.
        if store.manualOverrideOff { return (.forceSleep, nil) }
        // 3) Safety override — it forced shouldKeepAwake false. Reason mapping
        //    goes through `SafetyReason.asEndReason` (single, exhaustive seam);
        //    only the detail string is derived per-reason here.
        if let r = store.safetyRelease {
            let detail: String?
            switch r {
            case .batteryLow:      detail = store.batteryPercent.map { "\($0)%" }
            case .thermalSerious,
                 .thermalCritical: detail = thermalDetail(store)
            case .timer:
                let m = store.safetySettings.maxDurationMin
                detail = m > 0 ? "\(m)m" : nil
            case .watchdog:        detail = nil
            }
            return (r.asEndReason, detail)
        }
        // 4) Remote channel dropped — distinguish "session ended" vs "network/Wi-Fi lost".
        if prev?.remoteActive == true && !store.remoteActive {
            let online = Self.hasRoutableInterface()
            return (online ? .remoteEnded : .remoteNetworkLost, prev?.remoteDetail)
        }
        // 5) The last active agent stopped working.
        if prev?.agentsActive == true && store.activeAgents.isEmpty {
            return (.agentCeased, prev?.agentDetail)
        }
        return (.unknown, nil)
    }

    /// Temperature/severity detail for a thermal auto-release, so the history log
    /// records *how hot* it was (e.g. "87°C"), not just "thermal".
    private func thermalDetail(_ store: StateStore) -> String? {
        // Prefer the SoC sensors (CPU/GPU) that actually drive the thermal state;
        // battery °C runs much cooler and would understate a thermal trip.
        let soc = [store.cpuTempCelsius, store.gpuTempCelsius].compactMap { $0 }
        if let peak = soc.max() {
            return String(format: "%.0f°C", peak)
        }
        // No SMC reading (Intel / unsupported) — fall back to the severity label.
        if let p = store.thermalPressureLevel, p >= 3 {
            return SafetyMonitor.thermalPressureLabel(p)
        }
        switch store.thermalState {
        case .serious:  return "serious"
        case .critical: return "critical"
        default:        return nil
        }
    }

    // MARK: - Network reachability (getifaddrs, no extra framework)

    /// True if any non-loopback interface is UP+RUNNING with a routable (non
    /// link-local) IPv4/IPv6 address. When the user turns Wi-Fi off, en0 loses
    /// its carrier/address and — absent Ethernet — this returns false, which is
    /// how `remoteNetworkLost` is told apart from a normal `remoteEnded`.
    static func hasRoutableInterface() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var ptr = head
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let sa = p.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            guard let ip = Self.numericHost(sa) else { continue }
            let lower = ip.lowercased()
            if lower.hasPrefix("169.254.") || lower.hasPrefix("fe80") { continue } // link-local
            if lower.hasPrefix("127.") || lower == "::1" { continue }              // loopback (belt+braces)
            return true
        }
        return false
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let res = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST)
        return res == 0 ? String(cString: host) : nil
    }

    // MARK: - Persistence (atomic JSON in ~/Library/Application Support/eclam/)

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("eclam", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func load() {
        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AwakeEpisode].self, from: data) else { return }
        episodes = decoded
        if episodes.count > Self.maxEpisodes {
            episodes.removeFirst(episodes.count - Self.maxEpisodes)
        }
    }

    private func save() {
        guard let url = Self.fileURL else { return }
        guard let data = try? JSONEncoder().encode(episodes) else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { log.error("history save failed: \(error.localizedDescription, privacy: .public)") }
    }
}
