import Foundation
import OSLog

/// ADR-0025 — CLI TTL hold (`eclam on [--for <dur> | --forever]`)의 소유자.
///
/// GUI heartbeat 와 독립: helper 가 스스로 만료 시각에 복원하므로 "복원
/// 책임자가 항상 존재한다"는 불변규약 #1 이 GUI 없는 CLI-단독 사용에서도
/// 성립한다. 만료 시각은 디스크에 영속화되어 helper 재시작·재부팅을 넘어
/// 이어지고(SleepDisabled 는 영속 설정이므로 짝이 맞아야 함), 기록 없이
/// `SleepDisabled=true` 만 남은 고아 상태는 시작 시 복원한다.
///
/// 잠금 규율(데드락 방지): 상태는 `lock`(NSLock, leaf — 다른 잠금을 잡은 채
/// 호출되어도 안전), 타이머는 전용 직렬 큐. 만료 핸들러는 잠금을 모두 놓은
/// 뒤에야 `Watchdog`(자체 큐)을 조회한다. 역방향(`Watchdog` → `isActive`)은
/// leaf lock 만 잡으므로 AB-BA 순환이 없다.
final class HoldManager {
    static let shared = HoldManager()

    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "hold")
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "com.jadhvank.eclam.hold")
    private var timer: DispatchSourceTimer?
    private var holdUntil: Date?       // 유한 hold 의 만료 시각
    private var holdForever = false    // --forever

    private static let stateDir  = "/Library/Application Support/com.jadhvank.eclam"
    private static let statePath = stateDir + "/cli-hold"

    private init() {}

    // MARK: - Reads (leaf lock — 어떤 큐에서든 안전)

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        if holdForever { return true }
        guard let u = holdUntil else { return false }
        return u > Date()
    }

    /// 프로토콜 컨벤션: `-1` = forever, `0` = 없음, `>0` = 남은 초.
    func remainingSeconds(now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        if holdForever { return -1 }
        guard let u = holdUntil else { return 0 }
        return max(0, u.timeIntervalSince(now))
    }

    // MARK: - Mutations

    /// `seconds < 0` ⇒ forever. 전원 쓰기 성공 시에만 hold 를 기록한다.
    func arm(seconds: Double) -> Bool {
        guard PowerController.setSleepDisabled(true) else { return false }
        lock.lock()
        if seconds < 0 {
            holdForever = true
            holdUntil = nil
        } else {
            holdForever = false
            holdUntil = Date().addingTimeInterval(seconds)
        }
        let persisted = persistLocked()
        let until = holdUntil
        let forever = holdForever
        lock.unlock()
        schedule(until: until, forever: forever)
        // P3③ — best-effort persist (위 :50 주석). 실패해도 hold 을 거부하거나
        // rollback 하지 않는다(전원은 이미 켜졌고 고아 복원이 fail-safe 를 보장).
        // 다만 디스크 풀·IO 실패가 조용히 묻히지 않도록 로그는 남긴다.
        if !persisted {
            log.error("hold armed but persist failed — survives this session, not helper restart")
        }
        log.info("hold armed: \(forever ? "forever" : "\(Int(seconds))s", privacy: .public)")
        return true
    }

    /// 상태/파일/타이머만 비운다 — 전원 쓰기는 호출자 몫
    /// (`eclam off` 는 cancel 후 `setSleepDisabled(false)` 를 따로 보낸다).
    func cancel() {
        lock.lock()
        clearStateLocked()
        lock.unlock()
        timerQueue.async { [weak self] in self?.cancelTimerOnQueue() }
        log.info("hold cancelled")
    }

    /// helper 시작 시 1회 (main.swift). 영속 hold 재무장 + 고아 복원.
    func restoreAtLaunch() {
        // P3② — state 디렉토리는 helper 시작 시 1회만 보장한다. 매 arm 마다
        // createDirectory 를 호출하던 것을 여기로 옮겨 persistLocked 는 write 에
        // 집중한다. 실패해도 best-effort 이므로 막지 않고 로그만 남긴다.
        ensureStateDir()
        let fm = FileManager.default
        if let data = fm.contents(atPath: Self.statePath),
           let s = String(data: data, encoding: .utf8) {
            // 포맷 파싱은 순수 계층(HoldState)과 단일 진실원천을 공유한다.
            switch HoldState.parse(s) {
            case .forever:
                if arm(seconds: -1) { log.info("hold restored at launch: forever") }
                return
            case .until(let epoch):
                let remaining = epoch - Date().timeIntervalSince1970
                if remaining > 1 {
                    if arm(seconds: remaining) {
                        log.info("hold restored at launch: \(Int(remaining), privacy: .public)s left")
                    }
                    return
                }
                try? fm.removeItem(atPath: Self.statePath)
            case .none:
                break
            }
        }
        // 고아 복원: hold 기록이 없는데 SleepDisabled=true ⇒ 소유자 부재
        // (helper 크래시 등). GUI 가 살아 있다면 ≤10s 안에 자기 정책을 다시
        // 쓰므로(재수렴) 일단 안전한 쪽으로 복원한다.
        if PowerController.readSleepDisabled() {
            log.warning("orphan SleepDisabled=true at helper launch (no hold record); restoring")
            _ = PowerController.setSleepDisabled(false)
            Watchdog.shared.recordTrip(reason: "helper-restart")
        }
    }

    // MARK: - Timer (전용 큐)

    private func schedule(until: Date?, forever: Bool) {
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            self.cancelTimerOnQueue()
            guard !forever, let until = until else { return }
            let t = DispatchSource.makeTimerSource(queue: self.timerQueue)
            t.schedule(deadline: .now() + max(1, until.timeIntervalSinceNow))
            t.setEventHandler { [weak self] in self?.expireOnQueue() }
            t.resume()
            self.timer = t
        }
    }

    private func cancelTimerOnQueue() {
        timer?.cancel()
        timer = nil
    }

    private func expireOnQueue() {
        lock.lock()
        clearStateLocked()
        lock.unlock()
        cancelTimerOnQueue()
        // 잠금을 모두 놓은 뒤 Watchdog 조회 (잠금 규율 — 클래스 주석).
        // GUI 가 살아서 깨움을 유지 중이면 전원 상태는 GUI 소유 — 쓰지 않는다.
        if Watchdog.shared.isFedAndKeepingAwake {
            log.info("hold expired; GUI keep-awake active — leaving power state to the app")
            return
        }
        log.info("hold expired; restoring SleepDisabled=0")
        _ = PowerController.setSleepDisabled(false)
        Watchdog.shared.recordTrip(reason: "ttl")
    }

    // MARK: - State (lock 보유 상태에서만)

    private func clearStateLocked() {
        holdForever = false
        holdUntil = nil
        try? FileManager.default.removeItem(atPath: Self.statePath)
    }

    /// state 디렉토리를 1회 보장한다(P3②). 시작 경로(`restoreAtLaunch`)에서만
    /// 호출 — `persistLocked` 의 매-arm createDirectory 를 대체한다. 실패는
    /// best-effort 라 막지 않고 로그만 남긴다(write 단계에서 다시 드러난다).
    private func ensureStateDir() {
        do {
            try FileManager.default.createDirectory(atPath: Self.stateDir,
                                                    withIntermediateDirectories: true)
        } catch {
            log.error("could not create state dir \(Self.stateDir, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 만료 시각/forever 를 디스크에 영속화한다(P3③). write 에만 집중하고
    /// (디렉토리 생성은 `ensureStateDir` 가 시작 시 1회 처리), 성공 여부를
    /// 돌려주어 호출자가 실패를 로그할 수 있게 한다. force-unwrap 없이
    /// forever/finite 를 분기한다(P3① — 리팩터·오용 시 크래시 지뢰 제거).
    @discardableResult
    private func persistLocked() -> Bool {
        // P3① — 직렬화는 순수 계층(HoldState)에 위임. force-unwrap 없이
        // forever/finite 를 분기하고, finite 인데 만료 시각이 없는 (도달 불가)
        // 경우에도 now 로 폴백해 크래시 지뢰를 제거한다.
        let content = HoldState.serialize(forever: holdForever, holdUntil: holdUntil)
        do {
            try content.write(toFile: Self.statePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            log.error("could not persist hold to \(Self.statePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
