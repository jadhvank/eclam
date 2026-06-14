/// AgentActivityTests.swift — AgentDetector 활동 판정 순수 계층 검증 (L1, ADR-0006 §A/§C/§J/§L).
///
/// 1) hookDecision: hook-ping grace 경계(직전/직후) + PID-file 폴백 순서
/// 2) mtimeDecision: freshness 컷 경계 + Claude §J 워크스페이스 페어링 진리표
/// 3) decide: hook 채널 short-circuit(mtime 무시) + hookKey 게이트 + 세 신호 조합
///
/// 실행 (scripts/test.sh): AgentActivity.swift 와 함께 단독 컴파일 —
/// AgentDetector(Darwin notify·ps/lsof·Timer 결합)는 끌고 오지 않는다.

import Foundation

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

func expect(_ got: AgentActivity.Decision, active: Bool, reason: String, _ label: String) {
    let ok = got.active == active && got.reason == reason
    assert(ok, "\(label) ⇒ active=\(got.active) reason=\"\(got.reason)\""
              + (ok ? "" : " (want active=\(active) reason=\"\(reason)\")"))
}

/// `hookDecision` 처럼 `Decision?` 를 돌려주는 경로용 오버로드 — nil 은 실패.
func expect(_ got: AgentActivity.Decision?, active: Bool, reason: String, _ label: String) {
    guard let got = got else {
        assert(false, "\(label) ⇒ nil (want active=\(active) reason=\"\(reason)\")")
        return
    }
    expect(got, active: active, reason: reason, label)
}

func expectNil(_ got: AgentActivity.Decision?, _ label: String) {
    assert(got == nil, "\(label) ⇒ \(got.map { "active=\($0.active) reason=\($0.reason)" } ?? "nil")")
}

func match(_ age: TimeInterval) -> AgentActivity.MtimeMatch {
    AgentActivity.MtimeMatch(path: "/p/x.jsonl", age: age)
}

func testHookChannel() {
    print("── hookDecision (grace=30)")
    expectNil(AgentActivity.hookDecision(hookPingAge: nil, hookGrace: 30, pidFilePresent: false),
              "ping 없음 + pidfile 없음 ⇒ 폴스루(nil)")
    expect(AgentActivity.hookDecision(hookPingAge: 29, hookGrace: 30, pidFilePresent: false),
           active: true, reason: "hook-ping (29s)", "ping 29s (grace 직전)")
    expect(AgentActivity.hookDecision(hookPingAge: 30, hookGrace: 30, pidFilePresent: false),
           active: true, reason: "hook-ping (30s)", "ping 30s (grace 경계 ⇒ 포함)")
    expectNil(AgentActivity.hookDecision(hookPingAge: 31, hookGrace: 30, pidFilePresent: false),
              "ping 31s (grace 직후) + pidfile 없음 ⇒ 폴스루")
    expect(AgentActivity.hookDecision(hookPingAge: 31, hookGrace: 30, pidFilePresent: true),
           active: true, reason: "pidfile-ping", "ping 만료지만 pidfile 신선 ⇒ pidfile-ping")
    expect(AgentActivity.hookDecision(hookPingAge: nil, hookGrace: 30, pidFilePresent: true),
           active: true, reason: "pidfile-ping", "ping 없음 + pidfile ⇒ pidfile-ping")
    // ping 우선순위: 둘 다 신선하면 hook-ping 이 먼저.
    expect(AgentActivity.hookDecision(hookPingAge: 5, hookGrace: 30, pidFilePresent: true),
           active: true, reason: "hook-ping (5s)", "ping+pidfile 둘 다 ⇒ hook-ping 우선")
}

func testMtimeChannelNonClaude() {
    print("── mtimeDecision 비-Claude (freshness=60)")
    expect(AgentActivity.mtimeDecision(mtimeMatch: nil, freshness: 60, isClaude: false,
                                       liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: false, reason: "no-match", "매치 없음 ⇒ no-match")
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(59), freshness: 60, isClaude: false,
                                       liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: true, reason: "mtime-fresh", "age 59 (freshness 직전) ⇒ fresh")
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(60), freshness: 60, isClaude: false,
                                       liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: true, reason: "mtime-fresh", "age 60 (경계 ⇒ fresh)")
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(61), freshness: 60, isClaude: false,
                                       liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: false, reason: "stale", "age 61 (freshness 직후) ⇒ stale")
}

