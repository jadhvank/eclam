/// CodexRemoteDetectTests.swift — Codex remote-control 데몬 argv 분류 검증 (ADR-0031).
///
/// fixture 는 2026-06-14 라이브 `ps -axww -o command` 실측(Codex 149, standalone CLI,
/// `codex remote-control start` 직후):
///   daemon  `…/.codex/packages/standalone/current/codex app-server --remote-control --listen unix://`
///   sibling `…/codex app-server daemon pid-update-loop`                 ← remote 아님
///   상시 백엔드 `/Applications/Codex.app/…/codex app-server --analytics-default-enabled`,
///             `…/codex app-server --listen stdio://`                    ← remote 아님
///   Electron `/Applications/Codex.app/…/Codex`, `Codex (Service)`       ← codex CLI 아님
///
/// 실행 (scripts/test.sh): CodexRemoteDetect.swift 와 함께 단독 컴파일 —
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
let daemon = "/Users/foo/.codex/packages/standalone/current/codex "
    + "app-server --remote-control --listen unix://"
let sibling = "/Users/foo/.codex/packages/standalone/current/codex app-server daemon pid-update-loop"
let backendAnalytics = "/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled"
let backendStdio = "/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://"
let launcher = "/Applications/Codex.app/Contents/Resources/codex remote-control start"
let electronMain = "/Applications/Codex.app/Contents/MacOS/Codex"
let electronService = "/Applications/Codex.app/Contents/Frameworks/Codex Framework.framework"
    + "/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service) --type=gpu-process"

func testClassifyDaemon() {
    print("── classify: remote-control 데몬")
    assert(CodexRemoteDetect.classify(command: daemon) == .daemon,
           "app-server --remote-control ⇒ .daemon")
}

func testNonRemoteIsNil() {
    print("── classify: 상시 백엔드·sibling ⇒ nil (원격 아님)")
    assert(CodexRemoteDetect.classify(command: backendAnalytics) == nil,
           "--analytics-default-enabled ⇒ nil")
    assert(CodexRemoteDetect.classify(command: backendStdio) == nil,
           "--listen stdio:// ⇒ nil")
    assert(CodexRemoteDetect.classify(command: sibling) == nil,
           "app-server daemon pid-update-loop(--remote-control 없음) ⇒ nil")
    // 런처 `codex remote-control start` 는 데몬을 spawn 후 종료 — 영속 신호는
    // 데몬(--remote-control)이라 런처 자체는 비대상.
    assert(CodexRemoteDetect.classify(command: launcher) == nil,
           "런처 `remote-control start`(--remote-control 토큰 아님) ⇒ nil")
}

func testElectronNeverMatches() {
    print("── classify: Electron 데스크톱 앱 오탐 차단")
    assert(CodexRemoteDetect.classify(command: electronMain) == nil,
           "데스크톱 메인(대문자 Codex) ⇒ nil")
    assert(CodexRemoteDetect.classify(command: electronService) == nil,
           "Codex (Service) 헬퍼 ⇒ nil")
    // 대문자 Codex 가 --remote-control 을 가져도 codex CLI 아님.
    assert(CodexRemoteDetect.classify(command: "/Applications/Codex.app/Contents/MacOS/Codex app-server --remote-control") == nil,
           "대문자 Codex + --remote-control ⇒ nil (CLI 아님)")
}

func testNonCodexGuard() {
    print("── classify: 비-Codex 프로세스가 토큰을 가져도 차단")
    assert(CodexRemoteDetect.classify(command: "/opt/homebrew/bin/some-tool app-server --remote-control") == nil,
           "비-codex + --remote-control ⇒ nil")
}

func testIsCodexCLICommand() {
    print("── isCodexCLICommand")
    assert(CodexRemoteDetect.isCodexCLICommand(daemon), "standalone codex 데몬 ⇒ CLI")
    assert(CodexRemoteDetect.isCodexCLICommand(backendAnalytics), "번들 codex 백엔드 ⇒ CLI")
    assert(!CodexRemoteDetect.isCodexCLICommand(electronMain), "Electron 메인(대문자) ⇒ 아님")
    assert(!CodexRemoteDetect.isCodexCLICommand("/usr/bin/codexford"), "`codexford` ⇒ 아님(부분일치 금지)")
}

func testHasArgToken() {
    print("── hasArgToken (토큰 경계)")
    assert(CodexRemoteDetect.hasArgToken(daemon, "--remote-control"), "독립 토큰 매치")
    assert(!CodexRemoteDetect.hasArgToken("codex app-server --remote-control-x", "--remote-control"),
           "더 큰 토큰의 부분문자열은 불매치")
}

func testScanAndActive() {
    print("── scan / isRemoteControlActive (멀티라인 ps 덤프)")
    let dump = [electronMain, backendAnalytics, backendStdio, sibling, daemon].joined(separator: "\n")
    assert(CodexRemoteDetect.scan(psCommandOutput: dump) == [.daemon],
           "데몬만 검출, 백엔드/sibling/Electron 무시")
    assert(CodexRemoteDetect.isRemoteControlActive(psCommandOutput: dump), "데몬 존재 ⇒ true")

    let noDaemon = [electronMain, backendAnalytics, backendStdio, sibling].joined(separator: "\n")
    assert(!CodexRemoteDetect.isRemoteControlActive(psCommandOutput: noDaemon),
           "상시 백엔드만(데몬 없음) ⇒ false")
    assert(CodexRemoteDetect.scan(psCommandOutput: "").isEmpty, "빈 입력 ⇒ 빈 집합")
}

@main
enum CodexRemoteDetectTestMain {
    static func main() {
        testClassifyDaemon()
        testNonRemoteIsNil()
        testElectronNeverMatches()
        testNonCodexGuard()
        testIsCodexCLICommand()
        testHasArgToken()
        testScanAndActive()

        print("")
        print("CodexRemoteDetect tests: \(passCount) passed, \(failCount) failed")
        exit(failCount == 0 ? 0 : 1)
    }
}
