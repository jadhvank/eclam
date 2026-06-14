import Foundation
import OSLog

/// ADR-0004 §5 — helper-side dead-man switch.
///
/// The app must heartbeat every 10 seconds. If the helper goes 20 seconds
/// without one *and* is currently keeping the Mac awake, it forces
/// `SleepDisabled=false` on its own. This bounds how long a crashed/hung app
/// can keep the lid-closed Mac running on battery.
///
/// Singleton because `HelperService` is per-connection but the watchdog state
/// must outlive any individual NSXPCConnection.
final class Watchdog {
    static let shared = Watchdog()

    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "watchdog")
    private let queue = DispatchQueue(label: "com.jadhvank.eclam.watchdog")
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat: Date = Date()
    private var keepingAwake: Bool = false

    /// 20s cutoff per ADR-0004 §5.
    private let cutoff: TimeInterval = 20

    private(set) var lastTripReason: String?

    private init() {}

    /// Called from `HelperService.setSleepDisabled`. Tells the watchdog the
    /// current commanded state. When transitioning to "keeping awake" we reset
    /// the heartbeat clock so the first heartbeat has a full 20s window to
    /// arrive; when transitioning to "not keeping awake" we disarm.
    func armOrDisarm(keepingAwake on: Bool) {
        queue.sync {
            self.keepingAwake = on
            self.lastHeartbeat = Date()
            if on {
                ensureTimerLocked()
            } else {
                timer?.cancel()
                timer = nil
            }
        }
    }

    func beat() {
        queue.sync {
            self.lastHeartbeat = Date()
        }
    }

    func recordTrip(reason: String) {
        queue.sync {
            self.lastTripReason = reason
        }
    }

    /// ADR-0025 — HoldManager 만료 판단용: heartbeat 가 신선하고 GUI 가
    /// keep-awake 를 명령 중인가. (HoldManager 는 잠금을 모두 놓은 뒤에만
    /// 이걸 호출한다 — 잠금 규율은 HoldManager 클래스 주석.)
    var isFedAndKeepingAwake: Bool {
        queue.sync {
            keepingAwake && Date().timeIntervalSince(lastHeartbeat) <= cutoff
        }
    }

    // MARK: - Internals

    private func ensureTimerLocked() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // First check 5s in; then every 5s. Frequent enough that the 20s
        // cutoff has 4 samples of resolution.
        t.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        t.setEventHandler { [weak self] in
            self?.checkLocked()
        }
        t.resume()
        timer = t
        log.info("watchdog armed (cutoff=\(self.cutoff, privacy: .public)s)")
    }

    private func checkLocked() {
        guard keepingAwake else { return }
        let age = Date().timeIntervalSince(lastHeartbeat)
        if age > cutoff {
            // ADR-0025 — CLI TTL hold 가 살아 있으면 전원 상태의 소유자는
            // hold 다: GUI 죽음 때문에 hold 를 꺾지 않는다. GUI 몫의 감시만
            // disarm 하고 복원은 hold 만료 타이머에 맡긴다.
            // (`HoldManager.isActive` 는 leaf NSLock — 순환 잠금 없음.)
            if HoldManager.shared.isActive {
                log.info("watchdog starved but CLI hold active — disarming app-side watch only")
                keepingAwake = false
                timer?.cancel()
                timer = nil
                return
            }
            log.error("watchdog tripped: \(age, privacy: .public)s since last heartbeat; restoring SleepDisabled=0")
            _ = PowerController.setSleepDisabled(false)
            lastTripReason = "watchdog"
            keepingAwake = false
            timer?.cancel()
            timer = nil
        }
    }
}
