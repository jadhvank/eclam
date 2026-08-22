// SlackSupport.swift — Slack 알림의 순수 데이터·결정 계층.
//
// Telegram 쪽 구조를 그대로 따른다 (TelegramSupport.swift 주석 참고).
// 언제 보낼지는 `ChatNotify` 가 판단하고, 여기에는 Slack 에만 있는 것만 둔다 —
// 설정 타입, 토큰·채널 표기 검사, Web API 응답 파싱.
//
// Foundation 만 사용 — AppKit·OSLog·URLSession 호출 금지.
// (Tests/SlackSupportTests.swift 가 이 파일만 단독 컴파일한다.)

import Foundation

/// 사용자 설정. 봇 토큰을 포함하므로 디스크 직렬화 파일 전체가 0600 으로
/// 저장된다 (SlackNotifier 쪽 책임 — telegram.json 과 같은 규칙).
struct SlackSettings: Codable, Equatable, ChatNotifySettings {
    /// 마스터 토글. false ⇒ 어떤 메시지도 전송하지 않음 (기본값 — opt-in).
    var enabled: Bool
    /// 목적지 자격 정보. 두 형태를 받고, 값의 생김새로 구분한다
    /// (`credentialKind` — 별도 모드 스위치를 두지 않는 이유는 두 값이 서로
    /// 헷갈릴 수 없게 생겼고, 상태가 하나 늘면 값과 어긋날 수 있어서다):
    ///   · 봇 사용자 OAuth 토큰 `xoxb-…` — scope `chat:write`, 채널 이름
    ///     조회까지 쓰려면 `channels:read`(+ 비공개 채널은 `groups:read`).
    ///   · Incoming Webhook URL `https://hooks.slack.com/services/…` — scope 도
    ///     봇 초대도 필요 없는 대신, 채널이 webhook 을 만들 때 고정된다.
    var credential: String
    /// 채널 ID (`C0123ABCD`) 또는 `#general` 같은 이름. 이름은 "Look up ID"
    /// 버튼이 conversations.list 로 ID 로 바꿔 저장한다.
    /// ★webhook 자격 정보에서는 쓰이지 않는다 — 채널이 이미 고정돼 있다.
    var channel: String
    /// 깨어있음 시작 알림 (에이전트 시작 등). 빈도가 높아 기본 OFF.
    var notifyAwakeStart: Bool
    /// 깨어있음 종료 알림 — 에이전트 idle 진입·원격 세션 종료. 기본 ON.
    var notifyAwakeEnd: Bool
    /// 안전 가드 자동 해제 알림 (배터리·온도·타이머·워치독). 기본 ON.
    var notifySafety: Bool
    /// 에피소드 진행 중 주기 상태 다이제스트 간격(분). 0 = off (기본).
    /// ★Telegram 과 다른 점: Slack Web API 에는 무음 전송 옵션이 없다.
    /// 다이제스트도 일반 메시지로 도착하므로, 조용히 받고 싶으면 채널 자체를
    /// 음소거하는 것이 사용자 쪽 해법이다 (UI 문구도 "silent" 를 빼 두었다).
    var digestIntervalMin: Int

    static let `default` = SlackSettings(
        enabled: false,
        credential: "",
        channel: "",
        notifyAwakeStart: false,
        notifyAwakeEnd: true,
        notifySafety: true)

    /// 보낼 수 있는 최소 조건 — 마스터 ON + 자격 정보. 봇 토큰은 채널까지
    /// 있어야 하고, webhook 은 채널이 URL 안에 이미 들어 있어 자격 정보만으로
    /// 충분하다.
    var isConfigured: Bool {
        enabled && isConfiguredIgnoringMaster
    }

    /// 마스터 토글을 뺀 나머지 조건. "켜기 전에 배선부터 확인"하는 테스트
    /// 전송이 이 값을 본다 (마스터 OFF 여도 테스트는 나가야 한다).
    var isConfiguredIgnoringMaster: Bool {
        guard !credential.isEmpty else { return false }
        return SlackSupport.credentialKind(credential) == .webhook || !channel.isEmpty
    }

