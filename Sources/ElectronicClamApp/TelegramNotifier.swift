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
    /// Non-nil until a failed disk save is retried successfully. Contains only local text.
    private(set) var settingsSaveError: String?

    /// 직전 시작-알림 시각 (ChatNotify.minStartGapSeconds 스로틀).
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

    private let delivery: NotificationDelivery
    private let settingsURL: URL?

    private convenience init() {
        self.init(settingsURL: Self.fileURL)
    }

    /// Isolated dependencies keep tests away from real credentials and the network.
    init(settingsURL: URL?, transport: NotificationTransport = URLSessionNotificationTransport(),
         schedule: @escaping NotificationDelivery.Scheduler = NotificationDelivery.scheduleOnMain) {
        self.settingsURL = settingsURL
        self.delivery = NotificationDelivery(transport: transport, schedule: schedule)
        if let url = settingsURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(TelegramSettings.self, from: data) {
            settings = decoded
        }
    }

    /// Terminal shutdown: late history callbacks must not start new network work.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        digestTimer?.invalidate()
        digestTimer = nil
        delivery.stop()
    }

    func configure(store: StateStore) {
        dispatchPrecondition(condition: .onQueue(.main))
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

    /// Runtime changes take effect immediately; a failed save remains retryable and visible.
    @discardableResult
    func update(settings next: TelegramSettings) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let changed = settings != next
        guard changed || settingsSaveError != nil else { return true }
        if changed {
            // OFF takes effect even when persistence fails, including during cancellation callbacks.
            settings = next
            delivery.invalidate()
            reconfigureDigestTimer()
        }
        do {
            guard let url = settingsURL else { throw SecureNotificationSettings.SaveError.unavailable }
            try SecureNotificationSettings.write(JSONEncoder().encode(next), to: url)
            settingsSaveError = nil
            return true
        } catch {
            // Never include filesystem errors: URLs and values can contain secrets.
            settingsSaveError = NSL("notification.error.saveSettings",
                "Settings could not be saved. Changes apply for this session; restart may restore previous settings. Try saving again.")
            log.error("telegram settings save failed")
            return false
        }
    }

    // MARK: - Periodic digest (무음 하트비트 — ADR-0028 §7)

    /// 현재 설정·에피소드 상태에 맞춰 다이제스트 타이머를 (재)구성.
    /// 켜질 조건이 아니면 무조건 invalidate. 매 (재)구성마다 첫 발화는
    /// "지금 + 간격" — 시작 직후의 상태는 시작 이벤트가 이미 커버한다.
    private func reconfigureDigestTimer() {
        digestTimer?.invalidate()
        digestTimer = nil
        guard !delivery.stopped else { return }
        guard ChatNotify.shouldSendDigest(settings: settings,
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
        guard ChatNotify.shouldSendDigest(settings: settings,
                                               episodeOngoing: episodeOngoing) else { return }
        let dur = ChatNotify.formatDuration(
            Date().timeIntervalSince(episodeStartedAt ?? Date()))
        let head = NSLf("telegram.digest", "📊 Still awake — %@", dur)
        // 무음(silent): 채팅에 쌓이되 알림음·배너 없음. 소리 나는 건 이벤트뿐.
        send(compose(head), silent: true)
    }

    // MARK: - Episode events (AwakeHistoryStore 탭, 메인 스레드)

    func episodeStarted(_ ep: AwakeEpisode) {
        dispatchPrecondition(condition: .onQueue(.main))
        episodeOngoing = true
        episodeStartedAt = ep.startedAt
        reconfigureDigestTimer()
        guard ChatNotify.shouldNotifyStart(settings: settings,
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
        dispatchPrecondition(condition: .onQueue(.main))
        episodeOngoing = false
        episodeStartedAt = nil
        reconfigureDigestTimer()
        guard ChatNotify.shouldNotifyEnd(settings: settings,
                                              reason: ep.endReason ?? .unknown,
                                              durationSeconds: ep.duration) else { return }
        let dur = ChatNotify.formatDuration(ep.duration)
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

    // MARK: - VPN safety-net (ADR-0037 S3 §폴백)

    /// ADR-0037 §폴백 — VPN(예: FortiClient) 세션이 Connected→Disconnected 로
    /// 떨어졌을 때의 안전망 알림. 가상 디스플레이 앵커(S1)가 실패했거나 잠금이
    /// 새어나가 VPN 이 끊긴 경우 사용자에게 "재인증 필요"를 알린다. **자동 재연결은
    /// 시도하지 않는다**(SAML 재인증 불가 — ADR-0037 §대안 `scutil --nc start` 실패).
    ///
    /// 마스터 opt-in(`isConfigured`) 게이트만 거친다 — 끊김은 SAML 재인증을 요구하는
    /// 치명적 이벤트라 하위 토글로 묵살되지 않게 한다. `VpnWatcher` 가 disconnect
    /// 에지에서 1회 호출(에피소드당 1회 디바운스). 메인 스레드에서 호출할 것
    /// (`compose` 가 store 를, `send` 가 `lastSend*` 를 메인 전제로 읽는다).
    func notifyVpnDisconnected(serviceName: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        // 게이트 결정 로그(BUG2 진단용) — master opt-in 이 꺼져 있으면 send 가 조용히
        // no-op 한다. 로컬 알림은 VpnWatcher 가 별도로 띄우므로 여기서 안 막힌다.
        log.notice("vpn-drop telegram: isConfigured(master opt-in)=\(self.settings.isConfigured, privacy: .public) — \(self.settings.isConfigured ? "attempting send" : "skipped (configure Telegram to enable)", privacy: .public)")
        let head = NSLf("telegram.vpn.dropped",
            "🔌 VPN disconnected (%@) — FortiClient needs re-auth (SAML). No auto-reconnect.",
            serviceName)
        send(compose(head))
    }

    // MARK: - Test / Detect (Settings 패널)

    /// 테스트 전송. completion 은 메인 스레드, nil ⇒ 성공 / 문자열 ⇒ 에러.
    /// 게이팅을 우회해 master OFF 여도 토큰·chat id 만 있으면 보낸다 —
    /// 사용자가 켜기 전에 배선부터 확인하는 흐름이 자연스럽다.
    func sendTest(completion: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !delivery.stopped else {
            completion(NotificationDiagnostic.transport(URLError(.cancelled)))
            return
        }
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
        dispatchPrecondition(condition: .onQueue(.main))
        guard !delivery.stopped else {
            completion(nil, NotificationDiagnostic.transport(URLError(.cancelled)))
            return
        }
        let token = settings.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TelegramSupport.looksLikeBotToken(token),
              let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates") else {
            completion(nil, NSL("telegram.error.badToken", "That doesn't look like a bot token (expected 123456:ABC…)."))
            return
        }
        delivery.send(URLRequest(url: url)) { data, response, error in
            if let error {
                completion(nil, NotificationDiagnostic.transport(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), let data else {
                completion(nil, NotificationDiagnostic.invalidResponse)
                return
            }
            let parsed = TelegramSupport.parseSendResult(data)
            guard parsed.ok else {
                completion(nil, parsed.error ?? NotificationDiagnostic.invalidResponse)
                return
            }
            if let chatId = TelegramSupport.parseChatId(fromGetUpdates: data) {
                completion(chatId, nil)
            } else {
                completion(nil, NSL("telegram.error.noUpdates",
                    "No messages found. Send any message to your bot in Telegram, then try again."))
            }
        }
    }

    // MARK: - Internal

    /// head + (있으면) 현재 상태 한 줄.
    private func compose(_ head: String) -> String {
        guard let store = store else { return head }
        // SoC 센서(CPU/GPU) 우선 — thermal trip 을 실제로 끌고 가는 값.
        // 없으면(Intel/미지원) 배터리 온도로 폴백 (AwakeHistory.thermalDetail 패턴).
        let soc = [store.cpuTempCelsius, store.gpuTempCelsius].compactMap { $0 }.max()
            ?? store.batteryTempCelsius
        let status = ChatNotify.statusLine(
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
                      completion: ((String?) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !delivery.stopped else {
            completion?(NotificationDiagnostic.transport(URLError(.cancelled)))
            return
        }
        guard bypassGate || settings.isConfigured else { return }
        let token = settings.botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TelegramSupport.looksLikeBotToken(token),
              !settings.chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            finish(NSL("telegram.error.badToken", "That doesn't look like a bot token (expected 123456:ABC…)."),
                   completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["chat_id": settings.chatId, "text": text]
        if silent { body["disable_notification"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        delivery.send(request, retryTransportFailure: true) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                if NotificationDelivery.isCancellation(error) {
                    completion?(NotificationDiagnostic.transport(error))
                } else {
                    self.finish(NotificationDiagnostic.transport(error), completion: completion)
                }
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), let data else {
                self.finish(NotificationDiagnostic.invalidResponse, completion: completion)
                return
            }
            let parsed = TelegramSupport.parseSendResult(data)
            self.finish(parsed.ok ? nil : (parsed.error ?? NotificationDiagnostic.invalidResponse),
                        completion: completion)
        }
    }

    /// 결과 기록 + completion 마샬링. 토큰은 절대 로그에 남기지 않는다.
    private func finish(_ error: String?, completion: ((String?) -> Void)?) {
        if let error = error {
            log.error("telegram send error: \(error, privacy: .public)")
        } else {
            log.info("telegram message sent")
        }
        lastSendResult = error
        lastSendAt = Date()
        completion?(error)
    }
}
