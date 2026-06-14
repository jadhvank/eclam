/// WeeklySummaryTests.swift — 경계 케이스 검증 (일회성 하니스)
///
/// `AwakeStats.summarize(episodes:current:since:now:)` 순수 함수의
/// 1) 7일 창 경계 걸침 에피소드 클리핑
/// 2) 진행 중(ongoing) 에피소드 포함
/// 3) safety trip 카운트
///
/// 실행 (scripts/test.sh): SafetyPolicy.swift + AwakeEpisode.swift 와 함께
/// 단독 컴파일 — AwakeHistoryStore(OSLog·StateStore 결합)는 끌고 오지 않는다.

import Foundation

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers

func ep(start: TimeInterval, end: TimeInterval?, cause: AwakeStartCause = .manual,
        reason: AwakeEndReason? = nil, clam: TimeInterval = 0) -> AwakeEpisode {
    let e = AwakeEpisode(id: UUID(), startedAt: Date(timeIntervalSinceReferenceDate: start),
                         endedAt: end.map { Date(timeIntervalSinceReferenceDate: $0) },
                         clamshellSeconds: clam,
                         startCause: cause,
                         startDetail: nil,
                         endReason: reason,
                         endDetail: nil)
    return e
}

var passCount = 0
var failCount = 0

func assert(_ cond: Bool, _ msg: String) {
    if cond {
        print("  ✓ \(msg)")
        passCount += 1
    } else {
        print("  ✗ FAIL: \(msg)")
        failCount += 1
    }
}

func approxEqual(_ a: TimeInterval, _ b: TimeInterval, tol: TimeInterval = 1.0) -> Bool {
    abs(a - b) <= tol
}

@main
enum WeeklySummaryTestMain {
    static func main() {
        // Reference "now" = t=0 ; window = t=-604800 … t=0 (7 days = 604800s)
        let now   = Date(timeIntervalSinceReferenceDate: 0)
        let since = Date(timeIntervalSinceReferenceDate: -604800)

        // ──────────────────────────────────────────────────────────────────────────────
        // MARK: - Test 1: episode entirely outside window (too old)

        print("\n[Test 1] 윈도우 바깥 에피소드 제외")
        let t1 = AwakeStats.summarize(
            episodes: [ep(start: -700000, end: -650000)],
            current: nil, since: since, now: now)
        assert(t1.totalAwake == 0, "totalAwake == 0")
        assert(t1.safetyTrips == 0, "safetyTrips == 0")

        // ──────────────────────────────────────────────────────────────────────────────
        // MARK: - Test 2: episode straddles the left boundary (started before window)

        print("\n[Test 2] 창 왼쪽 경계 걸침 — 창 내 부분만 카운트")
        // episode: t=-700000 … t=-500000 → full=200000s, window covers -604800…-500000 = 104800s
        let straddle = ep(start: -700000, end: -500000, cause: .agent, clam: 100_000)
        let t2 = AwakeStats.summarize(
            episodes: [straddle], current: nil, since: since, now: now)
        let expectedDur: TimeInterval = 604800 - 500000  // = 104800
        assert(approxEqual(t2.totalAwake, expectedDur), "totalAwake ≈ \(Int(expectedDur))s (got \(Int(t2.totalAwake)))")
        // clamshell prorated: 100000 * (104800/200000) = 52400
        let expectedClam: TimeInterval = 100_000 * (104800.0 / 200_000.0)
        assert(approxEqual(t2.clamshell, expectedClam), "clamshell prorated ≈ \(Int(expectedClam))s (got \(Int(t2.clamshell)))")
        assert(approxEqual(t2.byAgent, expectedDur), "byAgent == totalAwake (cause=.agent)")

        // ──────────────────────────────────────────────────────────────────────────────
        // MARK: - Test 3: ongoing episode (endedAt == nil)

        print("\n[Test 3] 진행 중 에피소드 (endedAt == nil)")
        // started 2h ago, still running; 7200s should count
        var ongoing = ep(start: -7200, end: nil, cause: .manual, clam: 1800)
        ongoing.endedAt = nil  // already nil, belt+braces
        let t3 = AwakeStats.summarize(
            episodes: [], current: ongoing, since: since, now: now)
        assert(approxEqual(t3.totalAwake, 7200), "totalAwake ≈ 7200 (got \(Int(t3.totalAwake)))")
        assert(approxEqual(t3.clamshell, 1800), "clamshell == 1800 (got \(Int(t3.clamshell)))")
        assert(t3.byAgent == 0, "byAgent == 0 (cause=.manual)")

        // ──────────────────────────────────────────────────────────────────────────────
        // MARK: - Test 4: safety trips counted correctly

        print("\n[Test 4] safety trip 카운트")
        let trips = [
            ep(start: -86400, end: -80000, reason: .batteryLow),
            ep(start: -70000, end: -65000, reason: .thermalSerious),
            ep(start: -60000, end: -55000, reason: .thermalCritical),
            ep(start: -50000, end: -45000, reason: .timer),
            ep(start: -40000, end: -35000, reason: .watchdog),
            ep(start: -30000, end: -25000, reason: .manualOff),   // NOT a safety trip
        ]
        let t4 = AwakeStats.summarize(
            episodes: trips, current: nil, since: since, now: now)
        assert(t4.safetyTrips == 5, "safetyTrips == 5 (got \(t4.safetyTrips))")

        // ──────────────────────────────────────────────────────────────────────────────
        // MARK: - Test 5: episode entirely inside window

        print("\n[Test 5] 창 내 에피소드 전체 카운트")
        let inner = ep(start: -3600, end: -1800, cause: .agent, clam: 900)
        let t5 = AwakeStats.summarize(
            episodes: [inner], current: nil, since: since, now: now)
        assert(approxEqual(t5.totalAwake, 1800), "totalAwake == 1800")
        assert(approxEqual(t5.clamshell, 900),   "clamshell == 900")
        assert(approxEqual(t5.byAgent, 1800),    "byAgent == 1800")

        // ──────────────────────────────────────────────────────────────────────────────
        print("\n결과: \(passCount) 통과, \(failCount) 실패")
        exit(failCount > 0 ? 1 : 0)
    }
}