    // 미래 키 추가에 대비한 back-compat 디코더 (TelegramSettings 패턴).
    enum CodingKeys: String, CodingKey {
        case enabled, credential, channel, notifyAwakeStart, notifyAwakeEnd, notifySafety
        case digestIntervalMin
    }
    init(enabled: Bool, credential: String, channel: String,
         notifyAwakeStart: Bool, notifyAwakeEnd: Bool, notifySafety: Bool,
         digestIntervalMin: Int = 0) {
        self.enabled = enabled
        self.credential = credential
        self.channel = channel
        self.notifyAwakeStart = notifyAwakeStart
        self.notifyAwakeEnd = notifyAwakeEnd
        self.notifySafety = notifySafety
        self.digestIntervalMin = digestIntervalMin
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled          = try c.decodeIfPresent(Bool.self,   forKey: .enabled) ?? false
        self.credential       = try c.decodeIfPresent(String.self, forKey: .credential) ?? ""
        self.channel          = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        self.notifyAwakeStart = try c.decodeIfPresent(Bool.self,   forKey: .notifyAwakeStart) ?? false
        self.notifyAwakeEnd   = try c.decodeIfPresent(Bool.self,   forKey: .notifyAwakeEnd) ?? true
        self.notifySafety     = try c.decodeIfPresent(Bool.self,   forKey: .notifySafety) ?? true
        self.digestIntervalMin = try c.decodeIfPresent(Int.self, forKey: .digestIntervalMin) ?? 0
    }
}

/// Slack 전용 검사·파싱 + 공통 게이팅 위임.
enum SlackSupport {

    typealias EndChannel = ChatNotify.EndChannel

    static let minEndEpisodeSeconds = ChatNotify.minEndEpisodeSeconds
    static let minStartGapSeconds = ChatNotify.minStartGapSeconds
    static let digestIntervalChoices = ChatNotify.digestIntervalChoices

    static func shouldSendDigest(settings: SlackSettings,
                                 episodeOngoing: Bool) -> Bool {
        ChatNotify.shouldSendDigest(settings: settings, episodeOngoing: episodeOngoing)
    }

    static func endChannel(for reason: AwakeEndReason) -> EndChannel {
        ChatNotify.endChannel(for: reason)
    }

    static func shouldNotifyEnd(settings: SlackSettings,
                                reason: AwakeEndReason,
                                durationSeconds: TimeInterval) -> Bool {
        ChatNotify.shouldNotifyEnd(settings: settings, reason: reason,
                                   durationSeconds: durationSeconds)
    }

    static func shouldNotifyStart(settings: SlackSettings,
                                  cause: AwakeStartCause,
                                  lastStartAt: Date?,
                                  now: Date = Date()) -> Bool {
        ChatNotify.shouldNotifyStart(settings: settings, cause: cause,
                                     lastStartAt: lastStartAt, now: now)
    }

    // MARK: - 자격 정보 · 채널 표기

    /// 사용자가 넣은 자격 정보의 갈래. 값의 생김새로만 정하고, 별도 모드
    /// 스위치를 두지 않는다 — 두 형태가 서로 헷갈릴 수 없게 생겼다.
    enum CredentialKind: Equatable {
        case botToken   // xoxb-… / xoxp-… → chat.postMessage + 채널 지정
        case webhook    // https://hooks.slack.com/services/… → 채널 고정
        case unknown    // 둘 다 아님 (오타)
    }

    static func credentialKind(_ value: String) -> CredentialKind {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeWebhookURL(t) { return .webhook }
        if looksLikeBotToken(t) { return .botToken }
        return .unknown
    }

    /// 토큰 형식 대충 검사 — `xoxb-…`(봇) 또는 `xoxp-…`(사용자). API 호출 전
    /// 명백한 오타를 UI 단에서 거르는 용도일 뿐, 통과가 유효성을 보장하지는
    /// 않는다 (진짜 검증은 테스트 전송).
    static func looksLikeBotToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("xoxb-") || t.hasPrefix("xoxp-") else { return false }
        let rest = t.dropFirst(5)
        return rest.count >= 10
            && rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Incoming Webhook URL 검사. 호스트를 `hooks.slack.com` 으로 못 박는다 —
    /// 자격 정보 필드에 들어온 임의의 URL 로 전송하지 않기 위해서다.
    static func looksLikeWebhookURL(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("https://hooks.slack.com/services/") else { return false }
        // 접두사 뒤에 실제 경로가 있어야 한다 (T…/B…/secret).
        return t.dropFirst("https://hooks.slack.com/services/".count).contains("/")
    }

