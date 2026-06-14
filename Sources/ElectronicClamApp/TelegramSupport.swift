// TelegramSupport.swift — Telegram 알림의 순수 데이터·결정 계층 (ADR-0028).
//
// `TelegramNotifier`(URLSession·NSL 결합)에서 설정 타입·이벤트 게이팅·파싱을
// 분리해 `scripts/test.sh` 가 AwakeEpisode.swift 와 함께 단독 컴파일할 수 있게
// 한다 (Tests/TelegramSupportTests.swift). Foundation 만 사용 — AppKit·OSLog·
// URLSession 호출 금지.

import Foundation

/// 사용자 설정. 봇 토큰을 포함하므로 디스크 직렬화 파일 전체가 0600 으로
/// 저장된다 (TelegramNotifier 쪽 책임 — ADR-0028 "토큰 저장").
struct TelegramSettings: Codable, Equatable {
    /// 마스터 토글. false ⇒ 어떤 메시지도 전송하지 않음 (기본값 — opt-in).
    var enabled: Bool
    /// @BotFather 가 발급한 봇 토큰 (`123456:ABC-…`).
    var botToken: String
    /// 숫자 chat id. 사용자가 직접 입력하거나 "Detect" 가 getUpdates 로 채움.
    var chatId: String
    /// 깨어있음 시작 알림 (에이전트 시작 등). 빈도가 높아 기본 OFF.
    var notifyAwakeStart: Bool
    /// 깨어있음 종료 알림 — 에이전트 idle 진입·원격 세션 종료. 기본 ON.
    var notifyAwakeEnd: Bool
    /// 안전 가드 자동 해제 알림 (배터리·온도·타이머·워치독). 기본 ON.
    var notifySafety: Bool
    /// 에피소드 진행 중 주기 상태 다이제스트 간격(분). 0 = off (기본).
    /// disable_notification 무음 전송 — 소리 나는 건 이벤트뿐 (알람 피로 방지).
    var digestIntervalMin: Int

    static let `default` = TelegramSettings(
        enabled: false,
        botToken: "",
        chatId: "",
        notifyAwakeStart: false,
        notifyAwakeEnd: true,
        notifySafety: true)

    /// 보낼 수 있는 최소 조건 — 마스터 ON + 토큰·chat id 모두 존재.
    var isConfigured: Bool {
        enabled && !botToken.isEmpty && !chatId.isEmpty
    }

    // 미래 키 추가에 대비한 back-compat 디코더 (SafetySettings 패턴).
    enum CodingKeys: String, CodingKey {
        case enabled, botToken, chatId, notifyAwakeStart, notifyAwakeEnd, notifySafety
        case digestIntervalMin
    }
    init(enabled: Bool, botToken: String, chatId: String,
         notifyAwakeStart: Bool, notifyAwakeEnd: Bool, notifySafety: Bool,
         digestIntervalMin: Int = 0) {
        self.enabled = enabled
        self.botToken = botToken
        self.chatId = chatId
        self.notifyAwakeStart = notifyAwakeStart
        self.notifyAwakeEnd = notifyAwakeEnd
        self.notifySafety = notifySafety
        self.digestIntervalMin = digestIntervalMin
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled          = try c.decodeIfPresent(Bool.self,   forKey: .enabled) ?? false
        self.botToken         = try c.decodeIfPresent(String.self, forKey: .botToken) ?? ""
        self.chatId           = try c.decodeIfPresent(String.self, forKey: .chatId) ?? ""
        self.notifyAwakeStart = try c.decodeIfPresent(Bool.self,   forKey: .notifyAwakeStart) ?? false
        self.notifyAwakeEnd   = try c.decodeIfPresent(Bool.self,   forKey: .notifyAwakeEnd) ?? true
        self.notifySafety     = try c.decodeIfPresent(Bool.self,   forKey: .notifySafety) ?? true
        // v0.5.x 추가 — 기존 telegram.json 에는 없음 → off.
        self.digestIntervalMin = try c.decodeIfPresent(Int.self, forKey: .digestIntervalMin) ?? 0
    }
}

/// 이벤트 게이팅 + 파싱의 순수 함수 집합.
enum TelegramSupport {

    /// 종료 알림이 분류되는 채널. 설정 체크박스와 1:1.
    enum EndChannel: Equatable {
        case safety     // notifySafety 게이트
        case awakeEnd   // notifyAwakeEnd 게이트
        case never      // 절대 전송하지 않음
    }

    /// `agentCeased` 류 종료를 알릴 최소 에피소드 길이(초). 에이전트가 몇 초
    /// 일했다 멈춘 깜빡임은 원격 알림 가치가 없다. 안전 가드 해제에는 적용하지
    /// 않는다 — 5분 cooldown 이 곧 닥치므로 항상 의미가 있다.
    static let minEndEpisodeSeconds: TimeInterval = 60

    /// 깨어있음-시작 메시지 사이 최소 간격(초). 에이전트 flapping 이 시작
    /// 알림을 도배하지 않도록 notifier 가 이 값으로 스로틀한다.
    static let minStartGapSeconds: TimeInterval = 300

    /// 주기 다이제스트 간격 선택지(분). UI 팝업과 검증이 공유.
    static let digestIntervalChoices = [15, 30, 60]

    /// 다이제스트 1회 전송 여부 — 타이머 tick 시점의 가드.
    /// 에피소드 진행 중 + 마스터/간격 설정 충족일 때만.
    static func shouldSendDigest(settings: TelegramSettings,
                                 episodeOngoing: Bool) -> Bool {
        settings.isConfigured && settings.digestIntervalMin > 0 && episodeOngoing
    }

