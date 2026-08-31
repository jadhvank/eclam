import CoreGraphics

/// 상태아이템이 "실제로 메뉴바에 앉아 있는가"의 순수 판정 (2026-08-05).
///
/// 배경 — 실측 사건: 앱은 정상 동작하는데 메뉴바 아이콘이 안 보여 토글도 설정도 열
/// 수 없는 상태가 3일간 지속됐다. `NSStatusItem` 은 표시에 실패해도 살아 있고
/// (`isVisible == true`, 크기 28x24 유지) 창만 메뉴바 밖에 남는다. 실측 좌표:
/// 단일 디스플레이(0…1512 × 0…982)에서 `-1, 965` — 화면 좌하단 구석. 정상 설치에서는
/// 아이템의 y 가 ControlCenter 와 ±1pt 로 일치한다.
///
/// 그래서 `isVisible` 이 아니라 **버튼 창의 실제 프레임이 어느 화면의 상단 띠 안에
/// 있는가**로 판정한다. 프레임워크 없는 순수 계층으로 분리한 이유는 `scripts/test.sh`
/// 가 단독 컴파일해 회귀 검증하기 위해서다 (`SafetyPolicy`·`HoldState` 와 같은 관례).
///
/// 좌표계는 Cocoa (좌하단 원점, y 위로) — `NSScreen.frame` / `NSWindow.frame` 그대로.
public enum MenuBarPlacement {
    /// 메뉴바 띠로 인정하는 화면 상단으로부터의 깊이(pt).
    ///
    /// 실측: 노치 없는 외장 24pt, 노치 내장 33~34pt. 40 은 그 위로 여유를 둔 값이다.
    /// 더 키우면 메뉴바 바로 아래에 붙은 창을 오인하고, 더 줄이면 노치 화면에서
    /// 정상 아이템을 미배치로 오판한다.
    public static let stripDepth: CGFloat = 40

    /// 경계 판정의 허용 오차(pt). AppKit 이 화면 경계에 딱 붙일 때의 1pt 오차를 흡수.
    public static let epsilon: CGFloat = 1

    /// `itemFrame` 이 `screens` 중 어느 하나의 메뉴바 띠 안에 있는가.
    ///
    /// - `itemFrame`: 상태아이템 버튼 창의 프레임. 폭·높이가 0 이면 미배치로 본다.
    /// - `screens`: `NSScreen.screens` 의 `frame` 들.
    public static func isOnAMenuBar(itemFrame: CGRect, screens: [CGRect]) -> Bool {
        guard itemFrame.width > 0, itemFrame.height > 0 else { return false }
        for screen in screens {
            let top = screen.maxY
            // 세로: 창 윗변이 화면 윗변 근처(위로 넘지 않고, 띠 깊이 안).
            let withinStrip = itemFrame.maxY <= top + epsilon
                && itemFrame.maxY >= top - stripDepth
            // 가로: 창이 그 화면의 가로 범위 안.
            let withinWidth = itemFrame.minX >= screen.minX - epsilon
                && itemFrame.maxX <= screen.maxX + epsilon
            if withinStrip && withinWidth { return true }
        }
        return false
    }
}
