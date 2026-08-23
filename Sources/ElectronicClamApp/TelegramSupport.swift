// TelegramSupport.swift — Telegram 알림의 순수 데이터·결정 계층 (ADR-0028).
//
// `TelegramNotifier`(URLSession·NSL 결합)에서 설정 타입·이벤트 게이팅·파싱을
// 분리해 `scripts/test.sh` 가 AwakeEpisode.swift 와 함께 단독 컴파일할 수 있게
// 한다 (Tests/TelegramSupportTests.swift). Foundation 만 사용 — AppKit·OSLog·
// URLSession 호출 금지.
//
// 백엔드 공통 게이팅(언제 보낼지)은 `ChatNotify` 로 옮겼고 Slack 과 공유한다.
// 여기 남는 것은 Telegram 에만 있는 것 — 설정 타입, 봇 토큰 형식 검사,
// Bot API 응답 파싱. 아래 wrapper 들은 기존 호출부·테스트를 그대로 두기 위한
// 얇은 위임이다.

import Foundation

/// 사용자 설정. 봇 토큰을 포함하므로 디스크 직렬화 파일 전체가 0600 으로
/// 저장된다 (TelegramNotifier 쪽 책임 — ADR-0028 "토큰 저장").
struct TelegramSettings: Codable, Equatable, ChatNotifySettings {
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

/// Telegram 전용 파싱 + 공통 게이팅 위임.
enum TelegramSupport {

    /// 종료 알림이 분류되는 채널. 설정 체크박스와 1:1 (공통 정의 재수출).
    typealias EndChannel = ChatNotify.EndChannel

    static let minEndEpisodeSeconds = ChatNotify.minEndEpisodeSeconds
    static let minStartGapSeconds = ChatNotify.minStartGapSeconds
    static let digestIntervalChoices = ChatNotify.digestIntervalChoices

    static func shouldSendDigest(settings: TelegramSettings,
                                 episodeOngoing: Bool) -> Bool {
        ChatNotify.shouldSendDigest(settings: settings, episodeOngoing: episodeOngoing)
    }

    static func endChannel(for reason: AwakeEndReason) -> EndChannel {
        ChatNotify.endChannel(for: reason)
    }

    static func shouldNotifyEnd(settings: TelegramSettings,
                                reason: AwakeEndReason,
                                durationSeconds: TimeInterval) -> Bool {
        ChatNotify.shouldNotifyEnd(settings: settings, reason: reason,
                                   durationSeconds: durationSeconds)
    }

    static func shouldNotifyStart(settings: TelegramSettings,
                                  cause: AwakeStartCause,
                                  lastStartAt: Date?,
                                  now: Date = Date()) -> Bool {
        ChatNotify.shouldNotifyStart(settings: settings, cause: cause,
                                     lastStartAt: lastStartAt, now: now)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        ChatNotify.formatDuration(seconds)
    }

    static func statusLine(batteryPercent: Int?,
                           charging: Bool,
                           socTempCelsius: Double?,
                           activeAgents: [String],
                           host: String? = nil) -> String? {
        ChatNotify.statusLine(batteryPercent: batteryPercent, charging: charging,
                              socTempCelsius: socTempCelsius,
                              activeAgents: activeAgents, host: host)
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
}