    /// 종료 사유 → 채널 분류. exhaustive switch — `AwakeEndReason` 케이스가
    /// 늘어나면 여기서 컴파일이 깨져 분류 누락을 막는다 (asEndReason 패턴).
    static func endChannel(for reason: AwakeEndReason) -> EndChannel {
        switch reason {
        case .batteryLow, .thermalSerious, .thermalCritical, .timer, .watchdog:
            return .safety
        case .agentCeased, .remoteEnded, .remoteNetworkLost, .unknown:
            return .awakeEnd
        case .manualOff, .forceSleep:
            // 사용자가 Mac 앞에서 직접 한 행동 — 원격 알림 불필요.
            return .never
        case .appQuit:
            // applicationWillTerminate 중에는 비동기 전송 완료를 보장할 수
            // 없다. 보낼 수 없는 것을 보내는 척하지 않는다 (ADR-0028).
            return .never
        }
    }

    /// 종료 이벤트 전송 여부 결정.
    static func shouldNotifyEnd(settings: TelegramSettings,
                                reason: AwakeEndReason,
                                durationSeconds: TimeInterval) -> Bool {
        guard settings.isConfigured else { return false }
        switch endChannel(for: reason) {
        case .safety:
            return settings.notifySafety
        case .awakeEnd:
            return settings.notifyAwakeEnd && durationSeconds >= minEndEpisodeSeconds
        case .never:
            return false
        }
    }

    /// 시작 이벤트 전송 여부 결정. `lastStartAt` 은 notifier 가 들고 있는
    /// 직전 시작-알림 시각 (스로틀). manual 시작은 사용자가 Mac 앞에서 직접
    /// 한 행동이라 원격 알림 가치가 없다 (manualOff 종료와 대칭).
    static func shouldNotifyStart(settings: TelegramSettings,
                                  cause: AwakeStartCause,
                                  lastStartAt: Date?,
                                  now: Date = Date()) -> Bool {
        guard settings.isConfigured, settings.notifyAwakeStart else { return false }
        guard cause != .manual else { return false }
        if let last = lastStartAt, now.timeIntervalSince(last) < minStartGapSeconds {
            return false
        }
        return true
    }

    /// 봇 토큰 형식 대충 검사 — `<digits>:<35자 내외 base64url>`. API 호출 전
    /// 명백한 오타(공백·따옴표 포함 등)를 UI 단에서 거르는 용도일 뿐, 통과가
    /// 유효성을 보장하지는 않는다 (진짜 검증은 테스트 전송).
    static func looksLikeBotToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = t.firstIndex(of: ":") else { return false }
        let id = t[t.startIndex..<colon]
        let secret = t[t.index(after: colon)...]
        return !id.isEmpty && id.allSatisfy(\.isNumber)
            && secret.count >= 30
            && secret.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// getUpdates 응답에서 가장 최근 메시지의 chat id 를 꺼낸다 ("Detect Chat
    /// ID" 버튼). 사용자가 자기 봇에 아무 메시지나 보낸 직후 호출되는 흐름이라
    /// 마지막 update 의 message/edited_message/channel_post 만 본다.
    static func parseChatId(fromGetUpdates data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let results = root["result"] as? [[String: Any]] else { return nil }
        for update in results.reversed() {
            for key in ["message", "edited_message", "channel_post"] {
                if let msg = update[key] as? [String: Any],
                   let chat = msg["chat"] as? [String: Any],
                   let id = chat["id"] {
                    // chat.id 는 int64 (그룹은 음수) — 문자열로 정규화.
                    if let n = id as? Int64 { return String(n) }
                    if let n = id as? Int   { return String(n) }
                    if let n = id as? NSNumber { return n.stringValue }
                }
            }
        }
        return nil
    }

    /// sendMessage 응답의 성공 여부 + 실패 시 Telegram 의 description.
    static func parseSendResult(_ data: Data) -> (ok: Bool, error: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "unparseable response")
        }
        if root["ok"] as? Bool == true { return (true, nil) }
        return (false, root["description"] as? String ?? "unknown error")
    }

    /// "2h 14m" / "45m" / "<1m" — 메시지 본문용 짧은 길이 표기.
    /// (HistoryPane 의 표기와 독립 — 영문 단위 고정. 메시지는 채팅으로 가는
    /// 한 줄이라 i18n 단위보다 안정적인 축약형을 우선한다.)
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "<1m" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 메시지 꼬리에 붙는 현재 상태 한 줄. 모든 입력이 nil/빈 값이면 nil.
    /// 예: "🔋 78% ⚡️ · 🌡 62°C · 🤖 claude · 💻 MacBook Pro"
    /// host 는 멀티 Mac 사용자가 어느 기계의 알림인지 구분하는 용도.
    static func statusLine(batteryPercent: Int?,
                           charging: Bool,
                           socTempCelsius: Double?,
                           activeAgents: [String],
                           host: String? = nil) -> String? {
        var parts: [String] = []
        if let b = batteryPercent {
            parts.append(charging ? "🔋 \(b)% ⚡️" : "🔋 \(b)%")
        }
        if let t = socTempCelsius {
            parts.append(String(format: "🌡 %.0f°C", t))
        }
        if !activeAgents.isEmpty {
            parts.append("🤖 " + activeAgents.sorted().joined(separator: ", "))
        }
        if let h = host, !h.isEmpty {
            parts.append("💻 " + h)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
