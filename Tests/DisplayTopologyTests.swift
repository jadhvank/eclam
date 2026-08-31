// DisplayTopologyTests.swift — standalone swiftc test program for the pure
// real-external-display predicate `EClamDisplayIsRealExternal`
// (Sources/ElectronicClamApp/VirtualDisplayShim.m, ADR-0037 §미러링).
// scripts/test.sh clangs the shim to an object and links it with this file via
// the bridging header — no XCTest, no SwiftPM. Exits 0 on success, 1 on the
// first failure.
//
// 스냅샷 값은 전부 실측이다. 2026-09-01 이 맥에서 가상 디스플레이 두 개
// (하나는 "TV" 역할)로 미러/확장 토폴로지를 만들며 CG 를 찍은 결과:
//
//   확장(mirror 전):  active=2 online=2 — 슬레이브 active=1 inMirrorSet=0
//   미러(mirror 후):  active=1 online=2 — 슬레이브 active=0 inMirrorSet=1
//
// 즉 `CGGetActiveDisplayList` 는 하드웨어 미러셋 슬레이브를 **빼버린다**. v0.6.4
// 까지 이 목록만 봐서 "미러로 붙인 TV"를 외장으로 치지 못했다.

import Foundation

// MARK: - tiny assert harness

var currentSuite = "?"
var passed = 0

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL [\(currentSuite)]: \(msg)\n".utf8))
    exit(1)
}

func expect(_ got: Bool, _ want: Bool, _ what: String) {
    if got != want { fail("\(what): got \(got), want \(want)") }
    passed += 1
    print("  ✓ \(what)")
}

// MARK: - fixtures

let anchorID = EClamVirtualDisplayIdentity        // 0x6543 — 우리 앵커 identity
let appleVendor: UInt32 = 0x6161_706c             // 'aapl' — Screen Sharing Virtual Display
let tvVendor: UInt32 = 0x1e6d                     // 아무 실물 벤더

/// 판정 대상 한 개를 스냅샷 값으로 물어본다.
func isExternal(builtin: Bool = false,
                active: Bool = true,
                inMirrorSet: Bool = false,
                vendor: UInt32 = tvVendor,
                model: UInt32 = 0x0001) -> Bool {
    EClamDisplayIsRealExternal(builtin, active, inMirrorSet, vendor, model)
}

// MARK: - suites

/// 내장 패널은 어떤 조합에서도 외장이 아니다 — 미러셋에 들어가 있어도(TV 가
/// 내장을 미러할 때 내장도 inMirrorSet=1 로 보고된다) 마찬가지.
func testBuiltinNeverExternal() {
    currentSuite = "builtin"
    expect(isExternal(builtin: true), false, "내장 패널(활성)")
    expect(isExternal(builtin: true, active: false), false, "내장 패널(비활성)")
    expect(isExternal(builtin: true, inMirrorSet: true), false, "내장 패널(미러셋 멤버)")
}

/// 우리 앵커는 자기 자신을 외장으로 세면 안 된다. 세면 `apply()` 가
/// wantActive=false 로 뒤집혀 앵커를 내리고 → 다음 converge 에 다시 올리는
/// 플랩이 난다.
func testOwnAnchorNeverExternal() {
    currentSuite = "anchor"
    expect(isExternal(vendor: anchorID, model: anchorID), false, "앵커(확장 상태)")
    expect(isExternal(active: false, inMirrorSet: true, vendor: anchorID, model: anchorID),
           false, "앵커(main 을 미러 중)")
    expect(isExternal(active: false, vendor: anchorID, model: anchorID),
           false, "고아 앵커(이전 세션 잔존)")
    // vendor 만 같고 model 이 다르면 우리 것이 아니다 — 과도한 제외 방지.
    expect(isExternal(vendor: anchorID, model: 0x1234), true, "vendor 만 일치하는 남의 디스플레이")
}

/// 이번 릴리스가 고치는 것: **미러로 붙인 TV**. active=0 이지만 inMirrorSet=1 이다.
func testMirroredExternalIsSeen() {
    currentSuite = "mirrored-external"
    expect(isExternal(active: false, inMirrorSet: true), true,
           "미러로 붙은 TV (active=0, inMirrorSet=1) ← v0.6.4 가 놓치던 케이스")
    expect(isExternal(active: true, inMirrorSet: true), true,
           "미러셋의 주(primary) 외장")
}

/// 회귀 방지: v0.6.4 의 active-list 의미론은 그대로 유지된다(추가된 건 미러셋
/// 멤버뿐). 확장 연결은 전과 같이 외장이고, active 도 미러셋도 아닌 디스플레이는
/// 전과 같이 외장이 아니다 — 헤드리스 클램쉘 가드가 계속 동작하는 근거.
func testActiveSemanticsPreserved() {
    currentSuite = "regression"
    expect(isExternal(active: true), true, "확장으로 붙은 실물 외장")
    expect(isExternal(active: false, inMirrorSet: false), false,
           "비활성 + 미러셋 아님 (v0.6.4 와 동일하게 무시)")
    expect(isExternal(vendor: appleVendor), true, "Screen Sharing Virtual Display")
}

// MARK: - run

@main
enum DisplayTopologyTestMain {
    static func main() {
        testBuiltinNeverExternal()
        testOwnAnchorNeverExternal()
        testMirroredExternalIsSeen()
        testActiveSemanticsPreserved()
        print("DisplayTopology tests: \(passed) passed, 0 failed")
        print("OK: all DisplayTopology suites")
    }
}
