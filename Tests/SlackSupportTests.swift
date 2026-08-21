/// SlackSupportTests.swift — Slack 알림 순수 계층 검증.
///
/// 1) 게이팅: 마스터·체크박스·최소 길이·시작 스로틀 (ChatNotify 위임분 포함)
/// 2) 토큰·채널 표기 검사 (looksLikeBotToken / normalizeChannel / looksLikeChannelId)
/// 3) conversations.list 채널 ID 파싱 + 페이지 커서
/// 4) chat.postMessage 결과 파싱 + error 코드 분류
///
/// 실행 (scripts/test.sh): AwakeEpisode.swift + ChatNotifySupport.swift +
/// SlackSupport.swift 와 함께 단독 컴파일 — SlackNotifier(URLSession·NSL 결합)는
/// 끌고 오지 않는다.

import Foundation

var passCount = 0
var failCount = 0

func assert(_ cond: Bool, _ msg: String) {
    if cond {
        print("  ✓ \(msg)")
        passCount += 1
    } else {
        print("  ✗ FAIL: \(msg)")
        failCount += 1
    }
}

/// 설정 팩토리 — 모두 켜진 configured 상태에서 출발해 케이스별로 끈다.
func cfg(enabled: Bool = true, token: String = "xoxb-123456789012-abcdefghijkl",
         channel: String = "C0123ABCD", start: Bool = true, end: Bool = true,
         safety: Bool = true, digest: Int = 0) -> SlackSettings {
    SlackSettings(enabled: enabled, botToken: token, channel: channel,
                  notifyAwakeStart: start, notifyAwakeEnd: end, notifySafety: safety,
                  digestIntervalMin: digest)
}

/// conversations.list 응답 한 페이지를 만든다.
func listPage(_ names: [(String, String)], cursor: String? = nil, ok: Bool = true) -> Data {
    let channels = names.map { ["id": $0.0, "name": $0.1] }
    var root: [String: Any] = ["ok": ok, "channels": channels]
    if let cursor = cursor {
        root["response_metadata"] = ["next_cursor": cursor]
    }
    return try! JSONSerialization.data(withJSONObject: root)
}

