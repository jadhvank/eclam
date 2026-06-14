/// HookConfigEditingTests.swift — HookInstaller 순수 변환 계층 검증 (L1, ADR-0006 §E).
///
/// 1) wrappedCommand: 앱 삭제 후 `test -x` no-op 셸 래퍼 모양 + shellQuote
/// 2) Codex(TOML): 멱등 재설치, 기존 [features] 병합(중복 헤더 금지), uninstall 왕복
/// 3) Hermes(YAML): 마커 블록 왕복, 멱등
/// 4) Claude(JSON): 엔트리 교체(멱등)·기존 사용자 hook 보존·uninstall 정리
///
/// 실행 (scripts/test.sh): HookConfigEditing.swift 와 함께 단독 컴파일 —
/// HookInstaller(OSLog·Bundle·FileManager 결합)는 끌고 오지 않는다.

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

/// 부분 문자열 등장 횟수 (멱등성·중복 헤더 검증용).
func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var lo = haystack.startIndex
    while let r = haystack.range(of: needle, range: lo..<haystack.endIndex) {
        count += 1
        lo = r.upperBound
    }
    return count
}

/// `_eclam`-태그된 엔트리 개수.
func eclamCount(_ root: [String: Any], _ phase: String) -> Int {
    let hooks = root["hooks"] as? [String: Any] ?? [:]
    let arr = hooks[phase] as? [Any] ?? []
    return arr.filter { ($0 as? [String: Any])?[HookConfigEditing.jsonTagKey] as? Bool == true }.count
}

/// phase 배열 전체 길이.
func phaseCount(_ root: [String: Any], _ phase: String) -> Int {
    let hooks = root["hooks"] as? [String: Any] ?? [:]
    return (hooks[phase] as? [Any] ?? []).count
}

let bin = "/Applications/ElectronicClam.app/Contents/MacOS/eclam-hook"

func testWrappedCommand() {
    print("── wrappedCommand / shellQuote")
    let pre = HookConfigEditing.wrappedCommand(hookBinary: bin, source: "claude.pre")
    assert(pre == "test -x '\(bin)' && exec '\(bin)' claude.pre || true",
           "앱 삭제 후 test -x no-op 래퍼 모양")
    // 두 번의 인용은 같은 따옴표 경로 사용 (커맨드 인용은 래퍼가 전담).
    assert(occurrences(of: "'\(bin)'", in: pre) == 2, "경로가 단일 인용으로 2회 등장")
    assert(HookConfigEditing.shellQuote("/a b/x") == "'/a b/x'", "공백 경로 단일 인용")
    assert(HookConfigEditing.shellQuote("a'b") == "'a'\\''b'", "내부 따옴표 이스케이프")
}

func testCodexIdempotent() {
    print("── Codex 멱등 재설치 (빈 config)")
    let once = HookConfigEditing.codexConfig(installingInto: "", hookBinary: bin)
    assert(HookConfigEditing.markerBlockPresent(in: once), "마커 블록 존재")
    assert(once.contains("# >>> eclam-hook v3"), "버전 마커 v3")
    assert(once.contains("[features]") && once.contains("hooks = true"), "자체 [features] + hooks=true")
    assert(once.contains("[[hooks.PreToolUse.hooks]]") && once.contains("[[hooks.PostToolUse.hooks]]"),
           "Pre/Post 4요소 블록")
    let twice = HookConfigEditing.codexConfig(installingInto: once, hookBinary: bin)
    assert(twice == once, "재설치 멱등 — 바이트 동일")
    assert(occurrences(of: HookConfigEditing.markerBegin, in: twice) == 1, "마커 블록 정확히 1개")
}

func testCodexFeaturesMerge() {
    print("── Codex 기존 [features] 병합 (중복 헤더 금지)")
    let existing = "[features]\nother = 1\n"
    let merged = HookConfigEditing.codexConfig(installingInto: existing, hookBinary: bin)
    assert(occurrences(of: "[features]", in: merged) == 1, "[features] 헤더 1개 (중복 안 만듦)")
    assert(merged.contains("hooks = true  \(HookConfigEditing.featuresInlineMarker)"),
           "기존 섹션에 hooks=true 인라인 마커 주입")
    assert(merged.contains("other = 1"), "사용자 키 보존")

    // 이미 hooks 플래그가 있으면 재주입하지 않는다.
    let hasFlag = "[features]\nhooks = true\n"
    let merged2 = HookConfigEditing.codexConfig(installingInto: hasFlag, hookBinary: bin)
    assert(!merged2.contains(HookConfigEditing.featuresInlineMarker), "기존 hooks 플래그 → 인라인 마커 미주입")
    assert(occurrences(of: "hooks = true", in: merged2) == 1, "hooks=true 중복 없음")
}

