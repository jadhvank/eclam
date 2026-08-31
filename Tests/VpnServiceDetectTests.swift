// VpnServiceDetectTests.swift — standalone swiftc test program for the pure
// `VpnWatcher.pickVpnService(fromScutilList:)` parser (ADR-0037 S3 §폴백, RC3).
// No XCTest, no SwiftPM — see scripts/test.sh. Mirrors PolicyTests.swift /
// LaunchctlInspectTests.swift assert/print/exit(1) style. Exits 0 on success,
// 1 on the first failed assert.
//
// VpnWatcher.swift 는 StateStore·TelegramNotifier·ReleaseNotifier·NSL 에 결합돼
// 있어 단독 컴파일이 안 된다(그 결합부는 라이브 GUI·XPC 라 어차피 수동 검증). 그래서
// LaunchctlInspectTests 가 Subprocess.swift 를 "심볼 해소용"으로만 끌고 오듯,
// 여기서는 VpnWatcher 가 참조하는 최소 심볼만 **테스트 전용 스텁**으로 정의해
// VpnWatcher.swift 를 링크하고, 검증은 순수 함수 `pickVpnService` 만 exercise 한다.
// (스텁의 메서드는 이 테스트 경로에서 호출되지 않는다 — 순수 함수는 이들을 안 건드린다.)

import Foundation

// MARK: - 테스트 전용 최소 스텁 (VpnWatcher.swift 링크용, 검증엔 미사용) ──────────
//
// production 파일을 고치지 않고 순수 함수만 뽑아 쓰기 위한 스캐폴딩. 실제 앱에선
// StateStore/TelegramNotifier/ReleaseNotifier/NSL 이 진짜 구현을 제공한다.

final class StateStore {
    var vpnDisconnectNotifyEnabled = false
    var vpnServiceName = "VPN"
}

final class TelegramNotifier {
    static let shared = TelegramNotifier()
    func notifyVpnDisconnected(serviceName: String) {}
}

final class ReleaseNotifier {
    static let shared = ReleaseNotifier()
    func notifyInfo(identifier: String, title: String, body: String) async {}
}

func NSL(_ key: String, _ english: String) -> String { english }
func NSLf(_ key: String, _ english: String, _ args: CVarArg...) -> String {
    String(format: english, arguments: args)
}

// MARK: - tiny assert harness (mirrors PolicyTests.swift / LaunchctlInspectTests) ─

var currentSuite = "?"
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL [\(currentSuite)]: \(msg)\n".utf8))
    exit(1)
}
func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
    if !cond { fail(msg()) }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got != want { fail("\(what): got \(got), want \(want)") }
}

// MARK: - 실측 fixture (RC3) ──────────────────────────────────────────────────
//
// `scutil --nc list` 실제 출력 줄들. 헤더 + 세 서비스:
//   Tailscale (io.tailscale.ipn.macos)         — SSL VPN 아님, 절대 안 골라야 함
//   Unicorn HTTPS (com.unicorn-soft...)         — SSL VPN 아님, 절대 안 골라야 함
//   FortiSSLVPN (com.fortinet.forticlient...)   — 사내 SSL VPN, 있으면 골라야 함
// 앞 두 줄만 있을 때(FortiClient 부재)는 nil 이어야 한다(bare "vpn" 오탐 금지).

let tailscaleLine =
    #"* (Connected)     00000000-0000-0000-0000-000000000001 VPN (io.tailscale.ipn.macos) "Tailscale" [VPN:io.tailscale.ipn.macos]"#
let unicornLine =
    #"  (Invalid)       00000000-0000-0000-0000-000000000002 VPN (com.unicorn-soft.unicornhttpsformac) "Unicorn HTTPS" [VPN:com.unicorn-soft.unicornhttpsformac]"#
let fortiLine =
    #"* (Disconnected)  00000000-0000-0000-0000-000000000003 VPN (com.fortinet.forticlient.macos.vpn) "FortiSSLVPN" [VPN:com.fortinet.forticlient.macos.vpn]"#
let header = "Available network connection services in the current set (*=enabled):"

// MARK: - 테스트

/// FortiClient 부재 — Tailscale·Unicorn 만 있으면 아무것도 안 골라야 한다.
/// (이전 bug: bare "vpn" score=1 이 Tailscale 을 물었다.)
func testNoFortiClientPicksNothing() {
    currentSuite = "pick(no forticlient)"
    let out = [header, tailscaleLine, unicornLine].joined(separator: "\n")
    let picked = VpnWatcher.pickVpnService(fromScutilList: out)
    check(picked != "Tailscale", "must NOT pick Tailscale (not an SSL VPN)")
    check(picked != "Unicorn HTTPS", "must NOT pick Unicorn HTTPS (not an SSL VPN)")
    expectEqual(picked, nil, "no FortiClient/SSL VPN present ⇒ nil")
    print("OK: pick(no forticlient) → nil")
}

/// FortiClient 존재 — Tailscale·Unicorn 과 섞여 있어도 FortiClient 를 골라야 한다.
func testPicksFortiClientWhenPresent() {
    currentSuite = "pick(forticlient present)"
    // 순서를 일부러 Forti 를 마지막에 둬 "먼저 온 놈"이 아니라 점수로 고르는지 본다.
    let out = [header, tailscaleLine, unicornLine, fortiLine].joined(separator: "\n")
    let picked = VpnWatcher.pickVpnService(fromScutilList: out)
    expectEqual(picked, "FortiSSLVPN", "FortiClient present ⇒ pick its display name")
    print("OK: pick(forticlient present) → FortiSSLVPN")
}

/// Forti 가 첫 줄이어도 동일 — 표시 이름을 뽑는다(회귀 방지).
func testPicksFortiClientRegardlessOfOrder() {
    currentSuite = "pick(forticlient first)"
    let out = [header, fortiLine, tailscaleLine, unicornLine].joined(separator: "\n")
    expectEqual(VpnWatcher.pickVpnService(fromScutilList: out), "FortiSSLVPN",
                "order-independent pick")
    print("OK: pick(forticlient first) → FortiSSLVPN")
}

/// 표시 이름("...")이 없는 SSL VPN 줄은 UUID 로 폴백해 고른다.
func testFallsBackToUuidWhenNoQuotedName() {
    currentSuite = "pick(uuid fallback)"
    let noName =
        #"* (Disconnected)  DEADBEEF-0000-0000-0000-000000000009 VPN (com.fortinet.forticlient.macos.vpn) [VPN:...]"#
    expectEqual(VpnWatcher.pickVpnService(fromScutilList: [header, noName].joined(separator: "\n")),
                "DEADBEEF-0000-0000-0000-000000000009",
                "no quoted name ⇒ UUID identifier")
    print("OK: pick(uuid fallback) → UUID")
}

/// 빈 입력·헤더만 있는 입력 ⇒ nil (오발 금지).
func testEmptyAndHeaderOnly() {
    currentSuite = "pick(empty)"
    expectEqual(VpnWatcher.pickVpnService(fromScutilList: ""), nil, "empty ⇒ nil")
    expectEqual(VpnWatcher.pickVpnService(fromScutilList: header), nil, "header only ⇒ nil")
    print("OK: pick(empty) → nil")
}

// MARK: - run (@main: file isn't main.swift, compiled with other files)

@main
enum VpnServiceDetectTestMain {
    static func main() {
        testNoFortiClientPicksNothing()
        testPicksFortiClientWhenPresent()
        testPicksFortiClientRegardlessOfOrder()
        testFallsBackToUuidWhenNoQuotedName()
        testEmptyAndHeaderOnly()
        print("OK: all VpnServiceDetect suites")
    }
}