@main
enum SlackSupportTestMain {
    static func main() {
        print("── 게이팅: 종료 이벤트")
        assert(SlackSupport.shouldNotifyEnd(settings: cfg(), reason: .batteryLow,
                                            durationSeconds: 5),
               "안전 가드 해제는 길이와 무관하게 전송")
        assert(!SlackSupport.shouldNotifyEnd(settings: cfg(safety: false), reason: .batteryLow,
                                             durationSeconds: 5),
               "안전 체크박스 OFF ⇒ 미전송")
        assert(!SlackSupport.shouldNotifyEnd(settings: cfg(), reason: .agentCeased,
                                             durationSeconds: 30),
               "1분 미만 에이전트 종료는 소음 ⇒ 미전송")
        assert(SlackSupport.shouldNotifyEnd(settings: cfg(), reason: .agentCeased,
                                            durationSeconds: 120),
               "1분 이상 에이전트 종료 ⇒ 전송")
        assert(!SlackSupport.shouldNotifyEnd(settings: cfg(), reason: .manualOff,
                                             durationSeconds: 600),
               "사용자가 직접 끈 종료 ⇒ 절대 미전송")
        assert(!SlackSupport.shouldNotifyEnd(settings: cfg(enabled: false), reason: .batteryLow,
                                             durationSeconds: 600),
               "마스터 OFF ⇒ 미전송")
        assert(!SlackSupport.shouldNotifyEnd(settings: cfg(channel: ""), reason: .batteryLow,
                                             durationSeconds: 600),
               "채널 미입력 ⇒ 미전송")
        assert(SlackSupport.endChannel(for: .watchdog) == .safety, "watchdog → safety")
        assert(SlackSupport.endChannel(for: .remoteEnded) == .awakeEnd, "remoteEnded → awakeEnd")
        assert(SlackSupport.endChannel(for: .appQuit) == .never, "appQuit → never")

        print("── 게이팅: 시작 이벤트")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        assert(SlackSupport.shouldNotifyStart(settings: cfg(), cause: .agent,
                                              lastStartAt: nil, now: now),
               "첫 시작 ⇒ 전송")
        assert(!SlackSupport.shouldNotifyStart(settings: cfg(start: false), cause: .agent,
                                               lastStartAt: nil, now: now),
               "시작 체크박스 OFF ⇒ 미전송")
        assert(!SlackSupport.shouldNotifyStart(settings: cfg(), cause: .manual,
                                               lastStartAt: nil, now: now),
               "수동 시작 ⇒ 미전송")
        assert(!SlackSupport.shouldNotifyStart(settings: cfg(), cause: .agent,
                                               lastStartAt: now.addingTimeInterval(-60), now: now),
               "5분 이내 재시작 ⇒ 스로틀")
        assert(SlackSupport.shouldNotifyStart(settings: cfg(), cause: .agent,
                                              lastStartAt: now.addingTimeInterval(-600), now: now),
               "5분 지난 재시작 ⇒ 전송")

        print("── 게이팅: 다이제스트")
        assert(SlackSupport.shouldSendDigest(settings: cfg(digest: 30), episodeOngoing: true),
               "에피소드 중 + 간격 30 ⇒ 전송")
        assert(!SlackSupport.shouldSendDigest(settings: cfg(digest: 0), episodeOngoing: true),
               "간격 0(off, 기본) ⇒ 미전송")
        assert(!SlackSupport.shouldSendDigest(settings: cfg(digest: 30), episodeOngoing: false),
               "에피소드 없음(유휴) ⇒ 미전송")

        print("── 토큰 형식")
        assert(SlackSupport.looksLikeBotToken("xoxb-123456789012-abcdefghijkl"), "봇 토큰")
        assert(SlackSupport.looksLikeBotToken("  xoxb-123456789012-abcdefghijkl  "),
               "앞뒤 공백은 무시")
        assert(SlackSupport.looksLikeBotToken("xoxp-123456789012-abcdefghijkl"),
               "사용자 토큰도 허용")
        assert(!SlackSupport.looksLikeBotToken("123456:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw3"),
               "Telegram 토큰은 거부")
        assert(!SlackSupport.looksLikeBotToken("xoxb-short"), "너무 짧으면 거부")
        assert(!SlackSupport.looksLikeBotToken("xoxb-abc def ghij klm"), "공백 포함 거부")
        assert(!SlackSupport.looksLikeBotToken(""), "빈 문자열 거부")

        print("── 채널 표기")
        assert(SlackSupport.normalizeChannel("#general") == "general", "선행 # 제거")
        assert(SlackSupport.normalizeChannel("  #dev-alerts ") == "dev-alerts", "공백 + # 제거")
        assert(SlackSupport.normalizeChannel("general") == "general", "그대로")
        assert(SlackSupport.looksLikeChannelId("C0123ABCD"), "공개 채널 ID")
        assert(SlackSupport.looksLikeChannelId("#C0123ABCD"), "# 붙어도 ID 로 인식")
        assert(SlackSupport.looksLikeChannelId("G01234ABCDE"), "비공개 채널 ID")
        assert(!SlackSupport.looksLikeChannelId("general"), "이름은 ID 아님")
        assert(!SlackSupport.looksLikeChannelId("C0123abc"), "소문자 섞이면 ID 아님")
        assert(!SlackSupport.looksLikeChannelId("C012"), "너무 짧으면 ID 아님")

        print("── conversations.list 파싱")
        let page1 = listPage([("C111AAAAA", "random"), ("C222BBBBB", "general")])
        assert(SlackSupport.parseChannelId(fromConversationsList: page1, name: "general").id
               == "C222BBBBB", "이름으로 ID 찾기")
        assert(SlackSupport.parseChannelId(fromConversationsList: page1, name: "#general").id
               == "C222BBBBB", "# 붙여 넣어도 찾기")
        assert(SlackSupport.parseChannelId(fromConversationsList: page1, name: "GENERAL").id
               == "C222BBBBB", "대소문자 무시")
        let miss = SlackSupport.parseChannelId(fromConversationsList: page1, name: "nope")
        assert(miss.id == nil && miss.nextCursor == nil, "못 찾고 커서도 없으면 끝")
        let paged = listPage([("C111AAAAA", "random")], cursor: "dXNlcjpV")
        let next = SlackSupport.parseChannelId(fromConversationsList: paged, name: "general")
        assert(next.id == nil && next.nextCursor == "dXNlcjpV", "다음 페이지 커서 전달")
        let empty = listPage([("C111AAAAA", "random")], cursor: "")
        assert(SlackSupport.parseChannelId(fromConversationsList: empty, name: "general").nextCursor
               == nil, "빈 커서는 끝으로 취급")
        let failed = listPage([], ok: false)
        assert(SlackSupport.parseChannelId(fromConversationsList: failed, name: "general").id == nil,
               "ok=false 응답에서는 찾지 않음")

        print("── chat.postMessage 결과 파싱")
        let posted = try! JSONSerialization.data(withJSONObject: ["ok": true, "ts": "1.2"])
        assert(SlackSupport.parsePostResult(posted).ok, "성공 응답")
        let refused = try! JSONSerialization.data(
            withJSONObject: ["ok": false, "error": "not_in_channel"])
        let parsed = SlackSupport.parsePostResult(refused)
        assert(!parsed.ok && parsed.error == "not_in_channel", "실패 응답 + error 코드")
        assert(!SlackSupport.parsePostResult(Data("nonsense".utf8)).ok, "파싱 불가 ⇒ 실패")

        print("── error 코드 분류")
        assert(SlackSupport.classify(error: "invalid_auth") == .badToken, "invalid_auth → badToken")
        assert(SlackSupport.classify(error: "missing_scope") == .missingScope,
               "missing_scope → missingScope")
        assert(SlackSupport.classify(error: "not_in_channel") == .botNotInChannel,
               "not_in_channel → botNotInChannel")
        assert(SlackSupport.classify(error: "channel_not_found") == .botNotInChannel,
               "channel_not_found → botNotInChannel")
        assert(SlackSupport.classify(error: "ratelimited") == .rateLimited,
               "ratelimited → rateLimited")
        assert(SlackSupport.classify(error: "weird_new_code") == .other("weird_new_code"),
               "모르는 코드는 그대로 노출")

        print("── 설정 back-compat")
        let legacy = Data("""
        {"enabled":true,"botToken":"xoxb-123456789012-abcdefghijkl","channel":"C0123ABCD"}
        """.utf8)
        let decoded = try! JSONDecoder().decode(SlackSettings.self, from: legacy)
        assert(decoded.digestIntervalMin == 0, "없는 키는 off 로 디코드")
        assert(decoded.notifyAwakeEnd && decoded.notifySafety && !decoded.notifyAwakeStart,
               "체크박스 기본값 유지")
        assert(decoded.isConfigured, "토큰·채널 있으면 configured")

        print("")
        print("SlackSupport tests: \(passCount) passed, \(failCount) failed")
        if failCount > 0 { exit(1) }
    }
}
