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
/// **복귀 감지 — 이벤트 우선 + 폴링 백업**: 주 경로는 `NSWorkspace` 의 wake 알림
/// (`didWake`/`screensDidWake`)으로, 뚜껑을 다시 열면 즉시 `restore()` 한다(main 큐
/// 발화, 권한 불필요). 백업으로 dim 동안에만 도는 짧은 타이머가
/// `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)`
/// 로 시스템 입력 idle 을 폴링한다(Accessibility/Input-Monitoring 권한 불필요 → 전역
/// `NSEvent` 모니터 회피). idle 이 임계 밑으로 떨어지면(사용자 복귀) 복원.
/// LSUIElement 백그라운드 앱은 뚜껑을 닫으면 App Nap 으로 `RunLoop.main` 타이머가
/// 스로틀/중단되므로, dim 에피소드 동안 `ProcessInfo.beginActivity` 토큰을 잡아
/// 폴링 백업이 계속 돌게 한다(RC1).
///
/// **복원 시 id 재해석 + 재시도(RC2)**: 클램쉘 재개폐로 내장 패널의 `CGDirectDisplayID`
/// 가 바뀌거나 재-enumeration 될 수 있어, `restore()` 는 dim-진입 때 캡처한 id 를 그대로
/// 쓰지 않고 매 시도마다 `builtinID()` 로 다시 resolve(실패 시 캡처 id 폴백)하며, 방금
/// 깨어난 패널이 잠시 write 를 거부하면 짧은 지연으로 bounded 재시도한다.
///
/// 외장 디스플레이는 DisplayServices 비대상(DDC best-effort)이라 밝기는 내장만
/// 건드린다 — 외장은 no-sleep assertion 에만 의존(S2 범위, ADR-0037).
final class BlankDisplayDimmer {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "dim")

    /// 밝기 백엔드(테스트 주입점). 기본은 `DisplayServices` 위임.
    private let backend: BrightnessBackend

    /// 사용자 복귀로 판정하는 입력 idle 임계(초). 이 밑이면 "활성".
    private let activeIdleThreshold: TimeInterval = 2.0
    /// 복귀 폴링 간격(초). dim 동안에만 돈다(상시 idle 폴링 아님).
    private let pollInterval: TimeInterval = 0.5
    /// 복원 밝기 쓰기 재시도 상한. 방금 깨어난 패널이 잠시 write 를 거부할 수 있어
    /// (id 재해석 후에도) 짧은 지연으로 bounded 재시도한다.
    private let restoreRetryLimit = 5
    /// 복원 재시도 간격(초). 패널이 안정될 시간을 준다.
    private let restoreRetryDelay: TimeInterval = 0.2

    /// dim 진입 시점의 내장 밝기(복원용). nil = 내장 없음/밝기 미가용.
    private var savedBrightness: Float?
    /// dim 진입 시점에 밝기를 내린 내장 디스플레이 id. 복원 때는 이 값을 그대로 쓰지
    /// 않고 `backend.builtinID()` 로 다시 resolve 한다(클램쉘 재개폐로 id 가 바뀌거나
    /// 재-enumeration 되므로) — 재해석 실패 시에만 이 캡처 값으로 폴백(RC2).
    private var dimmedDisplay: CGDirectDisplayID?
    /// 잡고 있는 display-sleep 방지 assertion. 0 = 없음.
    private var assertionID: IOPMAssertionID = 0
    /// 복귀 감지 타이머(dim 동안에만 유효 = dim 여부의 진실 소스).
    private var pollTimer: Timer?
    /// dim 에피소드 동안 App Nap 을 막는 활동 토큰(RC1). LSUIElement 백그라운드 앱은
    /// 뚜껑을 닫으면 App Nap 으로 `RunLoop.main` 타이머(복귀 폴링)가 스로틀/중단돼
    /// 복원이 영영 안 일어난다 — begin/end 로 dim 동안만 nap 을 회피한다.
    /// (display-sleep assertion 은 App Nap 에 영향 없음.)
    private var dimActivity: NSObjectProtocol?
    /// 복귀(낙하 에지) 감지 무장 여부. dim 은 사용자의 메뉴 클릭으로 트리거되므로
    /// 진입 직후엔 idle 이 낮다 — idle 이 임계 위로 한 번 올라가(사용자가 손을 뗌)
    /// "떠남"을 본 뒤에야 무장한다. 안 그러면 진입 클릭을 복귀로 오인해 즉시 복원한다.
    private var armed = false
    /// dim 에피소드 세대 번호. `dim()`/`restore()` 마다 증가한다. 비동기 재시도 루프는
    /// 자기 세대를 캡처해 두고, 세대가 바뀌면(복원 완료 또는 새 dim 진입) 스스로 멈춘다
    /// — wake+poll 이 동시에 restore() 를 불러도 재시도 루프가 중첩되지 않게 하는 멱등 키.
    private var episode: UInt = 0

    var isDimmed: Bool { pollTimer != nil }

    init(backend: BrightnessBackend = DisplayServicesBrightnessBackend()) {
        self.backend = backend
        // 안전망: away 중 앱이 종료돼도 깜깜한 화면을 남기지 않도록 밝기를 되살린다.
        // (정상 흐름은 사용자 복귀 시 자동 복원 — 메뉴로 Quit 하러 와도 복원이 선행됨.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restore() }

        // RC1 — 이벤트 구동 복원: 뚜껑을 다시 열면(시스템/화면 wake) napped 폴링을
        // 기다리지 않고 즉시 복원한다. `restore()` 는 dim 중이 아니면 no-op 이므로
        // 상시 등록해도 안전하다. Swift-native 알림이라 main 큐에서 발화한다.
        // (C `CGDisplayRegisterReconfigurationCallback` 은 ObjC shim 소관 — 여기 아님.)
        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restore() }
        wsc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restore() }
    }

    /// dim 진입: 내장 밝기 저장 → floor 로 내림 → display-sleep 방지 assertion →
    /// 복귀 폴링 타이머 시작. 이미 dim 중이면 no-op(멱등).
    /// - Parameter floor: 내릴 목표 밝기(기본 0.0 = 완전 깜깜). 호출부에서 재정의 가능.
    func dim(floor: Float = 0.0) {
        guard !isDimmed else { return }
        armed = false
        episode &+= 1   // 새 에피소드 — 이전 세대의 재시도 루프가 남아 있으면 무효화.

        // 1) 내장 밝기 저장 + floor 적용 (DisplayServices, 내장 전용).
        if let display = backend.builtinID() {
            savedBrightness = backend.get(display)
            dimmedDisplay = display
            backend.set(display, floor)
        } else {
            // 내장 없음(헤드리스 클램쉘) — 밝기는 무의미. assertion 만으로 진행(RC3).
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

        // 3) App Nap 회피 활동 토큰(RC1). wake 이벤트가 주 복원 경로지만, 이벤트가
        //    누락돼도 폴링이 백업으로 계속 돌도록 dim 동안 nap 을 막는다. display-sleep
        //    은 assertion 이 담당하므로 여기선 idleSystemSleepDisabled 는 켜지 않는다
        //    (시스템 수면까지 막으면 과함) — 낮은-전력·display 유휴 수면 차단만.
        dimActivity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .idleDisplaySleepDisabled],
            reason: "Electronic Clam — blank (dim) return polling")

        // 4) 복귀 폴링 타이머 — dim 동안에만 돈다.
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollForReturn()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        log.info("blank(dim): brightness floored + display-sleep assertion held; polling for return")
    }

    /// 복원: 밝기를 되돌리고 assertion·활동 토큰을 풀고 타이머를 멈춘다.
    /// dim 중이 아니면 no-op(멱등). wake 이벤트·폴링이 겹쳐 여러 번 불려도
    /// `isDimmed` 게이트로 첫 호출만 실제 복원한다.
    func restore() {
        guard isDimmed else { return }
        // 타이머를 먼저 끊어 이후 재진입은 즉시 no-op 이 되게 한다(멱등 진입점).
        pollTimer?.invalidate()
        pollTimer = nil
        armed = false
        episode &+= 1   // 새 세대 — 이전 세대에서 스케줄된 재시도 루프가 있으면 무효화.

        // RC2 — 복원은 캡처한 id 가 아니라 *복원 시점에* resolve 한 built-in 을 우선한다.
        // 클램쉘 재개폐로 내장의 CGDirectDisplayID 가 바뀌거나 재-enumeration 될 수
        // 있어, dim-진입 때 잡은 id 로 쓰면 조용히 실패해 화면이 깜깜한 채 남는다.
        // 실제 대상 결정·재해석은 attemptBrightnessRestore 안에서 매 시도마다 한다
        // (방금 깨어난 패널이 잠깐 nil 을 주거나 write 를 거부하는 창을 재시도로 흡수).
        if let b = savedBrightness {
            attemptBrightnessRestore(b, fallback: dimmedDisplay,
                                     remaining: restoreRetryLimit, generation: episode)
        } else if backend.builtinID() != nil {
            // RC3 — dim 을 헤드리스로 진입해 저장값이 없다. 내장이 돌아왔어도 되돌릴
            //       기준값이 없으므로 밝기는 건드리지 않고(값 지어내기 금지) 기록만 한다.
            log.info("blank(dim): built-in returned but no saved brightness (entered headless) — leaving brightness as-is")
        }
        savedBrightness = nil
        dimmedDisplay = nil

        if let activity = dimActivity {
            ProcessInfo.processInfo.endActivity(activity)
            dimActivity = nil
        }
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        log.info("blank(dim): assertion + activity released")
    }

    /// 저장 밝기 `value` 를 복원한다 — 매 시도마다 대상을 재해석(RC2): 지금 resolve 되는
    /// built-in 을 우선하고, 아직 nil(패널 미복귀)이면 `fallback`(캡처 id)으로 폴백한다.
    /// 대상이 전혀 없거나 백엔드가 write 실패(false)를 보고하면 짧은 지연 뒤 bounded
    /// 재시도한다 — 방금 깨어난 패널이 잠깐 nil 을 주거나 write 를 거부하는 창을 흡수.
    /// 재시도는 main 큐에서 비동기로(동기 스핀 없음) 돌며, `generation` 이 현재 `episode`
    /// 와 다르면(복원 재호출 또는 새 dim 진입) 스스로 멈춰 루프 중첩을 막는다.
    private func attemptBrightnessRestore(_ value: Float, fallback: CGDirectDisplayID?,
                                         remaining: Int, generation: UInt) {
        // 세대가 바뀌었으면 이 루프는 낡은 것 — 조용히 종료(멱등).
        guard generation == episode else { return }
        // 복원 시점 재해석 우선, 없으면 캡처 id 폴백.
        let target = backend.builtinID() ?? fallback
        if let display = target, backend.set(display, value) { return }   // 성공 → 종료.
        guard remaining > 1 else {
            log.error("blank(dim): brightness restore failed after retries (target \(target ?? 0, privacy: .public))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreRetryDelay) { [weak self] in
            self?.attemptBrightnessRestore(value, fallback: fallback,
                                           remaining: remaining - 1, generation: generation)
        }
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
