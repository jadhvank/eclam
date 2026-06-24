// HelperHealth 순수 판정 테스트 (handoff 2026-06-24 — helper liveness honest status).
// swiftc 단독 컴파일: Sources/Shared/HelperHealth.swift 와 함께 (scripts/test.sh).
// (stdlib-only 제약은 대상 소스에만 — 테스트 파일은 Darwin/Foundation 사용 가능.)

import Foundation

var exitCode: Int32 = 0

func assertEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got != want {
        print("FAIL: \(label) — got \(got), want \(want)")
        exitCode = 1
    }
}

func assertTrue(_ cond: Bool, _ label: String) {
    if !cond {
        print("FAIL: \(label)")
        exitCode = 1
    }
}

// 핵심 회귀 — `.enabled` 인데 XPC 도달 불가면 거짓 양성 대신 정직한 신호:
// human 에 repair 힌트, exit 2. raw(JSON helperStatus)는 "enabled" 그대로 보존.
func testEnabledUnreachable() {
    let v = HelperHealth.evaluate(reg: .enabled, reachable: false)
    assertEqual(v.raw, "enabled", "unreachable: raw stays 'enabled' (JSON back-compat)")
    assertEqual(v.reachable, false, "unreachable: reachable=false")
    assertEqual(v.exit, 2, "unreachable: exit 2")
    assertTrue(v.human.contains(HelperHealth.unreachableHint),
               "unreachable: human carries the repair hint")
    assertTrue(v.human.contains("enabled"), "unreachable: human still mentions enabled")
    print("OK: enabled + unreachable")
}

// 살아있는 helper — 기존 동작 그대로(exit 0, human == raw == "enabled").
func testEnabledReachable() {
    let v = HelperHealth.evaluate(reg: .enabled, reachable: true)
    assertEqual(v.raw, "enabled", "reachable: raw")
    assertEqual(v.human, "enabled", "reachable: human == raw (no hint)")
    assertEqual(v.reachable, true, "reachable: reachable=true")
    assertEqual(v.exit, 0, "reachable: exit 0")
    print("OK: enabled + reachable")
}

// 프로브를 돌리지 않은 경우(reachable=nil)도 enabled 는 exit 0 — 프로브 생략이
// 거짓 unreachable 로 새지 않는다.
func testEnabledUnprobed() {
    let v = HelperHealth.evaluate(reg: .enabled, reachable: nil)
    assertEqual(v.human, "enabled", "unprobed: human == 'enabled'")
    assertEqual(v.exit, 0, "unprobed: exit 0")
    assertTrue(v.reachable == nil, "unprobed: reachable=nil")
    print("OK: enabled + unprobed (nil)")
}

// 비-enabled 상태는 전부 exit 0 (CI smoke.sh 가 미등록 러너에서 `eclam status`
// 를 돌리고 비정상 종료에 실패하므로 — 이 불변식이 깨지면 CI 가 깨진다).
func testNonEnabledStatesStayExitZero() {
    for reg in [HelperReg.requiresApproval, .notRegistered, .notFound, .unknown] {
        let v = HelperHealth.evaluate(reg: reg, reachable: nil)
        assertEqual(v.exit, 0, "\(reg.rawValue): exit stays 0 (CI smoke invariant)")
        assertEqual(v.raw, reg.rawValue, "\(reg.rawValue): raw == rawValue")
        assertEqual(v.human, reg.rawValue, "\(reg.rawValue): human unchanged from today")
        assertTrue(v.reachable == nil, "\(reg.rawValue): reachable=nil")
    }
    print("OK: non-enabled states stay exit 0")
}

// 방어적: reachable 인자가 비-enabled 상태에 잘못 전달돼도(false) exit 0 유지 —
// 도달성 판정은 오직 .enabled 에서만 의미가 있다.
func testReachabilityIgnoredWhenNotEnabled() {
    let v = HelperHealth.evaluate(reg: .notRegistered, reachable: false)
    assertEqual(v.exit, 0, "notRegistered ignores stray reachable=false")
    print("OK: reachability ignored when not enabled")
}

@main
enum HelperHealthTestMain {
    static func main() {
        testEnabledUnreachable()
        testEnabledReachable()
        testEnabledUnprobed()
        testNonEnabledStatesStayExitZero()
        testReachabilityIgnoredWhenNotEnabled()
        if exitCode != 0 {
            print("FAILED: HelperHealth suite")
            exit(exitCode)
        }
        print("OK: all HelperHealth suites")
    }
}
