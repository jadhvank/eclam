import Foundation
import OSLog

/// ADR-0037 S3 §폴백 — VPN disconnect 안전망 감시자.
///
/// 가상 디스플레이 앵커(S1)는 헤드리스 클램쉘 잠금을 막아 VPN(FortiClient)을
/// 지킨다. 그러나 미래 macOS 에서 private SPI 가 깨지거나 잠금이 한 번 새어나가면
/// VPN 이 끊기고, SAML/SSO 재인증 없이는 자동 복구가 불가능하다(ADR-0037 §대안 —
/// `scutil --nc start` 가 NEPacketTunnelProvider 에 거부되는 것을 실측). 그래서
/// 폴백은 **"끊김을 감지해 사용자에게 알린다"가 전부** — 자동 재연결은 시도하지
/// 않는다(불가능하고 깨지기 쉬움).
///
/// keep 신호가 살아있는 동안에만 `scutil --nc status <service>` 를 폴링한다(idle
/// 엔 폴링 0 — 값싸다). 진짜 Connected→Disconnected 에지에서만, 에피소드당 1회
/// (디바운스) Telegram(opt-in) + 로컬 알림을 쏜다. "한 번도 Connected 가 아니었던"
/// 상태에서의 Disconnected 는 무시한다.
///
/// **게이트(실측 버그 수정)**: master 게이트는 **`store.vpnDisconnectNotifyEnabled`**
/// 로, 잠금 가드(`clamshellLockGuardEnabled`, S1)와 **독립된 opt-in** 이다. 잠금
/// 가드를 안 켜도 VPN 끊김만 알리고 싶을 수 있어 토글을 분리했다(이전엔 잠금 가드에
/// 올라타 있어, 가드를 끈 채로는 끊김 알림이 아예 안 떴다).
///
/// **서비스명 자동 탐지(실측 버그 수정)**: 설정된 서비스명(`vpnServiceName`, 기본
/// "VPN")으로 `scutil` 이 서비스를 못 찾으면(`No service`) Connected 를 한 번도 못
/// 봐서 끊김 에지가 안 생기고 알림이 안 떴다. 그래서 못 찾을 때 `scutil --nc list`
/// 에서 FortiClient/SSL VPN 을 자동 탐지해 그 식별자로 폴링한다.
///
/// helper·`SleepDisabled` 와 무관하고 root 가 필요 없다(`scutil` 읽기만). `apply(...)`
/// 는 멱등이라 converge 마다 호출해도 안전하다(S1 `VirtualDisplayController.apply`
/// 와 같은 자리에서 호출).
final class VpnWatcher {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "vpn")
    private let store: StateStore

    /// dim/digest 타이머와 같은 메인 런루프 `Timer`. active 인 동안에만 산다
    /// (= 폴링 여부의 진실 소스). `nil` ⇒ 비활성.
    private var pollTimer: Timer?
    /// 폴 간격(초). 끊김은 분 단위가 아니라 초 단위로 알아야 의미 있지만, VPN 상태는
    /// 자주 바뀌지 않으므로 15초면 충분히 촘촘하면서 `scutil` 비용도 미미하다.
    private let pollInterval: TimeInterval = 15

    /// 직전까지 Connected 를 본 적이 있는지. disconnect 에지를 인정하려면 이 값이
    /// true 여야 한다 — "한 번도 연결된 적 없음"에서의 Disconnected 오발을 막는다.
    private var lastWasConnected = false
    /// 이번 disconnect 에피소드에서 이미 알렸는지(에피소드당 1회 디바운스). 폴마다
    /// Disconnected 가 유지돼도 재발사하지 않는다. Connected 복귀 시 리셋해 다음
    /// 끊김에 다시 알린다.
    private var notifiedThisEpisode = false

    /// 실제 존재하는 것으로 해석된 서비스명 캐시(설정명 그대로이거나 자동 탐지 결과).
    /// nil = 아직 미해석. 정상 경로에선 폴마다 `scutil` 을 한 번만 부르게 한다.
    private var resolvedService: String?
    /// `resolvedService` 를 만들 때 기준이 된 설정명. `store.vpnServiceName` 이
    /// 바뀌면(사용자가 Settings 에서 수정) 캐시를 무효화하는 트리거.
    private var resolvedForConfigured: String?
    /// "서비스를 못 찾음" 로그를 미해석 streak 당 1회만 남기게 하는 디바운스
    /// (15초마다 같은 경고를 도배하지 않도록). 해석 성공·재시작 시 리셋.
    private var unresolvedLogged = false

    init(store: StateStore) {
        self.store = store
    }

    /// converge 경로에서 매번 호출(멱등). S1 `VirtualDisplayController.apply(...)`
    /// 와 같은 자리에서 호출되지만 게이트는 **독립**이다 — VPN 끊김 알림 opt-in
    /// (`vpnDisconnectNotifyEnabled`)으로 켜고 끈다(잠금 가드와 무관).
    /// - Parameter keepAwake: 현재 keep(깨어있기) 신호 = `store.shouldKeepAwake`.
    func apply(keepAwake: Bool) {
        let wantActive = keepAwake && store.vpnDisconnectNotifyEnabled
        if wantActive {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Lifecycle

    private func start() {
        guard pollTimer == nil else { return }   // 멱등 — 이미 폴링 중이면 no-op.
        invalidateResolution()
        // 켤 때 현재 상태를 기준선으로 1회 읽는다 — 시작 직후의 첫 폴을 disconnect
        // 에지로 오인하지 않게 한다(예: 켤 때 이미 Disconnected 면 알리지 않음).
        let service = currentService()
        let baseline = Self.readStatus(service: service)
        lastWasConnected = (baseline == .connected)
        notifiedThisEpisode = false
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        log.info("vpn watcher started (configured=\(self.store.vpnServiceName, privacy: .public), resolved=\(service, privacy: .public), status=\(Self.statusName(baseline), privacy: .public))")
    }

    private func stop() {
        guard pollTimer != nil else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        // 다음 start 가 기준선을 새로 잡으므로 에피소드·해석 상태도 리셋해 둔다.
        lastWasConnected = false
        notifiedThisEpisode = false
        invalidateResolution()
        log.info("vpn watcher stopped")
    }

    // MARK: - Polling

    /// 폴에 쓸 서비스명은 `currentService()` 가 해석한다(설정명→자동탐지, 캐시).
    /// 사용자가 감시 중 설정명을 바꾸면 `currentService()` 가 캐시를 무효화해 새
    /// 이름이 반영된다.
    private func poll() {
        let service = currentService()
        let status = Self.readStatus(service: service)
        log.debug("vpn poll: service=\(service, privacy: .public) status=\(Self.statusName(status), privacy: .public)")
        switch status {
        case .connected:
            if !lastWasConnected {
                log.info("vpn: \(service, privacy: .public) is Connected (baseline armed)")
            }
            lastWasConnected = true
            notifiedThisEpisode = false   // 재연결 — 다음 끊김에 다시 알린다.
        case .disconnected, .disconnecting:
            // 진짜 Connected→Disconnected(or →Disconnecting) 에지 + 에피소드당 1회만.
            // Disconnecting 은 끊김의 선행 에지라(ADR-0037 인과표 t2) 여기서 잡고,
            // 뒤따르는 Disconnected 폴은 디바운스로 흡수한다.
            if lastWasConnected && !notifiedThisEpisode {
                log.notice("vpn: edge detected Connected→\(Self.statusName(status), privacy: .public) on \(service, privacy: .public)")
                notifiedThisEpisode = true
                notifyDropped(service: service)
            }
            lastWasConnected = false
        case .noService:
            // 폴링하던 서비스가 사라짐(이름 변경/삭제) — 캐시를 버리고 다음 폴에
            // 재해석한다. 이미 미해석 streak 면 `resolvedService` 가 nil 이라 무해.
            resolvedService = nil
        case .unknown:
            // 파싱 실패·Connecting/Invalid 등 — 상태 미상. 에지 판정에 쓰지 않는다
            // (오발 방지). lastWasConnected 를 건드리지 않아 일시적 미상 후 복귀해도
            // 직전 상태가 보존된다.
            break
        }
    }

    /// 폴에 쓸 서비스명을 해석한다. ① 설정명이 실제 존재하면 그것을, ② 없으면
    /// `scutil --nc list` 에서 FortiClient/SSL VPN 을 자동 탐지한다. 결과를 캐시해
    /// 정상 경로에선 `poll()` 의 상태 읽기 1회만 돌게 한다.
    private func currentService() -> String {
        let configured = store.vpnServiceName
        // 사용자가 Settings 에서 서비스명을 바꿨으면 캐시 무효화.
        if resolvedForConfigured != configured { invalidateResolution() }
        if let cached = resolvedService { return cached }

        resolvedForConfigured = configured
        // ① 설정명 자체가 실제 서비스인가? (No service 가 아니면 존재 — Connecting
        //    등 transient 도 "존재"로 인정.)
        if Self.readStatus(service: configured) != .noService {
            resolvedService = configured
            unresolvedLogged = false
            return configured
        }
        // ② 자동 탐지 — 설정명이 실제와 달라 못 찾는 BUG2 의 핵심 폴백.
        if let detected = Self.autodetectVpnService() {
            resolvedService = detected
            unresolvedLogged = false
            log.notice("vpn: configured service '\(configured, privacy: .public)' not found; auto-detected '\(detected, privacy: .public)' from scutil --nc list")
            return detected
        }
        // ③ 못 찾음 — 캐시하지 않고(다음 폴에 재시도) 설정명을 그대로 쓴다(폴은
        //    No service → unknown 으로 흘러 알림 없음). 로그는 streak 당 1회.
        if !unresolvedLogged {
            unresolvedLogged = true
            log.notice("vpn: configured service '\(configured, privacy: .public)' not found and no FortiClient/SSL VPN auto-detected; will keep retrying")
        }
        return configured
    }

    /// 해석 캐시 리셋(start/stop·설정명 변경 시).
    private func invalidateResolution() {
        resolvedService = nil
        resolvedForConfigured = nil
        unresolvedLogged = false
    }

    /// Connected→Disconnected 에지에서 1회 — Telegram(opt-in) + 로컬 알림 양쪽.
    /// 자동 재연결은 하지 않는다(SAML 재인증 불가 — ADR-0037 §대안). `service` 는
    /// 해석된(실제 폴링 중인) 서비스명이라 메시지가 실물 서비스를 가리킨다.
    private func notifyDropped(service svc: String) {
        log.notice("vpn: \(svc, privacy: .public) Connected→Disconnected — notifying user (no auto-reconnect; SAML re-auth required)")
        // Telegram: 마스터 opt-in 게이트만 — 설정 안 했으면 조용히 no-op.
        TelegramNotifier.shared.notifyVpnDisconnected(serviceName: svc)
        // 로컬 사용자 알림: ReleaseNotifier 의 일반 정보 경로 재사용(NotificationCenter.swift).
        // 고정 identifier 라 반복 끊김은 배너를 교체(coalesce)하지만, 디바운스로 어차피
        // 에피소드당 1회다.
        let title = NSL("notify.vpnDropped.title", "VPN disconnected")
        let body = NSLf("notify.vpnDropped.body",
            "%@ needs re-auth (SAML/SSO). Electronic Clam won't auto-reconnect — open FortiClient and sign in again.",
            svc)
        Task { await ReleaseNotifier.shared.notifyInfo(
            identifier: "eclam.vpn.disconnected", title: title, body: body) }
    }

    // MARK: - scutil parsing

    enum VpnStatus { case connected, disconnected, disconnecting, noService, unknown }

    /// 로그용 표기.
    static func statusName(_ s: VpnStatus) -> String {
        switch s {
        case .connected:     return "Connected"
        case .disconnected:  return "Disconnected"
        case .disconnecting: return "Disconnecting"
        case .noService:     return "No service"
        case .unknown:       return "unknown"
        }
    }

    /// `scutil --nc status <service>` 의 첫 줄을 파싱한다. 첫 줄에 상태 토큰이 온다
    /// (실측: `Connected` 다음 줄부터 `Extended Status <dictionary> { … }`). 서비스가
    /// 없으면 stdout 에 `No service` 한 줄(→ `.noService`, 자동탐지 트리거). `Subprocess`
    /// 가 stderr 는 버린다. service 는 표시 이름(예: "VPN")이나 식별자(UUID) 모두 허용.
    static func readStatus(service: String) -> VpnStatus {
        guard let out = Subprocess.capture("/usr/sbin/scutil", ["--nc", "status", service]) else {
            return .unknown   // launch 실패(서비스 부재와 구분 — 자동탐지 트리거 안 함).
        }
        let first = out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        switch first {
        case "Connected":     return .connected
        case "Disconnecting": return .disconnecting
        case "Disconnected":  return .disconnected
        case "No service":    return .noService   // 서비스명 불일치 → 자동탐지로.
        default:              return .unknown      // Connecting / Invalid / 빈 출력.
        }
    }

    // MARK: - 서비스 자동 탐지 (BUG2 — 서비스명 불일치 폴백)

    /// `scutil --nc list` 에서 FortiClient/SSL VPN 서비스를 찾아 그 식별자를 반환한다
    /// (있으면 표시 이름, 없으면 UUID — 둘 다 `scutil --nc status` 가 받는다). 설정된
    /// 서비스명이 실제와 달라 못 찾을 때(BUG2 핵심)의 폴백.
    ///
    /// `scutil --nc list` 한 줄 예:
    ///   `* (Disconnected)  <UUID> VPN (com.fortinet.forticlient...) "FortiSSLVPN" [...]`
    /// 매칭 점수: `forticlient`/`com.fortinet`(3) > `ipsec`/`ssl`(2) > `vpn`(1).
    /// 가장 높은 점수의 줄을 고른다. 못 찾으면 nil.
    static func autodetectVpnService() -> String? {
        guard let out = Subprocess.capture("/usr/sbin/scutil", ["--nc", "list"]) else {
            return nil
        }
        var bestIdentifier: String?
        var bestScore = 0
        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let lower = line.lowercased()
            let score: Int
            if lower.contains("forticlient") || lower.contains("com.fortinet") {
                score = 3
            } else if lower.contains("ipsec") || lower.contains("ssl") {
                score = 2
            } else if lower.contains("vpn") {
                score = 1
            } else {
                continue
            }
            guard score > bestScore else { continue }
            // 표시 이름("...")이 있으면 그것을, 없으면 UUID 를 식별자로(둘 다 status 가
            // 받는다). 이름이 사람이 읽기 좋고 알림 본문에도 그대로 쓰인다.
            let identifier = quotedName(in: line) ?? uuid(in: line)
            guard let identifier, !identifier.isEmpty else { continue }
            bestIdentifier = identifier
            bestScore = score
        }
        return bestIdentifier
    }

    /// `scutil --nc list` 의 모든 VPN 서비스 표시 이름("...")을 순서대로(중복 제거)
    /// 반환한다 — Settings 드롭다운용. `autodetectVpnService` 가 같은 파싱(`quotedName`)
    /// 으로 "최선 1개"를 고른다면, 이건 "전체 목록"이다. 따옴표 이름이 없는 줄(헤더
    /// "Available network connection services..." 등)은 건너뛴다.
    static func listVpnServices() -> [String] {
        guard let out = Subprocess.capture("/usr/sbin/scutil", ["--nc", "list"]) else {
            return []
        }
        var names: [String] = []
        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let name = quotedName(in: String(rawLine)), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// 줄에서 첫 `"..."` 안의 표시 이름을 꺼낸다(없으면 nil).
    private static func quotedName(in line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        let after = line.index(after: open)
        guard let close = line[after...].firstIndex(of: "\"") else { return nil }
        let name = String(line[after..<close])
        return name.isEmpty ? nil : name
    }

    /// 줄에서 첫 UUID(8-4-4-4-12 hex)를 꺼낸다(없으면 nil).
    private static func uuid(in line: String) -> String? {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[r])
    }
}
