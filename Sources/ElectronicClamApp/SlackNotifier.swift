import Foundation
import OSLog

/// Slack 알림 — 사용자 본인의 Slack 앱(봇)으로 상태 푸시.
///
/// `TelegramNotifier`(ADR-0028)의 형제다. 이벤트 소스·게이팅·문안 구성은 같고,
/// 목적지만 `slack.com/api/chat.postMessage` 다. ADR-0028 이 잠근 원칙은
/// 그대로 유지된다 — **기본값 완전 OFF(opt-in)**, 목적지는 사용자가 직접 만든
/// Slack 앱이 붙어 있는 워크스페이스 하나뿐, 개발자·제3자 서버로는 아무것도
/// 보내지 않는다. ADR-0028 의 "이 앱의 유일한 네트워크 egress" 문장은 이제
/// "사용자가 직접 설정한 채팅 백엔드(Telegram·Slack)로만 나간다"로 넓어진다.
///
/// 자격 정보는 두 갈래를 받고 값의 생김새로 고른다 (SlackSupport.credentialKind):
/// 봇 토큰이면 `chat.postMessage` 에 채널을 실어 보내고, Incoming Webhook URL
/// 이면 그 URL 로 바로 POST 한다 (채널은 webhook 에 이미 박혀 있다).
///
/// Telegram 과 다른 점 둘:
///   ① Slack 에는 무음 전송이 없다 → 다이제스트도 일반 메시지로 간다.
///   ② Web API 는 실패해도 HTTP 200 이 온다 → 본문 `ok` 를 봐야 한다.
///      webhook 은 반대로 평문 `ok` + HTTP 4xx 다 (SlackSupport 가 둘 다 판정).
///
/// 토큰 저장: `~/Library/Application Support/eclam/slack.json` (0600).
/// Keychain 을 쓰지 않는 이유는 TelegramNotifier 주석과 같다.
final class SlackNotifier {
    static let shared = SlackNotifier()
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "slack")

    /// 상태 스냅샷(배터리·온도·에이전트)을 읽기 위한 참조. AppDelegate 가
    /// 소유하는 단일 StateStore — configure(store:) 로 주입.
    private weak var store: StateStore?

    private(set) var settings: SlackSettings = .default
    /// Non-nil until a failed disk save is retried successfully. Contains only local text.
    private(set) var settingsSaveError: String?

    /// 직전 시작-알림 시각 (ChatNotify.minStartGapSeconds 스로틀).
    private var lastStartNotifiedAt: Date?

    /// 주기 다이제스트 상태 — 에피소드 진행 중에만 타이머가 산다. 메인 스레드 전용.
    private var episodeStartedAt: Date?
    private var digestTimer: Timer?

    /// 채널 이름 조회에서 훑을 최대 페이지 수. 워크스페이스가 아주 크면
    /// 전수 조회가 rate limit 을 부르므로, 못 찾으면 ID 직접 입력을 안내한다.
    private static let maxLookupPages = 5

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
           let decoded = try? JSONDecoder().decode(SlackSettings.self, from: data) {
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
        return dir.appendingPathComponent("slack.json")
    }

    /// Runtime changes take effect immediately; a failed save remains retryable and visible.
    @discardableResult
    func update(settings next: SlackSettings) -> Bool {
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
            log.error("slack settings save failed")
            return false
        }
    }

    // MARK: - Periodic digest

    /// 현재 설정·에피소드 상태에 맞춰 다이제스트 타이머를 (재)구성.
    private func reconfigureDigestTimer() {
        digestTimer?.invalidate()
        digestTimer = nil
        guard !delivery.stopped else { return }
        guard ChatNotify.shouldSendDigest(settings: settings,
                                          episodeOngoing: episodeStartedAt != nil) else { return }
        let interval = TimeInterval(settings.digestIntervalMin * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.digestTick()
        }
        RunLoop.main.add(t, forMode: .common)
        digestTimer = t
    }

    private func digestTick() {
        guard ChatNotify.shouldSendDigest(settings: settings,
                                          episodeOngoing: episodeStartedAt != nil) else { return }
        let dur = ChatNotify.formatDuration(
            Date().timeIntervalSince(episodeStartedAt ?? Date()))
        let head = NSLf("slack.digest", "📊 Still awake — %@", dur)
        send(compose(head))
    }

    // MARK: - Episode events (AwakeHistoryStore 탭, 메인 스레드)

    func episodeStarted(_ ep: AwakeEpisode) {
        dispatchPrecondition(condition: .onQueue(.main))
        episodeStartedAt = ep.startedAt
        reconfigureDigestTimer()
        guard ChatNotify.shouldNotifyStart(settings: settings,
                                           cause: ep.startCause,
                                           lastStartAt: lastStartNotifiedAt) else { return }
        lastStartNotifiedAt = Date()
        let head: String
        switch ep.startCause {
        case .agent:
            head = NSLf("slack.start.agent", "🟢 Awake — %@ is working", ep.startDetail ?? "agent")
        case .remote:
            head = NSLf("slack.start.remote", "🟢 Awake — remote session (%@)", ep.startDetail ?? "?")
        case .manual, .unknown:
            head = NSL("slack.start.generic", "🟢 Awake — keeping the Mac up")
        }
        send(compose(head))
    }

    func episodeEnded(_ ep: AwakeEpisode) {
        dispatchPrecondition(condition: .onQueue(.main))
        episodeStartedAt = nil
        reconfigureDigestTimer()
        guard ChatNotify.shouldNotifyEnd(settings: settings,
                                         reason: ep.endReason ?? .unknown,
                                         durationSeconds: ep.duration) else { return }
        let dur = ChatNotify.formatDuration(ep.duration)
        let head: String
        switch ep.endReason ?? .unknown {
        case .agentCeased:
            head = NSLf("slack.end.agentIdle", "⚪️ %1$@ went idle — awake ended after %2$@",
                        ep.endDetail ?? "agent", dur)
        case .batteryLow:
            head = NSLf("slack.end.battery", "🛑 Battery guard released sleep (%1$@) — your Mac may sleep soon. Awake %2$@",
                        ep.endDetail ?? "low", dur)
        case .thermalSerious, .thermalCritical:
            head = NSLf("slack.end.thermal", "🛑 Thermal guard released sleep (%1$@) — your Mac may sleep soon. Awake %2$@",
                        ep.endDetail ?? "hot", dur)
        case .timer:
            head = NSLf("slack.end.timer", "⏱ Max awake duration reached (%1$@) — sleep allowed. Awake %2$@",
                        ep.endDetail ?? dur, dur)
        case .watchdog:
            head = NSL("slack.end.watchdog", "⚠️ Helper watchdog tripped — sleep restored")
        case .remoteEnded:
            head = NSLf("slack.end.remoteEnded", "⚪️ Remote session ended (%1$@) — awake ended after %2$@",
                        ep.endDetail ?? "?", dur)
        case .remoteNetworkLost:
            head = NSLf("slack.end.remoteLost", "⚪️ Remote session dropped (network lost) — awake ended after %@", dur)
        case .manualOff, .forceSleep, .appQuit, .unknown:
            // manualOff/forceSleep/appQuit 은 게이팅에서 .never 로 걸러졌고,
            // 여기 남는 건 unknown 뿐.
            head = NSLf("slack.end.generic", "⚪️ Awake ended after %@", dur)
        }
        send(compose(head))
    }

    // MARK: - VPN safety-net (ADR-0037 S3 §폴백)

    /// VPN 세션이 Connected→Disconnected 로 떨어졌을 때의 안전망 알림.
    /// Telegram 쪽과 같은 규칙 — 마스터 opt-in 게이트만 거치고, 하위 토글로
    /// 묵살되지 않는다. `VpnWatcher` 가 disconnect 에지에서 1회 호출한다.
    func notifyVpnDisconnected(serviceName: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        log.notice("vpn-drop slack: isConfigured(master opt-in)=\(self.settings.isConfigured, privacy: .public) — \(self.settings.isConfigured ? "attempting send" : "skipped (configure Slack to enable)", privacy: .public)")
        let head = NSLf("slack.vpn.dropped",
            "🔌 VPN disconnected (%@) — FortiClient needs re-auth (SAML). No auto-reconnect.",
            serviceName)
        send(compose(head))
    }

    // MARK: - Test / Lookup (Settings 패널)

    /// 테스트 전송. completion 은 메인 스레드, nil ⇒ 성공 / 문자열 ⇒ 에러.
    /// 게이팅을 우회해 master OFF 여도 토큰·채널만 있으면 보낸다.
    func sendTest(completion: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !delivery.stopped else {
            completion(NotificationDiagnostic.transport(URLError(.cancelled)))
            return
        }
        guard settings.isConfiguredIgnoringMaster else {
            completion(NSL("slack.error.notConfigured",
                "Enter a bot token and a channel, or an incoming webhook URL, first."))
            return
        }
        let head = NSL("slack.test", "🐚 Electric Clam — test message. Notifications are wired up.")
        send(compose(head), bypassGate: true, completion: completion)
    }

    /// 채널 이름 → 채널 ID 조회 ("Look up ID" 버튼). 이미 ID 형태면 그대로
    /// 돌려준다. completion 은 메인 스레드 (channelId, errorMessage).
    func lookupChannelId(completion: @escaping (String?, String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !delivery.stopped else {
            completion(nil, NotificationDiagnostic.transport(URLError(.cancelled)))
            return
        }
        let token = settings.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if SlackSupport.credentialKind(token) == .webhook {
            completion(nil, NSL("slack.error.webhookHasChannel",
                "An incoming webhook already posts to one fixed channel — no lookup needed."))
            return
        }
        guard SlackSupport.looksLikeBotToken(token) else {
            completion(nil, NSL("slack.error.badTokenFormat",
                "That doesn't look like a Slack token (expected xoxb-…) or an incoming webhook URL."))
            return
        }
        let name = SlackSupport.normalizeChannel(settings.channel)
        guard !name.isEmpty else {
            completion(nil, NSL("slack.error.noChannelTyped",
                "Type a channel name (like #general) first, then look it up."))
            return
        }
        if SlackSupport.looksLikeChannelId(name) {
            completion(name, nil)
            return
        }
        lookupPage(token: token, name: name, cursor: nil, page: 1, completion: completion)
    }

    /// conversations.list 한 페이지 조회 후 필요하면 다음 페이지로 이어간다.
    private func lookupPage(token: String, name: String, cursor: String?, page: Int,
                            completion: @escaping (String?, String?) -> Void) {
        var comps = URLComponents(string: "https://slack.com/api/conversations.list")
        var items = [
            URLQueryItem(name: "types", value: "public_channel,private_channel"),
            URLQueryItem(name: "exclude_archived", value: "true"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        if let cursor = cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        comps?.queryItems = items
        guard let url = comps?.url else {
            completion(nil, NotificationDiagnostic.invalidResponse)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        delivery.send(request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(nil, NotificationDiagnostic.transport(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), let data else {
                completion(nil, NotificationDiagnostic.invalidResponse)
                return
            }
            let posted = SlackSupport.parsePostResult(data)
            guard posted.ok else {
                completion(nil, self.message(forFailure: SlackSupport.classify(error: posted.error ?? "")))
                return
            }
            let found = SlackSupport.parseChannelId(fromConversationsList: data, name: name)
            if let id = found.id {
                self.log.info("slack channel lookup → found")
                completion(id, nil)
                return
            }
            if let next = found.nextCursor, page < Self.maxLookupPages {
                self.lookupPage(token: token, name: name, cursor: next, page: page + 1,
                                completion: completion)
                return
            }
            completion(nil, NSL("slack.error.noMatch",
                "No channel with that name is visible to the bot. Invite the bot to the channel, or paste the channel ID (C…) instead."))
        }
    }

    // MARK: - Internal

    /// head + (있으면) 현재 상태 한 줄.
    private func compose(_ head: String) -> String {
        guard let store = store else { return head }
        // SoC 센서(CPU/GPU) 우선 — thermal trip 을 실제로 끌고 가는 값.
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

    /// Slack error 코드 → 사용자가 다음에 할 일이 보이는 문장.
    private func message(forFailure kind: SlackSupport.FailureKind) -> String {
        switch kind {
        case .badToken:
            return NSL("slack.error.badToken",
                "Slack rejected the token. Re-copy the bot token from your Slack app's OAuth page.")
        case .missingScope:
            return NSL("slack.error.missingScope",
                "The token is missing a scope. Add chat:write (and channels:read to look up channel names), then reinstall the app to your workspace.")
        case .botNotInChannel:
            return NSL("slack.error.notInChannel",
                "The bot can't post there. Invite it to the channel with /invite @your-bot, then try again.")
        case .rateLimited:
            return NSL("slack.error.rateLimited", "Slack is rate-limiting us. Try again in a minute.")
        case .other:
            return NSL("slack.error.rejected", "Slack rejected the request. Check the bot permissions and destination.")
        }
    }

    /// 전송. 자격 정보 갈래에 따라 요청을 만들고, 네트워크 오류(전송 자체
    /// 실패)에 한해 5초 뒤 1회 재시도한다. Slack 이 내용을 보고 거절한 경우
    /// (scope 누락·채널 없음 등)는 재시도가 무의미하므로 즉시 실패로 끝낸다.
    private func send(_ text: String,
                      bypassGate: Bool = false,
                      completion: ((String?) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !delivery.stopped else {
            completion?(NotificationDiagnostic.transport(URLError(.cancelled)))
            return
        }
        guard bypassGate || settings.isConfigured else { return }
        let credential = settings.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = SlackSupport.credentialKind(credential)
        guard let request = buildRequest(credential: credential, kind: kind, text: text) else {
            finish(NSL("slack.error.badTokenFormat",
                "That doesn't look like a Slack token (expected xoxb-…) or an incoming webhook URL."),
                   completion: completion)
            return
        }
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
            let parsed = kind == .webhook
                ? SlackSupport.parseWebhookResult(status: response.statusCode, body: data)
                : SlackSupport.parsePostResult(data)
            self.finish(parsed.ok ? nil : self.message(forFailure:
                SlackSupport.classify(error: parsed.error ?? "")), completion: completion)
        }
    }

    /// 갈래별 요청 조립. webhook 은 URL 자체가 목적지이자 자격 증명이라
    /// Authorization 헤더가 없고 채널도 싣지 않는다.
    private func buildRequest(credential: String,
                              kind: SlackSupport.CredentialKind,
                              text: String) -> URLRequest? {
        let url: URL?
        var body: [String: Any] = ["text": text]
        switch kind {
        case .webhook:
            url = URL(string: credential)
        case .botToken:
            url = URL(string: "https://slack.com/api/chat.postMessage")
            // 채널은 ID 를 그대로 쓰고, 이름이 저장돼 있으면 `#name` 으로 보낸다 —
            // Slack 은 둘 다 받는다 (이름은 봇이 그 채널에 있어야 한다).
            let channel = SlackSupport.normalizeChannel(settings.channel)
            body["channel"] = SlackSupport.looksLikeChannelId(channel) ? channel : "#" + channel
        case .unknown:
            return nil
        }
        guard let url = url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if kind == .botToken {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 결과 로그 + completion 마샬링. 토큰은 절대 로그에 남기지 않는다.
    private func finish(_ error: String?, completion: ((String?) -> Void)?) {
        if let error = error {
            log.error("slack send error: \(error, privacy: .public)")
        } else {
            log.info("slack message sent")
        }
        completion?(error)
    }
}
