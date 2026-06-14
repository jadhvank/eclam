// ADR-0025 — `eclam on --for <dur>` 파서/포매터 테스트.
// swiftc 단독 컴파일: Sources/Shared/DurationParse.swift 와 함께 (scripts/test.sh).
// (stdlib-only 제약은 대상 소스에만 적용 — 테스트 파일은 Darwin.exit 사용 가능.)

import Darwin

func assertEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got != want {
        print("FAIL: \(label) — got \(got), want \(want)")
        exitCode = 1
    }
}

var exitCode: Int32 = 0

func testSeconds() {
    let cases: [(String, Double?)] = [
        ("45",      2700),        // 단위 없음 = 분
        ("90m",     5400),
        ("2h",      7200),
        ("1h30m",   5400),
        ("1h30",    5400),        // 관용: 단위 뒤 꼬리 숫자는 분
        ("2H",      7200),        // 대소문자 무관
        (" 2h ",    7200),        // 공백 허용
        ("0",       nil),         // 0 이하 거부
        ("0m",      nil),
        ("",        nil),
        ("abc",     nil),
        ("2d",      nil),         // 미지원 단위
        ("h30",     nil),         // 숫자 없는 단위
        ("-5m",     nil),         // 음수 기호는 숫자가 아님
        ("1234567m", nil),        // 자릿수 폭주 가드
    ]
    for (raw, want) in cases {
        assertEqual(DurationParse.seconds(from: raw), want, "seconds(\"\(raw)\")")
    }
    print("OK: DurationParse.seconds (\(cases.count) cases)")
}

func testShortFormat() {
    let cases: [(Double, String)] = [
        (7200,  "2h"),
        (6180,  "1h 43m"),
        (2700,  "45m"),
        (59,    "59s"),
        (3600,  "1h"),
    ]
    for (sec, want) in cases {
        assertEqual(DurationParse.shortFormat(seconds: sec), want, "shortFormat(\(sec))")
    }
    print("OK: DurationParse.shortFormat (\(cases.count) cases)")
}

@main
enum DurationParseTestMain {
    static func main() {
        testSeconds()
        testShortFormat()
        if exitCode != 0 {
            print("FAILED: DurationParse suite")
            exit(exitCode)
        }
        print("OK: all duration suites")
    }
}
