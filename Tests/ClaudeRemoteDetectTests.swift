/// ClaudeRemoteDetectTests.swift — Claude Code 원격제어 argv 분류 검증 (ADR-0031).
///
/// fixture 는 2026-06-14 라이브 `ps -axww -o command` 실측 라인(Claude 2.1.177):
///   host   `claude remote-control …`
///   worker `…/claude/versions/<v> --print --sdk-url …/v1/code/sessions/cse_… …`
///   local  `claude`, `claude --resume <uuid>`
///   오탐원 Electron 데스크톱 앱(`/Applications/Claude.app/…/Claude`, crashpad,
///         renderer 의 `coworkRemoteSessionSpaces`)
///
/// 실행 (scripts/test.sh): ClaudeRemoteDetect.swift 와 함께 단독 컴파일 —
/// RemoteWatcher(ps exec·StateStore 결합)는 끌고 오지 않는다.

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

// ── 실측 fixture ──────────────────────────────────────────────────────────
let host = "claude remote-control --name home-eclam --spawn worktree --capacity 8"
let worker = "/Users/foo/.local/share/claude/versions/2.1.177 --print "
    + "--sdk-url https://api.anthropic.com/v1/code/sessions/cse_01QhaEYKNXsFY6YRmQen1o8u "
    + "--session-id cse_01QhaEYKNXsFY6YRmQen1o8u --input-format stream-json "
    + "--output-format stream-json --replay-user-messages"
let localBare = "claude"
let localResume = "claude --resume b069374b-0eca-4907-87cc-b1af297b9c60"

// Electron 데스크톱 앱 — 절대 매치되면 안 됨.
let desktopMain = "/Applications/Claude.app/Contents/MacOS/Claude"
let desktopCrashpad = "/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework"
    + "/Helpers/chrome_crashpad_handler --no-rate-limit --annotation=_productName=Claude "
    + "--annotation=_version=1.12603.1"
let desktopRenderer = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app"
    + "/Contents/MacOS/Claude Helper (Renderer) --type=renderer "
    + "--desktop-features={\"coworkRemoteSessionSpaces\":{\"status\":\"supported\"},"
    + "\"coworkBranchSession\":{\"status\":\"supported\"}}"

func testClassifyTargets() {
    print("── classify: 원격제어 대상")
    assert(ClaudeRemoteDetect.classify(command: host) == .host, "host: remote-control ⇒ .host")
    assert(ClaudeRemoteDetect.classify(command: worker) == .worker, "worker: code/sessions sdk-url ⇒ .worker")
    // cse_ + --session-id 폴백 (sdk-url 형태가 바뀌어도).
    let workerNoURL = "/Users/me/.local/share/claude/versions/2.2.0 --print "
        + "--session-id cse_abc123 --replay-user-messages"
    assert(ClaudeRemoteDetect.classify(command: workerNoURL) == .worker,
           "worker 폴백: cse_ + --session-id ⇒ .worker")
}

func testClassifyLocalIsNil() {
    print("── classify: 로컬 대화형 ⇒ nil (원격 아님)")
    assert(ClaudeRemoteDetect.classify(command: localBare) == nil, "`claude` ⇒ nil")
    assert(ClaudeRemoteDetect.classify(command: localResume) == nil, "`claude --resume <uuid>` ⇒ nil")
}

func testDesktopAppNeverMatches() {
    print("── classify: Electron 데스크톱 앱 오탐 차단")
    assert(ClaudeRemoteDetect.classify(command: desktopMain) == nil,
           "데스크톱 메인(대문자 Claude) ⇒ nil")
    assert(ClaudeRemoteDetect.classify(command: desktopCrashpad) == nil,
           "crashpad(productName=Claude) ⇒ nil")
    assert(ClaudeRemoteDetect.classify(command: desktopRenderer) == nil,
           "renderer(coworkRemoteSessionSpaces 토큰) ⇒ nil")
    // 대소문자 잠금: 대문자 Claude 가 remote-control 토큰을 가져도 CLI 아님.
    assert(ClaudeRemoteDetect.classify(command: "/Applications/Claude.app/Contents/MacOS/Claude remote-control") == nil,
           "대문자 Claude + remote-control ⇒ nil (CLI 아님)")
}

func testNonClaudeGuard() {
    print("── classify: 비-Claude 프로세스가 토큰을 가져도 차단")
    assert(ClaudeRemoteDetect.classify(command: "/opt/homebrew/bin/some-tool remote-control --foo") == nil,
           "비-Claude + remote-control 토큰 ⇒ nil")
    assert(ClaudeRemoteDetect.classify(command: "/usr/bin/grep cse_ file") == nil,
           "cse_ 를 인자로 가진 grep ⇒ nil")
}

func testIsClaudeCLICommand() {
    print("── isClaudeCLICommand")
    assert(ClaudeRemoteDetect.isClaudeCLICommand("claude"), "`claude` ⇒ CLI")
    assert(ClaudeRemoteDetect.isClaudeCLICommand("claude-code --foo"), "`claude-code` ⇒ CLI")
    assert(ClaudeRemoteDetect.isClaudeCLICommand(worker), "`…/claude/versions/…` ⇒ CLI")
    assert(!ClaudeRemoteDetect.isClaudeCLICommand(desktopMain), "데스크톱 앱(대문자) ⇒ 아님")
    assert(!ClaudeRemoteDetect.isClaudeCLICommand("/usr/bin/claudette"), "`claudette` ⇒ 아님(부분일치 금지)")
}

func testHasArgToken() {
    print("── hasArgToken (토큰 경계)")
    assert(ClaudeRemoteDetect.hasArgToken("claude remote-control --name x", "remote-control"),
           "독립 토큰 매치")
    assert(!ClaudeRemoteDetect.hasArgToken("claude --foo=remote-control-x", "remote-control"),
           "더 큰 토큰의 부분문자열은 불매치")
}

func testScanAndActive() {
    print("── scan / isRemoteControlActive (멀티라인 ps 덤프)")
    let dump = [desktopMain, localBare, host, worker, localResume].joined(separator: "\n")
    let classes = ClaudeRemoteDetect.scan(psCommandOutput: dump)
    assert(classes == [.host, .worker], "host+worker 둘 다 검출, 로컬/데스크톱 무시")
    assert(ClaudeRemoteDetect.isRemoteControlActive(psCommandOutput: dump), "원격 활성 ⇒ true")

    let localOnly = [desktopMain, localBare, localResume].joined(separator: "\n")
    assert(!ClaudeRemoteDetect.isRemoteControlActive(psCommandOutput: localOnly),
           "로컬/데스크톱만 ⇒ false")
    assert(ClaudeRemoteDetect.scan(psCommandOutput: "").isEmpty, "빈 입력 ⇒ 빈 집합")
}

@main
enum ClaudeRemoteDetectTestMain {
    static func main() {
        testClassifyTargets()
        testClassifyLocalIsNil()
        testDesktopAppNeverMatches()
        testNonClaudeGuard()
        testIsClaudeCLICommand()
        testHasArgToken()
        testScanAndActive()

        print("")
        print("ClaudeRemoteDetect tests: \(passCount) passed, \(failCount) failed")
        exit(failCount == 0 ? 0 : 1)
    }
}