func testCodexUninstallRoundTrip() {
    print("── Codex uninstall 왕복")
    let installed = HookConfigEditing.codexConfig(installingInto: "", hookBinary: bin)
    let removed = HookConfigEditing.codexConfig(uninstallingFrom: installed)
    assert(removed.isEmpty, "빈 config 설치→제거 ⇒ 빈 문자열 복원")
    assert(!HookConfigEditing.markerBlockPresent(in: removed), "마커 제거됨")

    // 사용자 [features] 보존 + 주입 플래그/마커만 제거.
    let userInstalled = HookConfigEditing.codexConfig(installingInto: "[features]\nother = 1\n", hookBinary: bin)
    let userRemoved = HookConfigEditing.codexConfig(uninstallingFrom: userInstalled)
    assert(userRemoved.contains("[features]") && userRemoved.contains("other = 1"),
           "사용자 [features]·키 보존")
    assert(!HookConfigEditing.markerBlockPresent(in: userRemoved), "사용자 보존 시에도 마커 제거")
    assert(!userRemoved.contains(HookConfigEditing.featuresInlineMarker), "주입 플래그 제거")
}

func testStripMalformed() {
    print("── stripCodexBlock 손상 복구")
    let malformed = "keep\n\(HookConfigEditing.markerBegin) v3\ngarbage"
    let result = HookConfigEditing.stripCodexBlock(malformed)
    assert(result == "keep\n", "end 마커 없으면 begin~EOF 절단")
}

func testHermesRoundTrip() {
    print("── Hermes 마커 블록 왕복")
    let once = HookConfigEditing.hermesConfig(installingInto: "", hookBinary: bin)
    assert(HookConfigEditing.markerBlockPresent(in: once), "마커 존재")
    assert(once.contains("hooks:") && once.contains("pre_tool_call:") && once.contains("post_tool_call:"),
           "hooks: pre/post_tool_call 키")
    let twice = HookConfigEditing.hermesConfig(installingInto: once, hookBinary: bin)
    assert(twice == once, "재설치 멱등")
    let removed = HookConfigEditing.hermesConfig(uninstallingFrom: once)
    assert(removed.isEmpty, "설치→제거 ⇒ 빈 문자열")
}

func testClaudeJSON() {
    print("── Claude JSON 엔트리 교체/병합/제거")
    let installed = HookConfigEditing.claudeRoot(installingInto: [:], hookBinary: bin)
    assert(HookConfigEditing.claudeInstalled(in: installed), "버전 키 stamped ⇒ installed")
    assert((installed[HookConfigEditing.jsonVersionKey] as? Int) == 3, "버전 == 3")
    assert(eclamCount(installed, "PreToolUse") == 1 && eclamCount(installed, "PostToolUse") == 1,
           "Pre/Post 각 1개 eclam 엔트리")

    // 멱등 재설치 — 교체이지 중복 추가 아님.
    let reinstalled = HookConfigEditing.claudeRoot(installingInto: installed, hookBinary: bin)
    assert(eclamCount(reinstalled, "PreToolUse") == 1, "재설치해도 eclam 엔트리 1개 (교체)")

    // 사용자 기존 hook 보존.
    let withUser: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash", "user": true]]]]
    let mergedRoot = HookConfigEditing.claudeRoot(installingInto: withUser, hookBinary: bin)
    assert(phaseCount(mergedRoot, "PreToolUse") == 2, "사용자 엔트리 + eclam = 2개")
    assert(eclamCount(mergedRoot, "PreToolUse") == 1, "그 중 eclam 1개")
    let userSurvived = (mergedRoot["hooks"] as? [String: Any])?["PreToolUse"] as? [Any]
    assert(userSurvived?.contains { ($0 as? [String: Any])?["user"] as? Bool == true } == true,
           "사용자 엔트리 보존")

    // uninstall — 빈 설치는 version·hooks 모두 제거.
    let cleaned = HookConfigEditing.claudeRoot(uninstallingFrom: installed)
    assert(!HookConfigEditing.claudeInstalled(in: cleaned), "version 키 제거")
    assert(cleaned["hooks"] == nil, "빈 hooks 맵 제거")

    // uninstall — 사용자 엔트리는 남기고 eclam·version만.
    let userCleaned = HookConfigEditing.claudeRoot(uninstallingFrom: mergedRoot)
    assert(!HookConfigEditing.claudeInstalled(in: userCleaned), "병합본도 version 제거")
    assert(eclamCount(userCleaned, "PreToolUse") == 0, "eclam 엔트리 제거")
    assert(phaseCount(userCleaned, "PreToolUse") == 1, "사용자 엔트리 1개 잔존")

    // 빈/미설치 root 판정.
    assert(!HookConfigEditing.claudeInstalled(in: [:]), "빈 root ⇒ not installed")
}

@main
enum HookConfigEditingTestMain {
    static func main() {
        testWrappedCommand()
        testCodexIdempotent()
        testCodexFeaturesMerge()
        testCodexUninstallRoundTrip()
        testStripMalformed()
        testHermesRoundTrip()
        testClaudeJSON()

        print("")
        print("HookConfigEditing tests: \(passCount) passed, \(failCount) failed")
        exit(failCount == 0 ? 0 : 1)
    }
}
