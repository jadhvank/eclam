import Foundation
import IOKit.pwr_mgt
import OSLog

/// ADR-0037 S1 — 헤드리스 클램쉘 잠금 방지 "세션 앵커" 컨트롤러.
///
/// keep 신호가 살아있고(`keepAwake`) 실물 외장 디스플레이가 없으며
/// (`externalDisplayPresent == false`) 사용자가 옵트인했을 때만
/// (`store.clamshellLockGuardEnabled`) 보이지 않는 가상 디스플레이를 띄운다.
/// 그러면 덮개를 닫아 내장 패널이 빠져도 활성 디스플레이가 0개가 되지 않아 화면
/// 잠금이 발생하지 않고, FortiClient 같은 VPN 세션이 끊기지 않는다.
///
/// 실제 디스플레이 생성·미러·해제는 ObjC shim(`EClamVirtualDisplay`)이 소유한다.
/// 이 컨트롤러는 정책(언제 켜고 끌지)만 가지며 helper·`SleepDisabled` 기구와는
/// 무관하다(ADR-0037 §결정). `apply(...)` 는 멱등이라 converge 마다 호출해도
/// 안전하다.
final class VirtualDisplayController {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "vdisplay")
    private let store: StateStore
    private let anchor = EClamVirtualDisplay()

    /// SPI 가 없거나 헤드리스라 `start()` 가 실패한 경우, 같은 조건에서 매 converge
    /// 마다 재시도/재로그하는 스팸을 막는 게이트. 조건이 풀리면(want=false) 리셋해
    /// 다음 진입 때 한 번 더 시도한다.
    private var startFailed = false

    /// ADR-0037 S1 (실측 버그 수정) — 앵커가 사는 동안 함께 잡는 idle DISPLAY-sleep
    /// 방지 assertion. `0` = 미보유.
    ///
    /// **왜 필요한가**: `SleepDisabled=1`(ADR-0001)은 시스템·덮개-닫힘 sleep 만 막고
    /// **idle display-sleep 타이머**는 못 막는다. 가상 디스플레이도 하나의 디스플레이라,
    /// 배터리 `displaysleep` idle 타임아웃(~2분) 동안 입력이 없으면 macOS 가 그 가상
    /// 디스플레이를 idle-sleep 시켜 활성 디스플레이가 0개가 되고 → 다시 잠금이 샌다
    /// (실측: 짧은 덮개-닫힘은 안 잠기지만 몇 분 뒤 잠김 + VPN 끊김). 그래서 앵커가
    /// 살아있는 동안 public `IOPMAssertionCreateWithName`(`PreventUserIdleDisplaySleep`)
    /// 으로 idle display-sleep + 스크린세이버를 막아 가상 디스플레이가 무너지지 않게
    /// 한다. 헤드리스 클램쉘에선 내장 패널이 물리적으로 꺼져 있고 가상 디스플레이는
    /// 백라이트가 없어 비용 ~0. S2 `BlankDisplayDimmer` 의 같은 타입 assertion 과는
    /// 독립이며(IOPM 이 ref-count 로 관리) 충돌하지 않는다.
    private var idleSleepAssertionID: IOPMAssertionID = 0

    init(store: StateStore) {
        self.store = store
    }

    deinit {
        // 안전망 — 정상 흐름은 `apply(keepAwake: false, …)`(앱 종료 경로,
        // AppDelegate.applicationWillTerminate)에서 이미 풀지만, 미래 리팩터로
        // 컨트롤러가 먼저 해제돼도 assertion 이 새지 않게 한다.
        releaseIdleSleepAssertion()
    }

    /// converge 경로에서 매번 호출(멱등). 조건이 맞으면 앵커를 올리고, 아니면 내린다.
    /// - Parameters:
    ///   - keepAwake: 현재 keep(깨어있기) 신호 = `store.shouldKeepAwake`.
    ///   - externalDisplayPresent: 실물 외장 디스플레이 존재 여부
    ///     (`SafetyMonitor` 가 채운 `store.extDisplayPresent` 재사용).
    func apply(keepAwake: Bool, externalDisplayPresent: Bool) {
        let wantActive = keepAwake
            && !externalDisplayPresent
            && store.clamshellLockGuardEnabled

        if wantActive {
            if anchor.active { return }
            if startFailed { return }
            if anchor.start() {
                // 앵커가 떴으면 idle display-sleep 도 같이 막는다 — 안 그러면 ~2분
                // 무입력 뒤 가상 디스플레이가 idle-sleep 돼 잠금이 다시 샌다.
                holdIdleSleepAssertion()
                log.info("clamshell lock guard: anchor started (keep on, no external display)")
            } else {
                // SPI 미가용/헤드리스. ADR-0037 §폴백 — 이 실패의 *실제 결과*(앵커가
                // 못 떠서 덮개 닫으면 잠금→VPN 끊김)는 S3 `VpnWatcher` 가 런타임에
                // 잡는다: VpnWatcher 는 SPI 성공이 아니라 keep+opt-in 게이트로만 도므로,
                // 앵커가 못 떠도 폴링이 살아 있어 실제 Connected→Disconnected 에지에서
                // "VPN 재인증 필요"를 알린다. 여기서 선제 알림을 또 쏘지 않는 이유 —
                // start() 는 아직 헤드리스가 아닐 때도(덮개 열림·전이 중) 실패할 수 있어
                // 선제 발사는 오발·소음이 된다. 끊김은 실제로 끊길 때만 알린다.
                startFailed = true
                log.error("clamshell lock guard: anchor start failed (SPI unavailable or headless); no-op until conditions change")
            }
        } else {
            startFailed = false
            if anchor.active {
                anchor.stop()
                log.info("clamshell lock guard: anchor stopped (keep off or external display present)")
            }
            // 앵커와 짝지어 항상 푼다(멱등 — 안 잡고 있으면 no-op). anchor.active
            // 가 false 여도 호출해 어떤 경로로든 새지 않게 한다.
            releaseIdleSleepAssertion()
        }
    }

    /// 앵커가 살아있는 동안 idle display-sleep 을 막는 public IOKit assertion 을
    /// 잡는다. 이미 잡고 있으면 no-op(멱등). `BlankDisplayDimmer`(S2)와 같은 패턴.
    private func holdIdleSleepAssertion() {
        guard idleSleepAssertionID == 0 else { return }
        var aid: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Electronic Clam — clamshell lock guard" as CFString,
            &aid)
        if r == kIOReturnSuccess {
            idleSleepAssertionID = aid
            log.info("clamshell lock guard: PreventUserIdleDisplaySleep assertion held")
        } else {
            idleSleepAssertionID = 0
            log.error("clamshell lock guard: PreventUserIdleDisplaySleep assertion failed: \(r, privacy: .public)")
        }
    }

    /// 잡고 있던 idle display-sleep assertion 을 푼다. 안 잡고 있으면 no-op.
    private func releaseIdleSleepAssertion() {
        guard idleSleepAssertionID != 0 else { return }
        IOPMAssertionRelease(idleSleepAssertionID)
        idleSleepAssertionID = 0
        log.info("clamshell lock guard: PreventUserIdleDisplaySleep assertion released")
    }
}
