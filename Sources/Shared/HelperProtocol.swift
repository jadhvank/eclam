import Foundation

/// XPC 프로토콜 버전 (v0.5 P1 — 업그레이드 트랩 감지, ADR-0020 후속).
/// selector 추가/시그니처 변경 등 앱↔daemon 호환이 깨지는 변경마다 +1.
/// 앱(`HelperBridge`)이 연결 수립(재수립) 시 `protocolVersion` RPC 1회로
/// 대조하고, 이 RPC 자체가 없는 pre-handshake daemon 은 reply 타임아웃 +
/// liveness 프로브로 "구버전 추정" 처리된다.
public enum HelperProtocolVersion {
    public static let current = 1
}

@objc public protocol ElectronicClamHelperProtocol {
    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Error?) -> Void)
    func currentState(reply: @escaping (Bool, Error?) -> Void)

    /// ADR-0025 — CLI TTL hold. helper 가 자체 타이머로 만료 시 복원하므로
    /// GUI heartbeat 없이도 유효하다 (`eclam on` 의 실체).
    /// `seconds < 0` ⇒ forever (CLI 가 경고와 함께 명시적으로만 보냄).
    /// 유한 값은 helper 가 [60s, 30d] 로 검증한다 (ADR-0023 입력 cap 정신).
    func holdSleepDisabled(forSeconds seconds: Double, reply: @escaping (Error?) -> Void)

    /// ADR-0025 — hold 상태만 비운다. 전원 쓰기는 별도 `setSleepDisabled(false)`
    /// (hold 활성 중의 off 쓰기는 무시되므로 반드시 cancel 이 먼저).
    func cancelHold(reply: @escaping (Error?) -> Void)

    /// ADR-0025 — `currentState` + hold 잔여. `remaining`: `-1` forever,
    /// `0` 없음, `>0` 남은 초. GUI 재수렴이 hold 를 외부 간섭으로 오인해
    /// 되돌리지 않도록 이 채널로 함께 보고한다.
    func currentStateWithHold(reply: @escaping (Bool, Double, Error?) -> Void)

    /// M1 — external activity ping. `source` is an `AgentTrace.id` (e.g. `"claude"`,
    /// `"codex"`) or a free-form hook label. The daemon sanitizes the value, then
    /// fans it out as a Darwin notification on
    /// `com.jadhvank.eclam.activity.<source>` so the app can react without
    /// keeping a long-lived XPC subscription. ADR-0006 §G.
    func pingActivity(source: String, reply: @escaping (Error?) -> Void)

    /// ADR-0004 §5 — watchdog heartbeat. The app fires this every 10 seconds
    /// while it considers the helper "live". If the helper does not see a
    /// heartbeat for 20 seconds AND it is currently keeping the Mac awake,
    /// the helper restores `SleepDisabled=false` on its own. Fire-and-forget
    /// on the app side; reply is the XPC ack only.
    func heartbeat(reply: @escaping (Error?) -> Void)

    /// Returns the most recent watchdog trip reason, or nil if the helper has
    /// not auto-restored sleep since launch. The string is one of:
    ///   - `"watchdog"`  — heartbeat starvation
    ///   - `"sigterm"`   — SIGTERM-driven shutdown restore
    /// The app reads this after reconnect to surface the cause to the user.
    func lastTripReason(reply: @escaping (String?, Error?) -> Void)

    /// v0.3.2 — publish the current "actively-working" agent set so out-of-band
    /// CLI calls (`eclam status --json`) can read it without polling the
    /// filesystem themselves. The app calls this whenever its
    /// `StateStore.activeAgents` set changes (debounced 250ms). IDs include
    /// both `AgentTrace.id` values and synthetic `session:<name>` entries from
    /// the `eclam session` family.
    func setActiveAgents(_ ids: [String], reply: @escaping (Error?) -> Void)

    /// v0.3.2 — snapshot of the most recent `setActiveAgents` call.
    /// Returns an empty array if the app has never reported one (e.g. helper
    /// just launched, app not running).
    func activeAgents(reply: @escaping ([String], Error?) -> Void)

    /// v0.5 P1 — 버전 핸드셰이크. 항상 `HelperProtocolVersion.current` 를
    /// 보고한다. 구버전 daemon 에는 이 selector 가 없어 호출이 에러 핸들러
    /// /무응답으로 끝나므로, 앱은 reply 타임아웃(2.5s)을 "버전 불명(구버전
    /// 추정)" 으로 다룬다 — `HelperBridge.performVersionHandshake`.
    func protocolVersion(reply: @escaping (Int) -> Void)
}

public enum HelperServiceName {
    public static let mach = "com.jadhvank.eclam.helper"

    /// Prefix for Darwin notifications fanned out per `pingActivity` source.
    /// Concrete name is `<prefix>.<sanitized-source>`. ADR-0006 §G.
    public static let activityNotifyPrefix = "com.jadhvank.eclam.activity"

    /// Hard cap on the sanitized source length. A rogue same-user XPC caller
    /// could otherwise hand `pingActivity` a megabyte-long string that the
    /// helper would splice into a Darwin notification name
    /// (`<prefix>.<source>`). Real `AgentTrace.id` / hook labels are a handful
    /// of chars, so 128 is generous while bounding what the helper synthesizes.
    /// Applied on top of the charset filter (ADR-0023 input caps).
    public static let maxActivitySourceLength = 128

    /// Lowercase, ascii-only, `[a-z0-9_-.]` only, length-capped. Used in both
    /// daemon (post) and app (subscribe) to guarantee both sides agree on the
    /// name.
    public static func sanitizeActivitySource(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        out.reserveCapacity(min(lowered.count, maxActivitySourceLength))
        for scalar in lowered.unicodeScalars {
            let v = scalar.value
            let isLower = (v >= 0x61 && v <= 0x7A)        // a-z
            let isDigit = (v >= 0x30 && v <= 0x39)        // 0-9
            let isSep   = (v == 0x5F || v == 0x2D || v == 0x2E) // _ - .
            if isLower || isDigit || isSep {
                out.append(Character(scalar))
                // Cap length so a rogue caller can't synthesize a huge
                // Darwin notification name (ADR-0023).
                if out.count >= maxActivitySourceLength { break }
            }
        }
        return out
    }
}

/// Minimal lock-guarded box for values that cross from XPC reply/error queues
/// to a synchronously-waiting caller (`HelperBridge.fetchActiveAgentsSync`,
/// the CLI's one-shot RPCs, the hook's bounded ping). The synchronous pattern
/// is `sem.wait(timeout:)` — after a timeout the caller reads the value on its
/// own thread while a *late* XPC callback may still be writing it, so a plain
/// `var` there is a data race. Every access goes through the lock instead.
/// Lives in Shared because the app/CLI target and the eclam-hook binary are
/// compiled separately and both need it.
public final class LockedBox<T> {
    private let lock = NSLock()
    private var value: T
    public init(_ value: T) { self.value = value }
    public func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    public func set(_ newValue: T) { lock.lock(); defer { lock.unlock() }; value = newValue }
}