func testMtimeChannelClaudePairing() {
    print("── mtimeDecision Claude §J 페어링 진리표 (fresh 전제)")
    // ps/lsof 불가 ⇒ permissive 폴백.
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(10), freshness: 60, isClaude: true,
                                       liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: true, reason: "mtime-fresh (claude pairing skipped — ps/lsof unavailable)",
           "liveClaude 비어있음 ⇒ 페어링 스킵(active)")
    // cwd 매치 ⇒ active + segment reason.
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(10), freshness: 60, isClaude: true,
                                       liveClaudeEmpty: false, claudeCwdMatched: true,
                                       claudeSegment: "-Users-me-proj"),
           active: true, reason: "mtime-fresh + cwd -Users-me-proj", "cwd 매치 ⇒ active + segment")
    // 매치 실패 ⇒ inactive.
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(10), freshness: 60, isClaude: true,
                                       liveClaudeEmpty: false, claudeCwdMatched: false,
                                       claudeSegment: "-Users-me-proj"),
           active: false, reason: "mtime-fresh but no live cwd match", "live cwd 불일치 ⇒ inactive")
    // segment nil 이면 매치 플래그가 켜져 있어도 inactive (방어적 계약).
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(10), freshness: 60, isClaude: true,
                                       liveClaudeEmpty: false, claudeCwdMatched: true, claudeSegment: nil),
           active: false, reason: "mtime-fresh but no live cwd match", "segment nil ⇒ inactive")
    // stale 면 Claude 페어링 분기 이전에 차단.
    expect(AgentActivity.mtimeDecision(mtimeMatch: match(61), freshness: 60, isClaude: true,
                                       liveClaudeEmpty: false, claudeCwdMatched: true,
                                       claudeSegment: "-Users-me-proj"),
           active: false, reason: "stale", "Claude라도 stale 먼저 차단")
}

func testComposedShortCircuit() {
    print("── decide: hook short-circuit + hookKey 게이트 + 조합")
    // hook 신선 ⇒ mtime(fresh)이 있어도 hook-ping 이 이긴다 (short-circuit).
    expect(AgentActivity.decide(hasHookKey: true, hookPingAge: 10, hookGrace: 30, pidFilePresent: false,
                                mtimeMatch: match(5), freshness: 60, isClaude: false,
                                liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: true, reason: "hook-ping (10s)", "hook 신선 ⇒ mtime 무시(short-circuit)")
    // hook 만료 + pidfile 없음 ⇒ mtime 채널로 폴스루.
    expect(AgentActivity.decide(hasHookKey: true, hookPingAge: 99, hookGrace: 30, pidFilePresent: false,
                                mtimeMatch: match(5), freshness: 60, isClaude: false,
                                liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: true, reason: "mtime-fresh", "hook 만료 ⇒ mtime 폴스루")
    // hookKey 없음 ⇒ ping 값이 있어도 hook 채널 자체를 건너뛴다.
    expect(AgentActivity.decide(hasHookKey: false, hookPingAge: 5, hookGrace: 30, pidFilePresent: true,
                                mtimeMatch: nil, freshness: 60, isClaude: false,
                                liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: false, reason: "no-match", "hookKey 없음 ⇒ hook 채널 게이트 차단")
    // 세 신호 모두 죽음 ⇒ no-match.
    expect(AgentActivity.decide(hasHookKey: true, hookPingAge: nil, hookGrace: 30, pidFilePresent: false,
                                mtimeMatch: nil, freshness: 60, isClaude: false,
                                liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: false, reason: "no-match", "전부 비활성 ⇒ no-match")
    // pidfile 만 살아있음 ⇒ pidfile-ping.
    expect(AgentActivity.decide(hasHookKey: true, hookPingAge: nil, hookGrace: 30, pidFilePresent: true,
                                mtimeMatch: nil, freshness: 60, isClaude: false,
                                liveClaudeEmpty: true, claudeCwdMatched: false, claudeSegment: nil),
           active: true, reason: "pidfile-ping", "pidfile만 ⇒ pidfile-ping")
}

@main
enum AgentActivityTestMain {
    static func main() {
        testHookChannel()
        testMtimeChannelNonClaude()
        testMtimeChannelClaudePairing()
        testComposedShortCircuit()

        print("")
        print("AgentActivity tests: \(passCount) passed, \(failCount) failed")
        exit(failCount == 0 ? 0 : 1)
    }
}
