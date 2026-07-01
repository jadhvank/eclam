import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import OSLog

/// ADR-0037 S2 — #8 "어둡게(dim)" 모드 컨트롤러 (VPN-안전 화면 끄기).
///
/// `pmset displaysleepnow`("재우기")는 즉시-잠금 Mac에서 화면을 *잠가* VPN을
/// 끊는다. dim 모드는 잠그지 않고 내장 패널 밝기를 바닥으로 내린 뒤 public
/// `IOPMAssertionCreateWithName`(`PreventUserIdleDisplaySleep`)으로 idle
/// display-sleep 타이머까지 막아 화면을 *깨어있되 깜깜*하게 유지한다 → 잠금
/// 이벤트가 없어 VPN 유지(ADR-0037 §#8 공존, §어둡게).
///
/// **왜 assertion 이 필요한가**: 밝기만 0 으로 내려도 idle display-sleep 타이머가
/// 결국 display 를 재워 잠긴다. 그래서 밝기 floor + no-sleep assertion 을 함께 잡는다.
///
/// **복귀 감지(권한 불필요)**: dim 동안에만 도는 짧은 타이머가
/// `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)`
/// 로 시스템 입력 idle 을 폴링한다. 이 읽기는 Accessibility/Input-Monitoring 권한이
/// 필요 없어 전역 `NSEvent` 모니터(권한 필요)를 피한다. idle 이 임계 밑으로 떨어지면
/// (사용자 복귀) 밝기 복원 + assertion 해제 + 타이머 정지.
///
/// 외장 디스플레이는 DisplayServices 비대상(DDC best-effort)이라 밝기는 내장만
/// 건드린다 — 외장은 no-sleep assertion 에만 의존(S2 범위, ADR-0037).
final class BlankDisplayDimmer {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "dim")

    /// 사용자 복귀로 판정하는 입력 idle 임계(초). 이 밑이면 "활성".
    private let activeIdleThreshold: TimeInterval = 2.0
    /// 복귀 폴링 간격(초). dim 동안에만 돈다(상시 idle 폴링 아님).
    private let pollInterval: TimeInterval = 0.5

    /// dim 진입 시점의 내장 밝기(복원용). nil = 내장 없음/밝기 미가용.
    private var savedBrightness: Float?
    /// 밝기를 내린 내장 디스플레이 id(복원 대상).
    private var dimmedDisplay: CGDirectDisplayID?
    /// 잡고 있는 display-sleep 방지 assertion. 0 = 없음.
    private var assertionID: IOPMAssertionID = 0
    /// 복귀 감지 타이머(dim 동안에만 유효 = dim 여부의 진실 소스).
    private var pollTimer: Timer?
    /// 복귀(낙하 에지) 감지 무장 여부. dim 은 사용자의 메뉴 클릭으로 트리거되므로
    /// 진입 직후엔 idle 이 낮다 — idle 이 임계 위로 한 번 올라가(사용자가 손을 뗌)
    /// "떠남"을 본 뒤에야 무장한다. 안 그러면 진입 클릭을 복귀로 오인해 즉시 복원한다.
    private var armed = false

    var isDimmed: Bool { pollTimer != nil }

    init() {
        // 안전망: away 중 앱이 종료돼도 깜깜한 화면을 남기지 않도록 밝기를 되살린다.
        // (정상 흐름은 사용자 복귀 시 자동 복원 — 메뉴로 Quit 하러 와도 복원이 선행됨.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restore() }
    }

    /// dim 진입: 내장 밝기 저장 → floor 로 내림 → display-sleep 방지 assertion →
    /// 복귀 폴링 타이머 시작. 이미 dim 중이면 no-op(멱등).
    /// - Parameter floor: 내릴 목표 밝기(기본 0.0 = 완전 깜깜). 호출부에서 재정의 가능.
    func dim(floor: Float = 0.0) {
        guard !isDimmed else { return }
        armed = false

        // 1) 내장 밝기 저장 + floor 적용 (DisplayServices, 내장 전용).
        if let display = DisplayBrightness.builtinDisplayID() {
            savedBrightness = DisplayBrightness.get(display)
            dimmedDisplay = display
            DisplayBrightness.set(display, floor)
        } else {
            // 내장 없음(헤드리스 클램쉘) — 밝기는 무의미. assertion 만으로 진행.
            savedBrightness = nil
            dimmedDisplay = nil
        }

        // 2) display-sleep 방지 assertion (public IOKit). 밝기만 내리면 idle
        //    타이머가 결국 display 를 재워 잠긴다 → 이 assertion 으로 막는다.
        var aid: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Electronic Clam — blank (dim)" as CFString,
            &aid)
        if r == kIOReturnSuccess {
            assertionID = aid
        } else {
            assertionID = 0
            log.error("PreventUserIdleDisplaySleep assertion failed: \(r, privacy: .public)")
        }

        // 3) 복귀 폴링 타이머 — dim 동안에만 돈다.
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollForReturn()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        log.info("blank(dim): brightness floored + display-sleep assertion held; polling for return")
    }

    /// 복원: 저장한 밝기로 되돌리고 assertion 을 풀고 타이머를 멈춘다.
    /// dim 중이 아니면 no-op.
    func restore() {
        guard isDimmed else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        armed = false
        if let display = dimmedDisplay, let b = savedBrightness {
            DisplayBrightness.set(display, b)
        }
        savedBrightness = nil
        dimmedDisplay = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        log.info("blank(dim): brightness restored + assertion released")
    }

    /// idle 이 임계 밑(사용자 복귀)으로 떨어지면 복원. 무장 전(진입 직후)에는
    /// idle 이 임계 위로 올라가길 기다리기만 한다.
    private func pollForReturn() {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard armed else {
            if idle >= activeIdleThreshold { armed = true }
            return
        }
        if idle < activeIdleThreshold {
            log.info("blank(dim): user active (idle \(idle, privacy: .public)s) — restoring")
            restore()
        }
    }
}
