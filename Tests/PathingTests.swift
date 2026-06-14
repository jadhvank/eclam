// PathingTests.swift — ClaudeWorkspacePathing 라운드트립 테이블 테스트.
// swiftc 단독 컴파일 가능 (no XCTest, no SwiftPM).
// scripts/test.sh 에서 ClaudeWorkspacePathing.swift 와 함께 컴파일해 실행.
// Exits 0 on success, 1 on first failure.
//
// 두 파일을 swiftc 로 같이 컴파일할 때는 top-level 문장이 한 파일에만 허용됨.
// PolicyTests.swift 와 동일하게 @main enum 패턴 사용.

import Foundation

// MARK: - tiny assert harness

private var currentSuite = "?"

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL [\(currentSuite)]: \(msg)\n".utf8))
    exit(1)
}
private func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
    if !cond { fail(msg()) }
}
private func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got != want { fail("\(what): got \"\(got)\", want \"\(want)\"") }
}

// MARK: - sanitizeCwdToSegment 직접 비교 테이블

private struct SanitizeCase {
    let input: String
    let expected: String
}

private func testSanitize() {
    currentSuite = "sanitizeCwdToSegment"

    let cases: [SanitizeCase] = [
        // 일반 cwd
        SanitizeCase(input: "/Users/foo/Workspace/proj",
                     expected: "Users-foo-Workspace-proj"),
        // 워크트리 cwd — `_` 와 `.` 포함
        SanitizeCase(input: "/Users/foo/.claude/worktrees/bridge-cse_01Abc",
                     expected: "Users-foo--claude-worktrees-bridge-cse-01Abc"),
        // 대문자 혼합
        SanitizeCase(input: "/Users/JohnDoe/MyProject",
                     expected: "Users-JohnDoe-MyProject"),
        // 숫자 포함 (끝 슬래시 없음)
        SanitizeCase(input: "/home/user42/repo2",
                     expected: "home-user42-repo2"),
        // `.` `_` 혼합 — 비영숫자 전체 변환 검증
        SanitizeCase(input: "/a/b.c/d_e",
                     expected: "a-b-c-d-e"),
        // 공백 포함
        SanitizeCase(input: "/Users/foo/My Projects/work",
                     expected: "Users-foo-My-Projects-work"),
        // 루트 바로 아래 — 선두 `-` 제거 확인
        SanitizeCase(input: "/eclam",
                     expected: "eclam"),
    ]

    for c in cases {
        let got = ClaudeWorkspacePathing.sanitizeCwdToSegment(c.input)
        expectEqual(got, c.expected, "sanitize(\"\(c.input)\")")
    }
    print("OK: sanitizeCwdToSegment (\(cases.count) cases)")
}

// MARK: - 라운드트립 테이블

private struct RoundtripCase {
    let cwd: String
    let baseDir: String  // ~/.claude/projects 의 절대 경로
}

private func testRoundtrip() {
    currentSuite = "roundtrip"

    let cases: [RoundtripCase] = [
        RoundtripCase(cwd: "/Users/foo/Workspace/proj",
                      baseDir: "/Users/foo/.claude/projects"),
        // 워크트리 cwd — `_` `.` 포함 → 이것이 2026-06-11 버그 케이스
        RoundtripCase(cwd: "/Users/foo/.claude/worktrees/bridge-cse_01Abc",
                      baseDir: "/Users/foo/.claude/projects"),
        // 대문자 혼합
        RoundtripCase(cwd: "/Users/JohnDoe/MyProject",
                      baseDir: "/Users/JohnDoe/.claude/projects"),
        // 숫자 포함
        RoundtripCase(cwd: "/home/user42/repo2",
                      baseDir: "/home/user42/.claude/projects"),
        // `.` `_` 혼합
        RoundtripCase(cwd: "/a/b.c/d_e",
                      baseDir: "/a/.claude/projects"),
    ]

    for c in cases {
        // 1) cwd → segment
        let segment = ClaudeWorkspacePathing.sanitizeCwdToSegment(c.cwd)
        // 2) Claude 가 실제로 쓰는 경로 형태: baseDir + "/-" + segment + "/sess.jsonl"
        //    (cwd 의 선두 `/` → `-` 이므로 segment 앞에 `-` 가 붙음)
        let path = "\(c.baseDir)/-\(segment)/sess.jsonl"
        // 3) 경로에서 segment 재추출 → 같아야 함
        guard let extracted = ClaudeWorkspacePathing.projectSegment(fromMatchedPath: path) else {
            fail("projectSegment returned nil for path \"\(path)\" (cwd=\"\(c.cwd)\")")
        }
        check(extracted == segment,
              "roundtrip mismatch for cwd=\"\(c.cwd)\": segment=\"\(segment)\" extracted=\"\(extracted)\"")
    }
    print("OK: roundtrip (\(cases.count) cases)")
}

// MARK: - projectSegment nil 케이스

private func testProjectSegmentNil() {
    currentSuite = "projectSegment/nil"

    let nilCases: [String] = [
        "/Users/foo/no-claude-dir/projects/-foo-bar/sess.jsonl",
        "/Users/foo/.claude/settings/foo",          // "settings" not "projects"
        "/Users/foo/.claude/projects",              // segment 없음
        "/Users/foo/.claude/projects/",             // segment 없음 (trailing /)
    ]

    for p in nilCases {
        let result = ClaudeWorkspacePathing.projectSegment(fromMatchedPath: p)
        check(result == nil, "expected nil for \"\(p)\" but got \"\(result!)\"")
    }
    print("OK: projectSegment/nil (\(nilCases.count) cases)")
}

// MARK: - @main entry point
//
// swiftc 로 여러 파일을 컴파일할 때 bare top-level 문장은 `main.swift` 에만
// 허용되므로 PolicyTests.swift 와 동일하게 @main enum 패턴을 사용한다.

@main
enum PathingTestMain {
    static func main() {
        testSanitize()
        testRoundtrip()
        testProjectSegmentNil()
        print("==> PathingTests PASS")
    }
}
