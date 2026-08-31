// MenuBarPlacementTests.swift — standalone swiftc test program for the pure
// status-item placement predicate (2026-08-05 메뉴바 실종 사건). Compiled with
// Sources/Shared/MenuBarPlacement.swift — no XCTest, no SwiftPM (scripts/test.sh).
// Exits 0 on success, 1 (with a descriptive message) on the first failure.
//
// 좌표는 전부 실측이다. 회사 맥북(노치 내장 1512x982 + 4K 외장 2대)과 개인 맥북
// (노치 내장 1728x1117 + 4K 외장 1대)의 실제 화면 프레임·아이템 좌표를 썼다.

import CoreGraphics
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

/// Cocoa 좌표(좌하단 원점)의 화면 프레임.
func screen(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

/// 상태아이템 창(28x24)을 "윗변 y" 기준으로 만든다 — 메뉴바 아이템은 윗변이 화면
/// 윗변에 붙는 게 정상이라 그 기준이 읽기 쉽다.
func item(x: CGFloat, top: CGFloat, w: CGFloat = 28, h: CGFloat = 24) -> CGRect {
    CGRect(x: x, y: top - h, width: w, height: h)
}

/// 개인 맥북(정상 동작 기준선): 내장 1728x1117 메인 + 외장 LG 왼쪽 아래.
let builtin16 = screen(x: 0, y: 0, w: 1728, h: 1117)
let extLG = screen(x: -1920, y: 327, w: 1920, h: 1080)
let healthy = [builtin16, extLG]

/// 회사 맥북: 내장 1512x982 메인 + 4K 외장 2대.
let builtin14 = screen(x: 0, y: 0, w: 1512, h: 982)
let extA = screen(x: -3840, y: 0, w: 1920, h: 1080)
let extB = screen(x: -1920, y: 0, w: 1920, h: 1080)
let work = [builtin14, extA, extB]

// MARK: - suites

func testPlacedNormally() {
    currentSuite = "정상 배치"
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1400, top: builtin16.maxY),
                                         screens: healthy), true,
           "내장 메뉴바 위의 아이템")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: -412, top: extLG.maxY),
                                         screens: healthy), true,
           "외장 메뉴바 위의 아이템 (실측 -412,-287)")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 0, top: builtin16.maxY),
                                         screens: healthy), true,
           "화면 왼쪽 끝에 딱 붙은 아이템")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1700, top: builtin16.maxY),
                                         screens: healthy), true,
           "화면 오른쪽 끝에 딱 붙은 아이템")
    print("OK: 정상 배치")
}

func testNotchedMenuBar() {
    currentSuite = "노치 화면"
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1200, top: builtin14.maxY - 5),
                                         screens: work), true,
           "노치 메뉴바 안쪽 5pt")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1200, top: builtin14.maxY - 34),
                                         screens: work), true,
           "노치 메뉴바 바닥(34pt)")
    print("OK: 노치 화면")
}

func testMisplaced() {
    currentSuite = "미배치 (실측 고장 좌표)"
    // 실측: 단일 화면(0…1512 × 0…982)에서 AX (-1, 965) = 좌하단 구석.
    expect(MenuBarPlacement.isOnAMenuBar(
        itemFrame: CGRect(x: -1, y: 982 - 965 - 24, width: 28, height: 24),
        screens: [builtin14]), false,
           "좌하단 구석에 버려진 아이템 (실측 -1,965)")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: -5418, top: extLG.maxY),
                                         screens: healthy), false,
           "메뉴바 관리 앱이 화면 밖으로 치운 아이템 (실측 -5418)")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 700, top: builtin16.maxY + 16),
                                         screens: healthy), false,
           "화면 윗변보다 16pt 위 (실측 -114 vs -98)")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 700, top: builtin16.maxY - 200),
                                         screens: healthy), false,
           "메뉴바 띠보다 한참 아래 (화면 중앙)")
    print("OK: 미배치")
}

func testDegenerate() {
    currentSuite = "퇴화 입력"
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: .zero, screens: healthy), false,
           "크기 0 프레임")
    expect(MenuBarPlacement.isOnAMenuBar(
        itemFrame: CGRect(x: 1400, y: 1093, width: 0, height: 24),
        screens: healthy), false, "폭 0 프레임")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1400, top: builtin16.maxY),
                                         screens: []), false,
           "화면 목록이 비어 있음")
    print("OK: 퇴화 입력")
}

func testBoundaries() {
    currentSuite = "경계 (1pt 허용 오차 · 40pt 띠 깊이)"
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1400, top: builtin16.maxY + 1),
                                         screens: healthy), true,
           "윗변 1pt 넘침 = 허용")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1400, top: builtin16.maxY + 2),
                                         screens: healthy), false,
           "윗변 2pt 넘침 = 미배치")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1400, top: builtin16.maxY - 40),
                                         screens: healthy), true,
           "띠 깊이 40pt 경계 = 허용")
    expect(MenuBarPlacement.isOnAMenuBar(itemFrame: item(x: 1400, top: builtin16.maxY - 41),
                                         screens: healthy), false,
           "띠 깊이 41pt = 미배치")
    print("OK: 경계")
}

// MARK: - run

@main
enum MenuBarPlacementTestMain {
    static func main() {
        testPlacedNormally()
        testNotchedMenuBar()
        testMisplaced()
        testDegenerate()
        testBoundaries()
        print("MenuBarPlacement tests: \(passed) passed, 0 failed")
        print("OK: all MenuBarPlacement suites")
    }
}
