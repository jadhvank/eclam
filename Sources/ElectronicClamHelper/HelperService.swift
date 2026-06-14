import Foundation
import OSLog

/// v0.3.2 — process-wide snapshot of "actively-working" agent ids reported by
/// the app via `setActiveAgents`. Lives outside `HelperService` because the
/// XPC listener creates a fresh `HelperService` per connection (ADR-0002 §6),
/// but the published set must survive across those short-lived instances.
/// Style mirrors `Watchdog.shared`.
final class ActiveAgentsStore {
    static let shared = ActiveAgentsStore()
    private let lock = NSLock()
    private var ids: [String] = []
    private init() {}

    func set(_ next: [String]) {
        lock.lock(); defer { lock.unlock() }
        // De-dupe + sort so snapshots are deterministic; cheap (<= a few dozen ids).
        var seen: Set<String> = []
        var out: [String] = []
        for id in next where !seen.contains(id) {
            seen.insert(id)
            out.append(id)
        }
        out.sort()
        ids = out
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ids
    }
}

final class HelperService: NSObject, ElectronicClamHelperProtocol {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "helper")

    /// 이 연결의 caller 가 `eclam-hook` 인가 (ADR-0023 §④ 방법 A). hook 은
    /// `pingActivity` 만 호출해야 하므로 전원/상태 변경 메서드를 거부한다.
    /// `HelperListenerDelegate` 가 connection 의 코드사인 정체성으로 판정해
    /// 주입한다 (dev-adhoc 빌드는 항상 false — 식별 불가 graceful fallback).
    private let isHook: Bool

    init(isHook: Bool) {
        self.isHook = isHook
        super.init()
    }

    /// hook caller 가 전원/상태 변경 메서드를 부르면 reply 로 돌려줄 에러.
    /// 호출부는 `if let err = denyIfHook(...) { reply(err); return }` 패턴.
    private func denyIfHook(_ method: String) -> NSError? {
        guard isHook else { return nil }
        log.error("\(method, privacy: .public) denied for hook caller (least privilege, ADR-0023)")
        return NSError(domain: "com.jadhvank.eclam.helper", code: 13,
                       userInfo: [NSLocalizedDescriptionKey:
                           "operation not permitted for this caller"])
    }

    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Error?) -> Void) {
        if let err = denyIfHook("setSleepDisabled") { reply(err); return }
        log.info("setSleepDisabled(\(enabled, privacy: .public))")
        // ADR-0025 — CLI TTL hold 활성 중의 off 쓰기(GUI converge·종료 복원)는
        // 무시한다: hold 가 전원 상태의 소유자이고 만료/취소 시 스스로 복원한다.
        // (GUI 종료가 hold 를 죽이지 않게 하는 핵심. 사용자 의도의 off 는
        // `cancelHold` 가 선행한다.) GUI 몫의 watchdog 만 disarm.
        if !enabled && HoldManager.shared.isActive {
            log.info("setSleepDisabled(false) deferred — CLI hold active (hold owns restore)")
            Watchdog.shared.armOrDisarm(keepingAwake: false)
            reply(nil)
            return
        }
        if PowerController.setSleepDisabled(enabled) {
            // Re-arm the watchdog so a fresh `keep awake` doesn't trip on the
            // most recent stale heartbeat (e.g. helper just came back).
            Watchdog.shared.armOrDisarm(keepingAwake: enabled)
            reply(nil)
        } else {
            let err = NSError(domain: "com.jadhvank.eclam.helper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "pmset failed"])
            reply(err)
        }
    }

    func currentState(reply: @escaping (Bool, Error?) -> Void) {
        let value = PowerController.readSleepDisabled()
        reply(value, nil)
    }

    // MARK: - ADR-0025 CLI TTL hold

    func holdSleepDisabled(forSeconds seconds: Double, reply: @escaping (Error?) -> Void) {
        if let err = denyIfHook("holdSleepDisabled") { reply(err); return }
        // 입력 검증 (ADR-0023 정신): 유한 hold 는 [60s, 30d]. 음수는 forever.
        if seconds >= 0 && (seconds < 60 || seconds > 30 * 24 * 3600) {
            reply(NSError(domain: "com.jadhvank.eclam.helper", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                              "hold duration out of range (60s…30d)"]))
            return
        }
        log.info("holdSleepDisabled(forSeconds: \(seconds, privacy: .public))")
        if HoldManager.shared.arm(seconds: seconds) {
            reply(nil)
        } else {
            reply(NSError(domain: "com.jadhvank.eclam.helper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "power write failed"]))
        }
    }

    func cancelHold(reply: @escaping (Error?) -> Void) {
        if let err = denyIfHook("cancelHold") { reply(err); return }
        log.info("cancelHold()")
        HoldManager.shared.cancel()
        reply(nil)
    }

    func currentStateWithHold(reply: @escaping (Bool, Double, Error?) -> Void) {
        reply(PowerController.readSleepDisabled(),
              HoldManager.shared.remainingSeconds(), nil)
    }

    func pingActivity(source: String, reply: @escaping (Error?) -> Void) {
        let sanitized = HelperServiceName.sanitizeActivitySource(source)
        guard !sanitized.isEmpty else {
            log.warning("pingActivity rejected: empty source after sanitize (raw=\(source, privacy: .public))")
            reply(NSError(domain: "com.jadhvank.eclam.helper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "empty source"]))
            return
        }
        ActivityRelay.post(source: sanitized)
        log.info("pingActivity source=\(sanitized, privacy: .public)")
        reply(nil)
    }

    func heartbeat(reply: @escaping (Error?) -> Void) {
        Watchdog.shared.beat()
        reply(nil)
    }

    func lastTripReason(reply: @escaping (String?, Error?) -> Void) {
        reply(Watchdog.shared.lastTripReason, nil)
    }

    func setActiveAgents(_ ids: [String], reply: @escaping (Error?) -> Void) {
        if let err = denyIfHook("setActiveAgents") { reply(err); return }
        // Clamp to a sane bound before `ActiveAgentsStore.set` (which sorts on
        // every call). Real reports are a handful of agent/session ids; 256 is
        // far above any legitimate set, so normal callers are unaffected. Caps
        // the work a rogue same-user caller can force per call (ADR-0023).
        let capped = ids.count > 256 ? Array(ids.prefix(256)) : ids
        ActiveAgentsStore.shared.set(capped)
        log.info("setActiveAgents count=\(capped.count, privacy: .public)")
        reply(nil)
    }

    func activeAgents(reply: @escaping ([String], Error?) -> Void) {
        reply(ActiveAgentsStore.shared.snapshot(), nil)
    }

    /// v0.5 P1 — 버전 핸드셰이크. 상수 보고만; 상태 없음.
    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(HelperProtocolVersion.current)
    }
}
