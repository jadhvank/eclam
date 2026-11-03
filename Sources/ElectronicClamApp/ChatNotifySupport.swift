// ChatNotifySupport.swift — 채팅 알림의 백엔드 공통 정책 계층.
//
// Telegram(ADR-0028)과 Slack 은 목적지 API 만 다르고 "언제 보낼지"는 같다.
// 그 공통분모(이벤트 게이팅·스로틀·문안 조각 포맷)를 여기 한 곳에 두고,
// 백엔드별 파일(TelegramSupport / SlackSupport)에는 그 백엔드에만 있는 것
// (설정 타입·토큰 형식 검사·응답 파싱)만 남긴다.
//
// Foundation 만 사용 — AppKit·OSLog·URLSession 호출 금지. `scripts/test.sh`
// 가 백엔드별 순수 계층과 함께 단독 컴파일한다.

import Foundation

/// 게이팅이 읽는 설정의 최소 형태. 백엔드 설정 struct 가 채택한다.
protocol ChatNotifySettings {
    /// 보낼 수 있는 최소 조건 — 마스터 ON + 목적지 자격 정보 완비.
    var isConfigured: Bool { get }
    var notifyAwakeStart: Bool { get }
    var notifyAwakeEnd: Bool { get }
    var notifySafety: Bool { get }
    var digestIntervalMin: Int { get }
}

/// 백엔드 공통 게이팅 + 문안 조각. 순수 함수만.
enum ChatNotify {

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
    static func shouldSendDigest(settings: ChatNotifySettings,
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
    static func shouldNotifyEnd(settings: ChatNotifySettings,
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
    static func shouldNotifyStart(settings: ChatNotifySettings,
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