    /// 사용자가 친 채널 표기를 정규화 — 앞뒤 공백과 선행 `#` 를 떼어낸다.
    /// `#general` · ` general ` · `general` 이 모두 `general` 이 된다.
    static func normalizeChannel(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 이미 채널 ID 인가 — `C`(공개)·`G`(비공개)·`D`(DM) 로 시작하는 대문자
    /// 영숫자. ID 면 conversations.list 조회 없이 그대로 쓸 수 있다.
    static func looksLikeChannelId(_ value: String) -> Bool {
        let t = normalizeChannel(value)
        guard t.count >= 9, let first = t.first, "CGD".contains(first) else { return false }
        return t.allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) }
    }

    // MARK: - Web API 응답 파싱

    /// conversations.list 한 페이지에서 이름이 일치하는 채널의 ID 를 찾는다.
    /// 못 찾으면 다음 페이지 커서를 함께 돌려준다 (커서가 빈 문자열이면 끝).
    /// 이름 비교는 Slack 채널명 규칙에 맞춰 소문자 기준으로 한다.
    static func parseChannelId(fromConversationsList data: Data,
                               name: String) -> (id: String?, nextCursor: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let channels = root["channels"] as? [[String: Any]] else {
            return (nil, nil)
        }
        let wanted = normalizeChannel(name).lowercased()
        for ch in channels {
            if let n = ch["name"] as? String, n.lowercased() == wanted,
               let id = ch["id"] as? String {
                return (id, nil)
            }
        }
        let cursor = (root["response_metadata"] as? [String: Any])?["next_cursor"] as? String
        return (nil, (cursor?.isEmpty ?? true) ? nil : cursor)
    }

    /// Incoming Webhook 응답 해석. Web API 와 달리 JSON 이 아니라 평문
    /// `ok` 를 주고, 실패는 HTTP 4xx + `invalid_payload` 같은 한 낱말이다.
    static func parseWebhookResult(status: Int, body: Data) -> (ok: Bool, error: String?) {
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status == 200 && text.lowercased() == "ok" { return (true, nil) }
        if text.isEmpty { return (false, "HTTP \(status)") }
        return (false, text)
    }

    /// chat.postMessage 응답의 성공 여부 + 실패 시 Slack 의 error 코드.
    /// Slack 은 실패해도 HTTP 200 을 주므로 본문을 봐야 한다.
    static func parsePostResult(_ data: Data) -> (ok: Bool, error: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "unparseable response")
        }
        if root["ok"] as? Bool == true { return (true, nil) }
        return (false, root["error"] as? String ?? "unknown error")
    }

    /// Slack 의 error 코드는 `not_in_channel` 처럼 짧아서 그대로 보여주면
    /// 사용자가 무엇을 해야 할지 알 수 없다. 자주 나오는 것만 분류해 두고,
    /// 실제 문구는 호출부(SlackNotifier)가 NSL 로 붙인다.
    enum FailureKind: Equatable {
        case badToken        // invalid_auth · not_authed · token_revoked · account_inactive
        case missingScope    // missing_scope · not_allowed_token_type
        case botNotInChannel // not_in_channel · channel_not_found · is_archived
        case rateLimited     // ratelimited
        case other(String)   // 그대로 노출
    }

    static func classify(error code: String) -> FailureKind {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "account_inactive":
            return .badToken
        case "missing_scope", "not_allowed_token_type":
            return .missingScope
        case "not_in_channel", "channel_not_found", "is_archived":
            return .botNotInChannel
        case "no_service", "no_team", "invalid_token":
            // webhook 이 삭제됐거나 URL 이 틀린 경우 — 자격 정보 문제로 묶는다.
            return .badToken
        case "ratelimited", "rate_limited":
            return .rateLimited
        default:
            return .other(code)
        }
    }
}
