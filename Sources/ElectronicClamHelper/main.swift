import Foundation
import OSLog

let helperLog = Logger(subsystem: "com.jadhvank.eclam", category: "helper")

// SIGTERM handler (ADR-0002 §8 path 2): restore SleepDisabled=false then exit.
// `signal()` requires async-signal-safe work; we delegate to a dispatch source on main.
signal(SIGTERM, SIG_IGN)
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSource.setEventHandler {
    helperLog.warning("SIGTERM received, restoring SleepDisabled=0")
    Watchdog.shared.recordTrip(reason: "sigterm")
    _ = PowerController.setSleepDisabled(false)
    exit(0)
}
sigSource.resume()

// ADR-0025 — 영속 CLI hold 재무장 + 고아 SleepDisabled 복원. 위 SIGTERM
// 핸들러는 전원만 복원하고 hold 파일은 남기므로, 재부팅/재등록 후 이 호출이
// 남은 시간으로 다시 무장한다 (SleepDisabled 는 영속 설정 — 짝이 맞아야 함).
HoldManager.shared.restoreAtLaunch()

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperServiceName.mach)
listener.delegate = delegate
listener.resume()

helperLog.info("ElectronicClamHelper started, listening on \(HelperServiceName.mach, privacy: .public)")
RunLoop.main.run()
