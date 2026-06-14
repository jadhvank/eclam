// ClaudeWorkspacePathing.swift
// §J Claude workspace pairing의 경로 인코딩 — 순수/stdlib-only로 분리해
// 테스트 harness가 단독 컴파일 가능하게 (2026-06-11 워크트리 미감지 버그가
// 정확히 이 클래스였음).
//
// Foundation/AppKit import 금지 — String/unicodeScalars 만 사용하므로 가능.

/// Claude workspace pairing (ADR-0006 §J)의 cwd ↔ project-segment 인코딩을
/// 담당하는 순수 함수 컬렉션. stdlib-only이므로 별도 swiftc 호출로 테스트 가능.
enum ClaudeWorkspacePathing {

    /// Claude의 on-disk project directory naming 규칙:
    /// `/Users/foo/bar` → `Users-foo-bar`
    ///
    /// 모든 비영숫자(영문자·숫자 이외 전체)를 `-`로 치환한다.
    /// `/`만 교체하지 않는 이유: `.`, `_`, `(`, `)` 등이 포함된 경로
    /// (예: `.claude/worktrees/bridge-cse_01Abc`)도 Claude 자신이 동일 규칙으로
    /// 인코딩하기 때문이다. 단순 `/` → `-` 치환은 이런 케이스에서 segment가
    /// 달라져 워크트리 미감지 버그를 일으킨다(2026-06-11 실측).
    static func sanitizeCwdToSegment(_ cwd: String) -> String {
        var result = ""
        result.reserveCapacity(cwd.unicodeScalars.count)
        for scalar in cwd.unicodeScalars {
            let v = scalar.value
            let isAlpha = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isDigit = (v >= 0x30 && v <= 0x39)
            if isAlpha || isDigit {
                result.append(Character(scalar))
            } else {
                result.append("-")
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        return result
    }

    /// `~/.claude/projects/<segment>/...` 형태의 경로에서 segment 부분을 추출.
    /// 반환값은 선두 `-`가 제거된 상태 — `sanitizeCwdToSegment`의 출력과 직접 비교 가능.
    ///
    /// 경로가 expected layout에 맞지 않으면 nil.
    static func projectSegment(fromMatchedPath path: String) -> String? {
        // split(separator:omittingEmptySubsequences:true) 사용 — stdlib-only.
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // ".claude" 다음에 "projects" 가 오고, 그 다음이 segment.
        guard let claudeIdx = parts.firstIndex(of: ".claude") else { return nil }
        let projIdx = claudeIdx + 1
        guard projIdx < parts.count, parts[projIdx] == "projects" else { return nil }
        let segIdx = projIdx + 1
        guard segIdx < parts.count else { return nil }
        // Claude 가 segment 앞에 선두 `-` 를 붙임(cwd의 선두 `/` → `-`).
        // 이를 제거해 sanitizeCwdToSegment 출력과 비교 가능하게 만든다.
        var seg = parts[segIdx]
        while seg.hasPrefix("-") { seg.removeFirst() }
        return seg
    }
}
