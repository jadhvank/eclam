// AwakeEpisode.swift — history 의 순수 데이터 계층 (proposal §1 분리).
//
// `AwakeHistoryStore`(OSLog·StateStore 결합)에서 타입과 주간 집계 순수 함수를
// 분리해 `scripts/test.sh` 가 SafetyPolicy.swift 와 함께 단독 컴파일할 수 있게
// 한다 (Tests/WeeklySummaryTests.swift). Foundation 만 사용.

import Foundation

enum AwakeStartCause: String, Codable {
    case manual   // user toggle (left-click / CLI `on`)
    case agent    // a watched agent became active
    case remote   // a remote-control channel became active
    case unknown
}

enum AwakeEndReason: String, Codable {
    case manualOff          // user turned the toggle off
    case forceSleep         // user clicked off while an agent/remote was holding (suppressed the auto signal)
    case agentCeased        // the last active agent stopped working
    case remoteEnded        // remote session ended (network still up)
    case remoteNetworkLost  // remote session dropped AND no network route — "Wi-Fi turned off"
    case batteryLow
    case thermalSerious
    case thermalCritical
    case timer              // max-duration safety cap
    case watchdog           // helper watchdog tripped
    case appQuit            // app terminated while awake
    case unknown
}

struct AwakeEpisode: Codable, Equatable {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date?                 // nil ⇒ ongoing
    var clamshellSeconds: TimeInterval = 0   // accumulated lid-closed time within the episode
    var startCause: AwakeStartCause
    var startDetail: String?           // e.g. "claude" or "ssh,tailscale"
    var endReason: AwakeEndReason?     // nil while ongoing
    var endDetail: String?             // e.g. "18%" or "60m"

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var isOngoing: Bool { endedAt == nil }
}

extension SafetyReason {
    /// Single mapping into the history log's end reason. Exhaustive: adding a
    /// `SafetyReason` case fails compilation here, instead of silently falling
    /// through the hand-written cross-enum translation `attribute` used to
    /// carry (the only non-exhaustive seam among the reason switches —
    /// docs/TODO.md P2). Lives here (not SafetyPolicy.swift) because
    /// `AwakeEndReason` isn't part of the framework-free test target.
    var asEndReason: AwakeEndReason {
        switch self {
        case .batteryLow:      return .batteryLow
        case .thermalSerious:  return .thermalSerious
        case .thermalCritical: return .thermalCritical
        case .timer:           return .timer
        case .watchdog:        return .watchdog
        }
    }
}


/// proposal §1 — 주간 집계 순수 함수의 집.
enum AwakeStats {
    // MARK: - Weekly summary (proposal §1)

    /// Rolling 7-day aggregate. Episodes that straddle the window boundary are
    /// clipped so only the portion inside the window is counted.
    struct WeeklySummary {
        var totalAwake: TimeInterval   // sum of awake seconds in the last 7 days
        var byAgent: TimeInterval      // subset: startCause == .agent
        var clamshell: TimeInterval    // lid-closed seconds in the last 7 days
        var safetyTrips: Int           // endReason ∈ {batteryLow, thermalSerious, thermalCritical, timer, watchdog}
    }

    /// Pure function — testable without instantiating the store.
    /// - Parameters:
    ///   - episodes: Ended episodes (oldest-first).
    ///   - current: Ongoing episode or nil, with live clamshellSeconds already folded in.
    ///   - since: Window start (= now − 7 days).
    ///   - now: Window end / effective "now" for the ongoing episode.
    static func summarize(episodes: [AwakeEpisode],
                          current: AwakeEpisode?,
                          since: Date,
                          now: Date) -> WeeklySummary {
        var totalAwake: TimeInterval = 0
        var byAgent: TimeInterval = 0
        var clamshell: TimeInterval = 0
        var safetyTrips: Int = 0

        let safetyReasons: Set<AwakeEndReason> = [
            .batteryLow, .thermalSerious, .thermalCritical, .timer, .watchdog
        ]

        // Build a flat list: ended episodes + ongoing (if any)
        var all = episodes
        if let c = current { all.append(c) }

        for ep in all {
            let epStart = ep.startedAt
            let epEnd   = ep.endedAt ?? now

            // Discard episodes entirely outside the window
            guard epEnd > since && epStart < now else { continue }

            // Clip to the window
            let clippedStart = max(epStart, since)
            let clippedEnd   = min(epEnd,   now)
            let windowDur    = clippedEnd.timeIntervalSince(clippedStart)
            guard windowDur > 0 else { continue }

            // Prorate clamshell seconds to the clipped portion
            let fullDur = epEnd.timeIntervalSince(epStart)
            let ratio   = fullDur > 0 ? windowDur / fullDur : 0
            let clippedClam = ep.clamshellSeconds * ratio

            totalAwake += windowDur
            clamshell  += clippedClam
            if ep.startCause == .agent { byAgent += windowDur }
            if let r = ep.endReason, safetyReasons.contains(r) { safetyTrips += 1 }
        }

        return WeeklySummary(totalAwake: totalAwake,
                             byAgent: byAgent,
                             clamshell: clamshell,
                             safetyTrips: safetyTrips)
    }


}

/// 기존 호출부 호환: `AwakeHistoryStore.weeklySummary` 반환 타입 명칭 유지.
typealias WeeklySummary = AwakeStats.WeeklySummary
