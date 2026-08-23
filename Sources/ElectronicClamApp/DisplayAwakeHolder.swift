import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import OSLog

/// `caffeinate -d` 등가물 — keep-awake 동안 **디스플레이까지** 깨어 있게 잡는다
/// (opt-in, 기본 OFF).
///
/// **왜 별도 컨트롤러인가.** 헬퍼가 쓰는 `SleepDisabled`(PowerController.swift)는
/// 시스템 잠자기와 클램쉘 잠자기를 막지만 idle *display* sleep 은 막지 않는다.
/// 그래서 keep-awake 중에도 `displaysleep` 타이머가 만료되면 화면이 꺼진다
/// (실측: keep-awake 상태에서 `pmset -g` 가 `displaysleep 10` 을 그대로 유지).
/// 화면을 계속 켜 두려면 `caffeinate -d` 가 쓰는 것과 같은 public assertion
/// `PreventUserIdleDisplaySleep` 이 필요하다.
///
/// **왜 헬퍼가 아니라 앱이 잡는가.** assertion 은 per-pid 이고 프로세스가 죽으면
/// 커널이 자동으로 푼다 — `SleepDisabled` 가 ownerless 라서 복원 machinery
/// (ADR-0002 restore-on-exit + ADR-0004 §5 watchdog)를 요구하는 것과 정확히 반대
/// 성질이다. 앱 프로세스가 직접 잡으면 XPC 프로토콜도 헬퍼 재등록도 건드리지
/// 않고, 앱이 죽어도 화면 설정이 오염된 채로 남지 않는다.
///
/// **`BlankDisplayDimmer` 와의 관계.** 같은 종류의 assertion 을 잡지만 목적이
/// 반대다(dim 은 *깜깜하되 깨어있게*, 여기는 *켜진 채로*). 둘이 동시에 잡혀도
/// 무해하다 — assertion 은 겹쳐 쌓이고 dim 의 어둡기는 밝기로 만들기 때문이다.
/// 실제로 충돌하는 경로는 "Blank screen → Sleep"(`pmset displaysleepnow`) 하나뿐
/// 이라, 거기서만 `suspendUntilUserReturns()` 로 비켜 준다.
final class DisplayAwakeHolder {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "displayawake")
    private let store: StateStore

    /// 잡고 있는 display-sleep 방지 assertion. 0 = 없음.
    private var assertionID: IOPMAssertionID = 0
    /// `apply(...)` 가 마지막으로 계산한 목표(keep 신호 ∧ opt-in). suspend 중에도
    /// 유지된다 — 복귀 시 이 값으로 되돌아간다.
    private var wanted = false
    /// "Blank screen → Sleep" 이 화면을 끈 동안 assertion 을 비켜 두는 중인지.
    private var suspended = false

    /// 복귀 감지 타이머(suspend 동안에만 유효). 상시 폴링이 아니다.
    private var returnPollTimer: Timer?
    /// 복귀(낙하 에지) 감지 무장 여부 — BlankDisplayDimmer 와 같은 이유로 필요하다.
    /// suspend 트리거가 사용자의 메뉴 클릭이라 진입 직후엔 idle 이 낮다. idle 이
    /// 임계 위로 한 번 올라가(사용자가 손을 뗌) "떠남"을 본 뒤에야 무장한다.
    private var armed = false

    /// 복귀 판정 임계·폴링 간격. BlankDisplayDimmer 와 같은 신호를 쓰므로 같은 값.
    private let activeIdleThreshold: TimeInterval = 2.0
    private let pollInterval: TimeInterval = 0.5

    /// 지금 실제로 assertion 을 잡고 있는지(진단·CLI status 용).
    var isHolding: Bool { assertionID != 0 }

    init(store: StateStore) {
        self.store = store
        // 안전망. assertion 은 프로세스 종료 시 커널이 어차피 풀지만, 명시적으로
        // 풀어 두면 `pmset -g assertions` 에 잔상이 남는 구간이 없다.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseAssertion() }
    }

    /// `convergeNow` 가 매 수렴마다 호출한다(멱등). keep 신호와 opt-in 이 **둘 다**
    /// 참일 때만 잡는다 — VpnWatcher.apply 와 같은 게이트 모양이다. 설정만 바뀌고
    /// keep 은 그대로인 경우도 반영되도록 convergeNow 의 no-op early-return 위에서
    /// 불린다.
    func apply(keepAwake: Bool) {
        // 값이 그대로여도 reconcile 을 부른다 — 멱등이고, 앞선 assertion 획득이
        // 실패했을 때 다음 수렴에서 자연히 재시도된다.
        wanted = keepAwake && store.keepDisplayAwakeEnabled
        reconcile()
    }

    /// "Blank screen → Sleep" 전용 — 화면이 꺼져 있는 동안 assertion 을 놓는다.
    /// 안 놓으면 `pmset displaysleepnow` 로 끈 화면을 idle 로직이 곧바로 되살려
    /// 사용자에겐 "화면 끄기가 안 먹는다"로 보인다. 사용자가 돌아오면 자동 복귀
    /// 하므로 호출부는 짝이 되는 resume 을 부를 필요가 없다.
    /// (`.dim` 모드는 부르지 않는다 — 그쪽은 assertion 이 겹쳐도 무해하다.)
    func suspendUntilUserReturns() {
        guard wanted, !suspended else { return }
        suspended = true
        armed = false
        reconcile()

        returnPollTimer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollForReturn()
        }
        RunLoop.main.add(t, forMode: .common)
        returnPollTimer = t
        log.info("display keep-awake suspended for blank(sleep); polling for return")
    }

    /// idle 이 임계 밑(사용자 복귀)으로 떨어지면 suspend 를 끝낸다. 무장 전
    /// (진입 직후)에는 idle 이 임계 위로 올라가길 기다리기만 한다.
    private func pollForReturn() {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard armed else {
            if idle >= activeIdleThreshold { armed = true }
            return
        }
        guard idle < activeIdleThreshold else { return }
        log.info("display keep-awake resumed (idle \(idle, privacy: .public)s)")
        endSuspend()
    }

    private func endSuspend() {
        returnPollTimer?.invalidate()
        returnPollTimer = nil
        armed = false
        suspended = false
        reconcile()
    }

    /// 목표(`wanted` ∧ ¬`suspended`)와 실제 assertion 보유 상태를 일치시킨다.
    private func reconcile() {
        if wanted && !suspended {
            acquireAssertion()
        } else {
            releaseAssertion()
            // suspend 가 아니라 목표 자체가 꺼진 것이면 폴링도 정리한다.
            if !wanted && suspended { endSuspend() }
        }
    }

    private func acquireAssertion() {
        guard assertionID == 0 else { return }
        var aid: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            // ASCII 로만 적는다 — `pmset -g assertions` 가 비-ASCII 를 깨뜨려
            // 출력하기 때문이다(실측: 엠대시가 `?` 로 나옴). 사용자가 동작을
            // 확인하는 자리라 읽히는 게 우선이다.
            "Electronic Clam - keep display awake" as CFString,
            &aid)
        guard r == kIOReturnSuccess else {
            log.error("PreventUserIdleDisplaySleep assertion failed: \(r, privacy: .public)")
            return
        }
        assertionID = aid
        log.info("display keep-awake assertion held")
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        log.info("display keep-awake assertion released")
    }
}
