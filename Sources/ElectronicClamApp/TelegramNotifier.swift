import Foundation
import OSLog

/// ADR-0028 — 사용자 본인의 텔레그램 봇으로 상태 푸시.
///
/// 이 앱의 유일한 네트워크 egress. 목적지는 사용자가 직접 설정한
/// `api.telegram.org/bot<본인 토큰>` 하나뿐이고, 기본값은 완전 OFF (opt-in).
/// 개발자/제3자 서버로는 어떤 데이터도 보내지 않는다 — 이 원칙 자체가
/// ADR-0028 에 잠금되어 있다.
///
/// 이벤트 소스는 `AwakeHistoryStore` 의 에피소드 전환 탭 (onEpisodeStart /
/// onEpisodeEnd). 거기서 이미 시작 원인·종료 사유·디테일 귀속이 끝나 있으므로
/// 여기서는 게이팅(순수 `TelegramSupport`) → 문안 조립(NSL) → 전송만 한다.
///
/// 토큰 저장: `~/Library/Application Support/eclam/telegram.json` (0600).
/// Keychain 이 아닌 이유 — ad-hoc 서명은 빌드마다 code identity 가 바뀌어
/// Keychain ACL 재승인 프롬프트가 업데이트마다 뜨고, 이는 "권한 요청 1회"
/// 규약(CLAUDE.md §4)의 회귀다. v1.0 노터라이즈에서 Keychain 전환 검토.
final class TelegramNotifier {
    static let shared = TelegramNotifier()
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "telegram")

    /// 상태 스냅샷(배터리·온도·에이전트)을 읽기 위한 참조. AppDelegate 가
    /// 소유하는 단일 StateStore — configure(store:) 로 주입.
    private weak var store: StateStore?

    private(set) var settings: TelegramSettings = .default

    /// 직전 시작-알림 시각 (TelegramSupport.minStartGapSeconds 스로틀).
    private var lastStartNotifiedAt: Date?

    /// 주기 다이제스트(무음) 상태 — 에피소드 진행 중에만 타이머가 산다.
    /// "침묵 = 정상인지 죽었는지 모름"의 모호함을 깨는 하트비트. 메인 스레드 전용.
    private var episodeOngoing = false
    private var episodeStartedAt: Date?
    private var digestTimer: Timer?

    /// 마지막 전송 결과 — Settings 패널이 표시. nil ⇒ 이번 세션 전송 없음.
    /// 메인 스레드에서만 읽고 쓴다.
    private(set) var lastSendResult: String?
    private(set) var lastSendAt: Date?

    /// 전송 타임아웃 짧게 — 메시지는 best-effort 고, 곧 잠들 수도 있는 기계가
    /// 소켓을 오래 붙들 이유가 없다.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    private init() {
        settings = Self.loadSettings()
    }

    func configure(store: StateStore) {
        self.store = store
    }

    // MARK: - Settings persistence (0600 JSON)

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("eclam", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("telegram.json")
    }

    private static func loadSettings() -> TelegramSettings {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TelegramSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    /// 저장 + 권한 강제. atomic write 는 파일을 교체하므로 매 저장 후 0600 을
    /// 다시 박는다 (토큰 포함 파일 — ADR-0028 "토큰 저장").
    func update(settings next: TelegramSettings) {
        guard settings != next else { return }
        settings = next
        guard let url = Self.fileURL,
              let data = try? JSONEncoder().encode(next) else { return }
        do {
            // 첫 저장의 권한 공백 차단: 빈 파일을 0600 으로 먼저 만들어 둔다.
            // `.atomic` 교체는 기존 파일의 권한을 승계하므로, 이 사전 생성이
            // 없으면 최초 1회는 umask 기본값(644)으로 잠깐 존재한다.
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil,
                              attributes: [.posixPermissions: 0o600])
            }
            try data.write(to: url, options: .atomic)
            try fm.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("telegram settings save failed: \(error.localizedDescription, privacy: .public)")
        }
        // 간격·마스터가 에피소드 진행 중에 바뀌면 타이머를 새 설정으로 재구성.
        reconfigureDigestTimer()
    }

    // MARK: - Periodic digest (무음 하트비트 — ADR-0028 §7)

    /// 현재 설정·에피소드 상태에 맞춰 다이제스트 타이머를 (재)구성.
    /// 켜질 조건이 아니면 무조건 invalidate. 매 (재)구성마다 첫 발화는
    /// "지금 + 간격" — 시작 직후의 상태는 시작 이벤트가 이미 커버한다.
    private func reconfigureDigestTimer() {
        digestTimer?.invalidate()
        digestTimer = nil
        guard TelegramSupport.shouldSendDigest(settings: settings,
                                               episodeOngoing: episodeOngoing) else { return }
        let interval = TimeInterval(settings.digestIntervalMin * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.digestTick()
        }
        RunLoop.main.add(t, forMode: .common)
        digestTimer = t
    }

    private func digestTick() {
        // 설정·에피소드가 tick 사이에 바뀌었을 수 있다 — 전송 직전 재가드.
        guard TelegramSupport.shouldSendDigest(settings: settings,
                                               episodeOngoing: episodeOngoing) else { return }
        let dur = TelegramSupport.formatDuration(
            Date().timeIntervalSince(episodeStartedAt ?? Date()))
        let head = NSLf("telegram.digest", "📊 Still awake — %@", dur)
        // 무음(silent): 채팅에 쌓이되 알림음·배너 없음. 소리 나는 건 이벤트뿐.
        send(compose(head), silent: true)
    }

    // MARK: - Episode events (AwakeHistoryStore 탭, 메인 스레드)

    func episodeStarted(_ ep: AwakeEpisode) {
        episodeOngoing = true
        episodeStartedAt = ep.startedAt
        reconfigureDigestTimer()
        guard TelegramSupport.shouldNotifyStart(settings: settings,
                                                cause: ep.startCause,
                                                lastStartAt: lastStartNotifiedAt) else { return }
        lastStartNotifiedAt = Date()
        let head: String
        switch ep.startCause {
        case .agent:
            head = NSLf("telegram.start.agent", "🟢 Awake — %@ is working", ep.startDetail ?? "agent")
        case .remote:
            head = NSLf("telegram.start.remote", "🟢 Awake — remote session (%@)", ep.startDetail ?? "?")
        case .manual, .unknown:
            head = NSL("telegram.start.generic", "🟢 Awake — keeping the Mac up")
        }
        send(compose(head))
    }

    func episodeEnded(_ ep: AwakeEpisode) {
        episodeOngoing = false
        episodeStartedAt = nil
        reconfigureDigestTimer()
        guard TelegramSupport.shouldNotifyEnd(settings: settings,
                                              reason: ep.endReason ?? .unknown,
                                              durationSeconds: ep.duration) else { return }
        let dur = TelegramSupport.formatDuration(ep.duration)
        let head: String
        switch ep.endReason ?? .unknown {
        case .agentCeased:
            head = NSLf("telegram.end.agentIdle", "⚪️ %1$@ went idle — awake ended after %2$@",
                        ep.endDetail ?? "agent", dur)
        case .batteryLow:
            head = NSLf("telegram.end.battery", "🛑 Battery guard released sleep (%1$@) — your Mac may sleep soon. Awake %2$@",
                        ep.endDetail ?? "low", dur)
        case .thermalSerious, .thermalCritical:
            head = NSLf("telegram.end.thermal", "🛑 Thermal guard released sleep (%1$@) — your Mac may sleep soon. Awake %2$@",
                        ep.endDetail ?? "hot", dur)
        case .timer:
            head = NSLf("telegram.end.timer", "⏱ Max awake duration reached (%1$@) — sleep allowed. Awake %2$@",
                        ep.endDetail ?? dur, dur)
        case .watchdog:
            head = NSL("telegram.end.watchdog", "⚠️ Helper watchdog tripped — sleep restored")
        case .remoteEnded:
            head = NSLf("telegram.end.remoteEnded", "⚪️ Remote session ended (%1$@) — awake ended after %2$@",
                        ep.endDetail ?? "?", dur)
        case .remoteNetworkLost:
            head = NSLf("telegram.end.remoteLost", "⚪️ Remote session dropped (network lost) — awake ended after %@", dur)
        case .manualOff, .forceSleep, .appQuit, .unknown:
            // manualOff/forceSleep/appQuit 은 게이팅에서 .never 로 걸러졌고,
            // 여기 남는 건 unknown 뿐.
            head = NSLf("telegram.end.generic", "⚪️ Awake ended after %@", dur)
        }
        send(compose(head))
    }

    // MARK: - Test / Detect (Settings 패널)

    /// 테스트 전송. completion 은 메인 스레드, nil ⇒ 성공 / 문자열 ⇒ 에러.
    /// 게이팅을 우회해 master OFF 여도 토큰·chat id 만 있으면 보낸다 —
    /// 사용자가 켜기 전에 배선부터 확인하는 흐름이 자연스럽다.
    func sendTest(completion: @escaping (String?) -> Void) {
        guard !settings.botToken.isEmpty, !settings.chatId.isEmpty else {
            completion(NSL("telegram.error.notConfigured", "Enter a bot token and chat ID first."))
            return
        }
        let head = NSL("telegram.test", "🐚 Electronic Clam — test message. Notifications are wired up.")
        send(compose(head), bypassGate: true, completion: completion)
    }

    /// getUpdates 로 chat id 자동 감지. 사용자가 봇에 아무 메시지나 보낸 뒤
    /// 눌러야 한다. completion 은 메인 스레드 (chatId, errorMessage).
    func detectChatId(completion: @escaping (String?, String?) -> Void) {
        let token = settings.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TelegramSupport.looksLikeBotToken(token) else {
            completion(nil, NSL("telegram.error.badToken", "That doesn't look like a bot token (expected 123456:ABC…)."))
            return
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates") else {
            completion(nil, "bad URL")
            return
        }
        let task = session.dataTask(with: url) { [weak self] data, _, error in
            let result: (String?, String?)
            if let error = error {
                result = (nil, error.localizedDescription)
            } else if let data = data, let chatId = TelegramSupport.parseChatId(fromGetUpdates: data) {
                result = (chatId, nil)
            } else {
                // 빈 결과의 압도적 1위 원인: 사용자가 아직 봇에 말을 안 걸었다.
                result = (nil, NSL("telegram.error.noUpdates",
                    "No messages found. Send any message to your bot in Telegram, then try again."))
            }
            self?.log.info("detectChatId → \(result.0 != nil ? "found" : "not found", privacy: .public)")
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
        task.resume()
    }

    // MARK: - Internal

    /// head + (있으면) 현재 상태 한 줄.
    private func compose(_ head: String) -> String {
        guard let store = store else { return head }
        // SoC 센서(CPU/GPU) 우선 — thermal trip 을 실제로 끌고 가는 값.
        // 없으면(Intel/미지원) 배터리 온도로 폴백 (AwakeHistory.thermalDetail 패턴).
        let soc = [store.cpuTempCelsius, store.gpuTempCelsius].compactMap { $0 }.max()
            ?? store.batteryTempCelsius
        let status = TelegramSupport.statusLine(
            batteryPercent: store.batteryPercent,
            charging: store.isCharging,
            socTempCelsius: soc,
            activeAgents: Array(store.activeAgents),
            host: Host.current().localizedName)
        guard let status = status else { return head }
        return head + "\n" + status
    }

    /// sendMessage POST. 네트워크 오류(전송 자체 실패)에 한해 5초 뒤 1회 재시도.
    /// API 가 ok=false 로 답한 경우(잘못된 chat id 등)는 재시도 무의미 — 즉시 실패.
    private func send(_ text: String,
                      bypassGate: Bool = false,
                      silent: Bool = false,
                      completion: ((String?) -> Void)? = nil,
                      isRetry: Bool = false) {
        if !bypassGate {
            guard settings.isConfigured else { return }
        }
        let token = settings.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            finish("bad URL", completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["chat_id": settings.chatId, "text": text]
        // 다이제스트는 무음 — Telegram 이 알림음·배너 없이 배달한다.
        if silent { body["disable_notification"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                if !isRetry {
                    self.log.notice("telegram send failed (\(error.localizedDescription, privacy: .public)); retrying once in 5s")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        self.send(text, bypassGate: bypassGate, silent: silent,
                                  completion: completion, isRetry: true)
                    }
                    return
                }
                self.finish(error.localizedDescription, completion: completion)
                return
            }
            guard let data = data else {
                self.finish("empty response", completion: completion)
                return
            }
            let parsed = TelegramSupport.parseSendResult(data)
            self.finish(parsed.ok ? nil : (parsed.error ?? "unknown error"), completion: completion)
        }
        task.resume()
    }

    /// 결과 기록 + completion 마샬링. 토큰은 절대 로그에 남기지 않는다.
    private func finish(_ error: String?, completion: ((String?) -> Void)?) {
        if let error = error {
            log.error("telegram send error: \(error, privacy: .public)")
        } else {
            log.info("telegram message sent")
        }
        DispatchQueue.main.async {
            self.lastSendResult = error
            self.lastSendAt = Date()
            completion?(error)
        }
    }
}
