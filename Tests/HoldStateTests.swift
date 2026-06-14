// P3 — HoldManager 영속 포맷(HoldState) 테스트.
// swiftc 단독 컴파일: Sources/Shared/HoldState.swift 와 함께 (scripts/test.sh).
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

// P3① — serialize 는 force-unwrap 없이 forever/finite 를 분기한다.
func testSerializeForever() {
    // forever 이면 holdUntil 값과 무관하게 "forever".
    assertEqual(HoldState.serialize(forever: true, holdUntil: nil), "forever",
                "serialize(forever, nil)")
    assertEqual(HoldState.serialize(forever: true, holdUntil: Date(timeIntervalSince1970: 123)),
                "forever", "serialize(forever, date)")
    print("OK: serialize forever")
}

func testSerializeFinite() {
    let d = Date(timeIntervalSince1970: 1_700_000_000)
    assertEqual(HoldState.serialize(forever: false, holdUntil: d),
                String(1_700_000_000.0), "serialize(finite)")
    print("OK: serialize finite")
}

// P3① 핵심 — finite 인데 holdUntil 이 nil (arm() 불변식상 도달 불가) 이어도
// force-unwrap 크래시 없이 now 폴백으로 유효한 토큰을 낸다.
func testSerializeFiniteNilFallsBackToNow() {
    let now = Date(timeIntervalSince1970: 1_650_000_000)
    let out = HoldState.serialize(forever: false, holdUntil: nil, now: now)
    assertEqual(out, String(1_650_000_000.0), "serialize(finite, nil) falls back to now")
    // 폴백 결과는 다시 파싱 가능해야 한다 (깨진 토큰을 쓰지 않음).
    assertEqual(HoldState.parse(out), .until(epoch: 1_650_000_000.0),
                "fallback token round-trips")
    print("OK: serialize finite nil → now fallback")
}

func testParse() {
    assertEqual(HoldState.parse("forever"), .forever, "parse(forever)")
    assertEqual(HoldState.parse("  forever \n"), .forever, "parse(forever w/ whitespace)")
    assertEqual(HoldState.parse("1700000000.0"), .until(epoch: 1_700_000_000.0),
                "parse(epoch)")
    assertEqual(HoldState.parse(" 42 "), .until(epoch: 42.0), "parse(epoch w/ whitespace)")
    // 알 수 없는/빈 토큰은 nil.
    assertTrue(HoldState.parse("") == nil, "parse(empty) == nil")
    assertTrue(HoldState.parse("garbage") == nil, "parse(garbage) == nil")
    assertTrue(HoldState.parse("Forever") == nil, "parse(Forever cased) == nil")
    print("OK: parse")
}

// serialize → parse 라운드트립: 쓴 것을 그대로 다시 읽을 수 있어야 한다
// (helper 재시작 시 hold 가 정확히 복원되는 불변식).
func testRoundTrip() {
    assertEqual(HoldState.parse(HoldState.serialize(forever: true, holdUntil: nil)),
                .forever, "round-trip forever")
    let d = Date(timeIntervalSince1970: 1_734_000_000)
    assertEqual(HoldState.parse(HoldState.serialize(forever: false, holdUntil: d)),
                .until(epoch: 1_734_000_000.0), "round-trip finite")
    print("OK: round-trip")
}

@main
enum HoldStateTestMain {
    static func main() {
        testSerializeForever()
        testSerializeFinite()
        testSerializeFiniteNilFallsBackToNow()
        testParse()
        testRoundTrip()
        if exitCode != 0 {
            print("FAILED: HoldState suite")
            exit(exitCode)
        }
        print("OK: all HoldState suites")
    }
}
