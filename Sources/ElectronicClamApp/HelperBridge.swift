import Foundation
import OSLog

/// Owns the NSXPCConnection to the privileged helper.
/// One long-lived connection per app launch; recreated lazily on invalidation.
final class HelperBridge {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "xpc")
    private let store: StateStore
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    /// v0.5 P1 — 버전 핸드셰이크 직렬 큐 (reply 타임아웃 대기 동안 블록되므로
    /// 전용 큐; 메인/XPC 큐와 무관).
    private let handshakeQueue = DispatchQueue(label: "com.jadhvank.eclam.handshake")
    /// `lock` 보호. 구버전 daemon 이 미구현 selector 수신으로 연결을
    /// invalidate 하면 "재연결 → 핸드셰이크 → invalidate" 루프가 생길 수
    /// 있어, 연결 생성이 잦아도 핸드셰이크는 이 간격으로만 다시 던진다.
    private var lastHandshakeAt: Date?
    private static let handshakeReplyTimeout: TimeInterval = 2.5
    private static let handshakeMinInterval: TimeInterval = 5.0

    init(store: StateStore) {
        self.store = store
    }

    private func ensureConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: HelperServiceName.mach, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ElectronicClamHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            self?.log.warning("xpc invalidated")
            self?.lock.lock()
            self?.connection = nil
            self?.lock.unlock()
        }
        c.interruptionHandler = { [weak self] in
            self?.log.warning("xpc interrupted")
        }
        c.resume()
        connection = c
        // v0.5 P1 — 버전 핸드셰이크: 연결 수립 시 1회 (+invalidation 후
        // 재수립 시). 폴링 없음; 위 throttle 이 비정상 재연결 폭주만 막는다.
        let now = Date()
        if lastHandshakeAt.map({ now.timeIntervalSince($0) >= Self.handshakeMinInterval }) ?? true {
            lastHandshakeAt = now
            handshakeQueue.async { [weak self] in self?.performVersionHandshake() }
        }
        return c
    }

    // MARK: - v0.5 P1 — protocol version handshake

    /// 업그레이드 직후 잔존한 구버전 daemon 감지 (ADR-0020 트랩 후속).
    ///
    /// `protocolVersion` 은 신규 selector 라 구버전 daemon 의 exported
    /// interface 에 없다. NSXPC 는 미구현 selector 수신 시 reply 를 절대
    /// 보내지 않고, 메시지 거부/연결 invalidation 으로 끝나 앱 쪽에서는
    /// ① 에러 핸들러 invoke 또는 ② 영원한 무응답 둘 중 하나로만 관측된다.
    /// 둘 다 2.5s reply 타임아웃으로 수렴시키되, "daemon 이 아예 죽어있음"
    /// 과 구분하기 위해 모든 세대 daemon 이 구현하는 `currentState` 를
    /// liveness 프로브로 이어 보낸다:
    ///   - version reply 수신          ⇒ mismatch = (v != current)
    ///   - version 실패 + liveness OK  ⇒ 버전 불명(구버전 추정) ⇒ mismatch
    ///   - version 실패 + liveness 실패 ⇒ 도달 불가 — 버전 문제 아님(등록
    ///     상태 UI 소관) ⇒ mismatch 해제
    /// 버전이 일치하면 플래그는 false 그대로 — 기존 동작 변화 0.
    private func performVersionHandshake() {
        let sem = DispatchSemaphore(value: 0)
        let version = LockedBox<Int?>(nil)
        guard let proxy = remoteProxy(errorHandler: { [weak self] err in
            self?.log.notice("protocolVersion xpc error (old daemon?): \(err.localizedDescription, privacy: .public)")
            sem.signal()
        }) else { return }
        proxy.protocolVersion { v in
            version.set(v)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + Self.handshakeReplyTimeout)

        let mismatch: Bool
        if let v = version.get() {
            mismatch = (v != HelperProtocolVersion.current)
            if mismatch {
                log.error("helper protocol v\(v, privacy: .public) != app v\(HelperProtocolVersion.current, privacy: .public) — reinstall needed")
            } else {
                log.info("helper protocol handshake OK (v\(v, privacy: .public))")
            }
        } else if probeLiveness() {
            log.error("helper alive but protocolVersion unanswered — pre-handshake daemon presumed; reinstall needed")
            mismatch = true
        } else {
            // 도달 불가: 등록/승인 문제이지 버전 문제가 아니다. 플래그를
            // 올리면 잘못된 안내(재설치)로 유도하므로 명시적으로 내린다.
            mismatch = false
        }
        DispatchQueue.main.async { [weak self] in
            self?.store.update(helperVersionMismatch: mismatch)
        }
    }

    /// 모든 세대 daemon 이 구현하는 `currentState` 1회 — "살아있는데 구버전"
    /// 과 "죽어있음/미승인" 을 구분하는 프로브. 미구현 selector 가 연결을
    /// invalidate 했더라도 `remoteProxy → ensureConnection` 이 새 연결을
    /// 만들므로 (throttle 이 중복 핸드셰이크는 막는다) 판정은 유효하다.
    private func probeLiveness() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let alive = LockedBox(false)
        guard let proxy = remoteProxy(errorHandler: { _ in sem.signal() }) else { return false }
        proxy.currentState { _, err in
            if err == nil { alive.set(true) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + Self.handshakeReplyTimeout) == .timedOut { return false }
        return alive.get()
    }

    private func remoteProxy(errorHandler: @escaping (Error) -> Void) -> ElectronicClamHelperProtocol? {
        let c = ensureConnection()
        let proxy = c.remoteObjectProxyWithErrorHandler { err in
            errorHandler(err)
        } as? ElectronicClamHelperProtocol
        return proxy
    }

    // MARK: - Public

    func setSleepDisabled(_ on: Bool, completion: @escaping (Error?) -> Void) {
        guard let proxy = remoteProxy(errorHandler: { err in
            DispatchQueue.main.async { completion(err) }
        }) else {
            DispatchQueue.main.async { completion(makeError("no proxy")) }
            return
        }
        proxy.setSleepDisabled(on) { [weak self] err in
            DispatchQueue.main.async {
                if let err = err {
                    self?.log.error("setSleepDisabled error: \(err.localizedDescription, privacy: .public)")
                    self?.store.update(lastError: err.localizedDescription)
                } else {
                    self?.store.update(sleepDisabled: on)
                    self?.store.update(lastError: nil)
                }
                completion(err)
            }
        }
    }

    /// Called on the main queue with every fresh `SleepDisabled` reading from
    /// `refreshCurrentState`. Lets AppDelegate detect out-of-band writes
    /// (`eclam on/off` talks to the helper directly) and drop its
    /// no-op-write cache instead of silently diverging.
    /// ADR-0025 — second param: CLI hold remaining (-1 forever / 0 none /
    /// >0 sec). A live hold is a *sanctioned* divergence, not a rogue write.
    var onReportedState: ((Bool, Double) -> Void)?

    func refreshCurrentState() {
        // P1-a — this is also the app's liveness signal. A connection-level XPC
        // failure (errorHandler) marks the helper unreachable; any reply clears
        // it. Drives the menu's "Helper not responding" warning for the
        // dead-but-`.enabled` case (handoff 2026-06-24). Called on launch, on
        // every menu open, and every 10s while we believe we're holding sleep
        // off — so a helper that dies mid-hold surfaces within one beat.
        guard let proxy = remoteProxy(errorHandler: { [weak self] err in
            DispatchQueue.main.async {
                self?.log.error("refreshCurrentState xpc error: \(err.localizedDescription, privacy: .public)")
                self?.store.update(helperUnreachable: true)
            }
        }) else {
            DispatchQueue.main.async { [weak self] in self?.store.update(helperUnreachable: true) }
            return
        }
        proxy.currentStateWithHold { [weak self] enabled, holdRemaining, err in
            DispatchQueue.main.async {
                // A reply landed → the helper is answering, regardless of payload.
                self?.store.update(helperUnreachable: false)
                if let err = err {
                    self?.log.error("currentState error: \(err.localizedDescription, privacy: .public)")
                    return
                }
                self?.store.update(sleepDisabled: enabled)
                self?.store.update(cliHoldRemaining: holdRemaining)
                self?.onReportedState?(enabled, holdRemaining)
            }
        }
    }

    /// ADR-0025 — cancel the CLI TTL hold (user clicked "sleep now" while a
    /// hold was active; the helper ignores plain off-writes during a hold).
    func cancelHold() {
        guard let proxy = remoteProxy(errorHandler: { [weak self] err in
            self?.log.error("cancelHold xpc error: \(err.localizedDescription, privacy: .public)")
        }) else { return }
        proxy.cancelHold { [weak self] err in
            if let err = err {
                self?.log.error("cancelHold reply error: \(err.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { self?.store.update(cliHoldRemaining: 0) }
        }
    }

    /// ADR-0004 §5 — fire-and-forget heartbeat. The 20s helper-side cutoff means
    /// we tolerate occasional drops; no retry/error path here.
    func heartbeat() {
        guard let proxy = remoteProxy(errorHandler: { [weak self] err in
            self?.log.debug("heartbeat xpc error: \(err.localizedDescription, privacy: .public)")
        }) else { return }
        proxy.heartbeat { _ in /* ack only */ }
    }

    /// Fetch the most recent watchdog/sigterm trip reason. Called after reconnect.
    func fetchLastTripReason(_ completion: @escaping (String?) -> Void) {
        guard let proxy = remoteProxy(errorHandler: { [weak self] err in
            self?.log.debug("lastTripReason xpc error: \(err.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { completion(nil) }
        }) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        proxy.lastTripReason { reason, _ in
            DispatchQueue.main.async { completion(reason) }
        }
    }

    /// v0.3.2 — push the current active-agents set to the helper so out-of-band
    /// CLI calls (`status --json`) can read it. Fire-and-forget; debouncing is
    /// the caller's responsibility.
    func setActiveAgents(_ ids: [String]) {
        guard let proxy = remoteProxy(errorHandler: { [weak self] err in
            self?.log.debug("setActiveAgents xpc error: \(err.localizedDescription, privacy: .public)")
        }) else { return }
        proxy.setActiveAgents(ids) { [weak self] err in
            if let err = err {
                self?.log.debug("setActiveAgents reply error: \(err.localizedDescription, privacy: .public)")
            }
        }
    }

    /// v0.3.2 — synchronous snapshot of the helper's published active-agents set.
    /// Used by `eclam status --json`. Returns `nil` on XPC failure so the
    /// caller can distinguish "no data" from "definitively empty".
    func fetchActiveAgentsSync(timeout: TimeInterval = 0.5) -> [String]? {
        let sem = DispatchSemaphore(value: 0)
        // Lock-guarded: the reply and the error handler land on XPC queues
        // while the caller waits (and, after a timeout, reads) on its own
        // thread — a plain `var` here was a data race.
        let result = LockedBox<[String]?>(nil)
        guard let proxy = remoteProxy(errorHandler: { _ in
            sem.signal()
        }) else { return nil }
        proxy.activeAgents { ids, err in
            if err == nil { result.set(ids) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return result.get()
    }

    /// Synchronously restore sleep on quit (ADR-0002 §8 path 1).
    /// Invariant #1: never exit with `SleepDisabled=true` left behind. Tries
    /// the existing connection, then retries once on a fresh one — the nil
    /// proxy / stale connection case used to be a silent early return, leaving
    /// the helper's SIGTERM/watchdog machinery as the *first* resort instead
    /// of the last. Worst case `2 × timeout` of blocking at quit.
    func shutdownAndRestore(timeout: TimeInterval) {
        for attempt in 1...2 {
            if attemptRestore(timeout: timeout) {
                if attempt > 1 { log.info("shutdownAndRestore: restored on retry") }
                break
            }
            log.warning("shutdownAndRestore attempt \(attempt) failed\(attempt < 2 ? "; retrying on a fresh connection" : " — watchdog is the last resort")")
            teardownConnection()  // force ensureConnection() to rebuild next attempt
        }
        teardownConnection()
    }

    /// One bounded restore attempt. `false` on nil proxy, XPC failure, helper
    /// error, or timeout.
    private func attemptRestore(timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let restored = LockedBox(false)
        guard let proxy = remoteProxy(errorHandler: { _ in sem.signal() }) else { return false }
        proxy.setSleepDisabled(false) { err in
            if err == nil { restored.set(true) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return false }
        return restored.get()
    }

    private func teardownConnection() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }
}

// `LockedBox` (lock-guarded value for sync-XPC timeout races) used to live
// here as a private type; it moved to Sources/Shared/HelperProtocol.swift so
// the CLI commands and the separately-compiled eclam-hook binary can reuse it.

private func makeError(_ msg: String) -> NSError {
    NSError(domain: "com.jadhvank.eclam", code: -1,
            userInfo: [NSLocalizedDescriptionKey: msg])
}
