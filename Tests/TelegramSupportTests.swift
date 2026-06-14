/// TelegramSupportTests.swift — Telegram 알림 순수 계층 검증 (ADR-0028)
///
/// 1) 종료 사유 → 채널 분류 (safety / awakeEnd / never)
/// 2) 게이팅: 마스터·체크박스·최소 길이·시작 스로틀
/// 3) getUpdates chat id 파싱 / sendMessage 결과 파싱
/// 4) duration·status line 포맷
///
/// 실행 (scripts/test.sh): SafetyPolicy.swift + AwakeEpisode.swift +
/// TelegramSupport.swift 와 함께 단독 컴파일 — TelegramNotifier(URLSession·
/// NSL 결합)는 끌고 오지 않는다.

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
func cfg(enabled: Bool = true, token: String = "12345:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
         chat: String = "777", start: Bool = true, end: Bool = true,
         safety: Bool = true, digest: Int = 0) -> TelegramSettings {
    TelegramSettings(enabled: enabled, botToken: token, chatId: chat,
                     notifyAwakeStart: start, notifyAwakeEnd: end, notifySafety: safety,
                     digestIntervalMin: digest)
}

@main
enum TelegramSupportTestMain {
    static func main() {
        print("── endChannel 분류")
        assert(TelegramSupport.endChannel(for: .batteryLow) == .safety, "batteryLow → safety")
        assert(TelegramSupport.endChannel(for: .thermalSerious) == .safety, "thermalSerious → safety")
        assert(TelegramSupport.endChannel(for: .thermalCritical) == .safety, "thermalCritical → safety")
        assert(TelegramSupport.endChannel(for: .timer) == .safety, "timer → safety")
        assert(TelegramSupport.endChannel(for: .watchdog) == .safety, "watchdog → safety")
        assert(TelegramSupport.endChannel(for: .agentCeased) == .awakeEnd, "agentCeased → awakeEnd")
        assert(TelegramSupport.endChannel(for: .remoteEnded) == .awakeEnd, "remoteEnded → awakeEnd")
        assert(TelegramSupport.endChannel(for: .remoteNetworkLost) == .awakeEnd, "remoteNetworkLost → awakeEnd")
        assert(TelegramSupport.endChannel(for: .manualOff) == .never, "manualOff → never (사용자가 Mac 앞)")
        assert(TelegramSupport.endChannel(for: .forceSleep) == .never, "forceSleep → never")
        assert(TelegramSupport.endChannel(for: .appQuit) == .never, "appQuit → never (전송 보장 불가)")

        print("── shouldNotifyEnd 게이팅")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(enabled: false), reason: .batteryLow, durationSeconds: 3600),
               "마스터 OFF ⇒ 안전 해제도 전송 안 함")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(token: ""), reason: .batteryLow, durationSeconds: 3600),
               "토큰 없음 ⇒ 전송 안 함")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(chat: ""), reason: .batteryLow, durationSeconds: 3600),
               "chat id 없음 ⇒ 전송 안 함")
        assert(TelegramSupport.shouldNotifyEnd(settings: cfg(), reason: .batteryLow, durationSeconds: 5),
               "안전 해제는 최소 길이 미적용 (5초 에피소드도 전송)")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(safety: false), reason: .batteryLow, durationSeconds: 3600),
               "notifySafety OFF ⇒ 안전 해제 미전송")
        assert(TelegramSupport.shouldNotifyEnd(settings: cfg(safety: false), reason: .agentCeased, durationSeconds: 3600),
               "notifySafety OFF 여도 agentCeased 는 awakeEnd 채널로 전송")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(), reason: .agentCeased, durationSeconds: 59),
               "agentCeased 59초 ⇒ 깜빡임 억제")
        assert(TelegramSupport.shouldNotifyEnd(settings: cfg(), reason: .agentCeased, durationSeconds: 60),
               "agentCeased 60초 ⇒ 전송")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(end: false), reason: .agentCeased, durationSeconds: 3600),
               "notifyAwakeEnd OFF ⇒ agentCeased 미전송")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(), reason: .manualOff, durationSeconds: 3600),
               "manualOff 는 어떤 설정에서도 미전송")
        assert(!TelegramSupport.shouldNotifyEnd(settings: cfg(), reason: .appQuit, durationSeconds: 3600),
               "appQuit 미전송")

        print("── shouldNotifyStart 스로틀")
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        assert(!TelegramSupport.shouldNotifyStart(settings: cfg(start: false), cause: .agent, lastStartAt: nil, now: now),
               "notifyAwakeStart OFF(기본값) ⇒ 미전송")
        assert(TelegramSupport.shouldNotifyStart(settings: cfg(), cause: .agent, lastStartAt: nil, now: now),
               "첫 시작 ⇒ 전송")
        assert(!TelegramSupport.shouldNotifyStart(settings: cfg(), cause: .manual, lastStartAt: nil, now: now),
               "manual 시작 ⇒ 미전송 (사용자가 Mac 앞)")
        assert(TelegramSupport.shouldNotifyStart(settings: cfg(), cause: .remote, lastStartAt: nil, now: now),
               "remote 시작 ⇒ 전송")
        assert(!TelegramSupport.shouldNotifyStart(settings: cfg(), cause: .agent,
               lastStartAt: now.addingTimeInterval(-100), now: now),
               "100초 전 시작 알림 있음 ⇒ 스로틀")
        assert(TelegramSupport.shouldNotifyStart(settings: cfg(), cause: .agent,
               lastStartAt: now.addingTimeInterval(-301), now: now),
               "301초 경과 ⇒ 전송")
        assert(!TelegramSupport.shouldNotifyStart(settings: cfg(enabled: false), cause: .agent, lastStartAt: nil, now: now),
               "마스터 OFF ⇒ 미전송")

        print("── looksLikeBotToken")
        assert(TelegramSupport.looksLikeBotToken("123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw3"),
               "전형적 토큰 통과")
        assert(TelegramSupport.looksLikeBotToken("  123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw3  "),
               "공백 트림 후 통과")
        assert(!TelegramSupport.looksLikeBotToken("no-colon-here"), "콜론 없음 거부")
        assert(!TelegramSupport.looksLikeBotToken("abc:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw3"),
               "bot id 가 숫자 아님 거부")
        assert(!TelegramSupport.looksLikeBotToken("123:short"), "시크릿 너무 짧음 거부")
        assert(!TelegramSupport.looksLikeBotToken("123456789:AAHdq TcvCH1vGWJxfSeofSAs0K5PALDsaw3"),
               "시크릿 내 공백 거부")

        print("── parseChatId")
        let typical = """
        {"ok":true,"result":[
          {"update_id":1,"message":{"message_id":10,"chat":{"id":111,"type":"private"},"text":"old"}},
          {"update_id":2,"message":{"message_id":11,"chat":{"id":222333444,"type":"private"},"text":"hi"}}
        ]}
        """.data(using: .utf8)!
        assert(TelegramSupport.parseChatId(fromGetUpdates: typical) == "222333444",
               "마지막 update 의 chat id 채택")
        let group = """
        {"ok":true,"result":[{"update_id":3,"message":{"chat":{"id":-100123456789,"type":"supergroup"}}}]}
        """.data(using: .utf8)!
        assert(TelegramSupport.parseChatId(fromGetUpdates: group) == "-100123456789",
               "그룹(음수 int64) id 보존")
        let edited = """
        {"ok":true,"result":[{"update_id":4,"edited_message":{"chat":{"id":555,"type":"private"}}}]}
        """.data(using: .utf8)!
        assert(TelegramSupport.parseChatId(fromGetUpdates: edited) == "555", "edited_message 도 인식")
        let empty = #"{"ok":true,"result":[]}"#.data(using: .utf8)!
        assert(TelegramSupport.parseChatId(fromGetUpdates: empty) == nil, "빈 result ⇒ nil")
        let notOk = #"{"ok":false,"description":"Unauthorized"}"#.data(using: .utf8)!
        assert(TelegramSupport.parseChatId(fromGetUpdates: notOk) == nil, "ok=false ⇒ nil")
        assert(TelegramSupport.parseChatId(fromGetUpdates: Data("garbage".utf8)) == nil, "비 JSON ⇒ nil")

        print("── parseSendResult")
        let sentOk = #"{"ok":true,"result":{"message_id":1}}"#.data(using: .utf8)!
        assert(TelegramSupport.parseSendResult(sentOk).ok, "ok=true 성공")
        let sentErr = #"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#.data(using: .utf8)!
        let r = TelegramSupport.parseSendResult(sentErr)
        assert(!r.ok && r.error == "Bad Request: chat not found", "실패 시 description 추출")
        assert(!TelegramSupport.parseSendResult(Data("x".utf8)).ok, "비 JSON ⇒ 실패")

        print("── formatDuration")
        assert(TelegramSupport.formatDuration(30) == "<1m", "30s → <1m")
        assert(TelegramSupport.formatDuration(60) == "1m", "60s → 1m")
        assert(TelegramSupport.formatDuration(3600) == "1h", "3600s → 1h")
        assert(TelegramSupport.formatDuration(2 * 3600 + 14 * 60) == "2h 14m", "8040s → 2h 14m")
        assert(TelegramSupport.formatDuration(86400) == "1d", "86400s → 1d")
        assert(TelegramSupport.formatDuration(86400 + 3 * 3600) == "1d 3h", "→ 1d 3h")
        assert(TelegramSupport.formatDuration(-5) == "<1m", "음수 방어")

        print("── statusLine")
        assert(TelegramSupport.statusLine(batteryPercent: 78, charging: false,
                                          socTempCelsius: 62.4, activeAgents: ["codex", "claude"])
               == "🔋 78% · 🌡 62°C · 🤖 claude, codex",
               "전체 조합 + 에이전트 정렬")
        assert(TelegramSupport.statusLine(batteryPercent: 95, charging: true,
                                          socTempCelsius: nil, activeAgents: [])
               == "🔋 95% ⚡️", "충전 표시 + 부분 입력")
        assert(TelegramSupport.statusLine(batteryPercent: nil, charging: false,
                                          socTempCelsius: nil, activeAgents: []) == nil,
               "전부 없음 ⇒ nil")
        assert(TelegramSupport.statusLine(batteryPercent: 50, charging: false,
                                          socTempCelsius: nil, activeAgents: [], host: "Mini")
               == "🔋 50% · 💻 Mini", "호스트명 꼬리 표기")

        print("── digest (ADR-0028 §7)")
        assert(TelegramSupport.shouldSendDigest(settings: cfg(digest: 30), episodeOngoing: true),
               "에피소드 중 + 간격 30 ⇒ 전송")
        assert(!TelegramSupport.shouldSendDigest(settings: cfg(digest: 0), episodeOngoing: true),
               "간격 0(off, 기본) ⇒ 미전송")
        assert(!TelegramSupport.shouldSendDigest(settings: cfg(digest: 30), episodeOngoing: false),
               "에피소드 없음(유휴) ⇒ 미전송")
        assert(!TelegramSupport.shouldSendDigest(settings: cfg(enabled: false, digest: 30), episodeOngoing: true),
               "마스터 OFF ⇒ 미전송")
        // back-compat: digestIntervalMin 없는 기존 telegram.json → 0 (off)
        let legacyJSON = #"{"enabled":true,"botToken":"1:x","chatId":"7","notifyAwakeStart":false,"notifyAwakeEnd":true,"notifySafety":true}"#
        let legacy = try? JSONDecoder().decode(TelegramSettings.self, from: Data(legacyJSON.utf8))
        assert(legacy?.digestIntervalMin == 0, "구버전 JSON 디코드 ⇒ digest 0 (off)")

        print("")
        print("TelegramSupport tests: \(passCount) passed, \(failCount) failed")
        exit(failCount == 0 ? 0 : 1)
    }
}
