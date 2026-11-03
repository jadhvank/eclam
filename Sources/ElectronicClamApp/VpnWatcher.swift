import AppKit
import Foundation
import OSLog

/// VPN observation is independent of keep-awake and the preemptive lock guard.
/// Preserve the connected baseline through keep/safety changes and real sleep;
/// observe immediately on wake. Only a confirmed disconnect edge notifies.
/// The observer prevents App Nap while awake, but owns no sleep-prevention
/// assertion. Existing helper/virtual-display protection remains independent.
final class VpnWatcher {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "vpn")
    private let store: StateStore

    struct Dependencies {
        var readStatus: (String) -> VpnStatus = VpnWatcher.readStatus
        var autodetect: () -> String? = VpnWatcher.autodetectVpnService
        var beginActivity: (ProcessInfo.ActivityOptions) -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: $0, reason: "Electronic Clam - VPN connection monitoring")
        }
        var endActivity: (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
        var schedule: (TimeInterval, @escaping () -> Void) -> (() -> Void) = { interval, callback in
            let timer = Timer(timeInterval: interval, repeats: true) { _ in callback() }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
        var observeWake: (@escaping () -> Void) -> (() -> Void) = { callback in
            let center = NSWorkspace.shared.notificationCenter
            let tokens = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map {
                center.addObserver(forName: $0, object: nil, queue: .main) { _ in callback() }
            }
            return { tokens.forEach { center.removeObserver($0) } }
        }
        var notify: ((String) -> Void)? = nil
    }

    private let dependencies: Dependencies
    private(set) var isActive = false
    private var generation = 0
    private var cancelPolling: (() -> Void)?
    private var cancelWake: (() -> Void)?
    private var observedService: String?
    private var localNotificationTask: Task<Void, Never>?
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

    private var activityToken: NSObjectProtocol?

    init(store: StateStore, dependencies: Dependencies = Dependencies()) {
        self.store = store
        self.dependencies = dependencies
    }

    deinit { stop() }

    /// Explicit opt-in, never gated by keep or lock-guard state.
    func apply(enabled: Bool) {
        if enabled {
            if isActive && resolvedForConfigured != store.vpnServiceName { poll() }
            else { start() }
        } else { stop() }
    }

    private func start() {
        guard !isActive else { return }
        isActive = true
        generation += 1
        let epoch = generation
        invalidateResolution()
        activityToken = dependencies.beginActivity(.userInitiatedAllowingIdleSystemSleep)
        let service = currentService()
        observedService = service
        lastWasConnected = dependencies.readStatus(service) == .connected
        notifiedThisEpisode = false
        let callback: () -> Void = { [weak self] in
            guard let self, self.isActive, self.generation == epoch else { return }
            self.poll()
        }
        cancelWake = dependencies.observeWake(callback)
        cancelPolling = dependencies.schedule(pollInterval, callback)
    }

    /// Explicit, idempotent shutdown even while the opt-in remains enabled.
    func stop() {
        guard isActive else { return }
        isActive = false
        generation += 1
        localNotificationTask?.cancel()
        localNotificationTask = nil
        cancelPolling?()
        cancelPolling = nil
        cancelWake?()
        cancelWake = nil
        if let token = activityToken { dependencies.endActivity(token) }
        activityToken = nil
        lastWasConnected = false
        notifiedThisEpisode = false
        observedService = nil
        invalidateResolution()
    }

    // MARK: - Polling

    /// 폴에 쓸 서비스명은 `currentService()` 가 해석한다(설정명→자동탐지, 캐시).
    /// 사용자가 감시 중 설정명을 바꾸면 `currentService()` 가 캐시를 무효화해 새
    /// 이름이 반영된다.
    private func poll() {
        guard isActive else { return }
        let configurationChanged = resolvedForConfigured != store.vpnServiceName
        let service = currentService()
        if configurationChanged || observedService != service {
            localNotificationTask?.cancel()
            localNotificationTask = nil
            lastWasConnected = false
            notifiedThisEpisode = false
            observedService = service
        }
        let status = dependencies.readStatus(service)
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
        if dependencies.readStatus(configured) != .noService {
            resolvedService = configured
            unresolvedLogged = false
            return configured
        }
        // ② 자동 탐지 — 설정명이 실제와 달라 못 찾는 BUG2 의 핵심 폴백.
        if let detected = dependencies.autodetect() {
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

    /// Connected→Disconnected 에지에서 1회 — 채팅 알림(opt-in) + 로컬 알림 양쪽.
    /// 자동 재연결은 하지 않는다(SAML 재인증 불가 — ADR-0037 §대안). `service` 는
    /// 해석된(실제 폴링 중인) 서비스명이라 메시지가 실물 서비스를 가리킨다.
    private func notifyDropped(service svc: String) {
        if let notify = dependencies.notify { notify(svc); return }
        log.notice("vpn: \(svc, privacy: .public) Connected→Disconnected — notifying user (no auto-reconnect; SAML re-auth required)")
        // Telegram·Slack: 마스터 opt-in 게이트만 — 설정 안 했으면 조용히 no-op.
        TelegramNotifier.shared.notifyVpnDisconnected(serviceName: svc)
        SlackNotifier.shared.notifyVpnDisconnected(serviceName: svc)
        // 로컬 사용자 알림: ReleaseNotifier 의 일반 정보 경로 재사용(NotificationCenter.swift).
        // 고정 identifier 라 반복 끊김은 배너를 교체(coalesce)하지만, 디바운스로 어차피
        // 에피소드당 1회다.
        let title = NSL("notify.vpnDropped.title", "VPN disconnected")
        let body = NSLf("notify.vpnDropped.body",
            "%@ needs re-auth (SAML/SSO). Electronic Clam won't auto-reconnect — open FortiClient and sign in again.",
            svc)
        let epoch = generation
        localNotificationTask?.cancel()
        localNotificationTask = Task { @MainActor [weak self] in
            guard let self, self.isActive, self.generation == epoch else { return }
            await ReleaseNotifier.shared.notifyInfo(identifier: "eclam.vpn.disconnected", title: title, body: body)
        }
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
    /// 서비스명이 실제와 달라 못 찾을 때(BUG2 핵심)의 폴백. I/O(`Subprocess.capture`)는
    /// 여기서만, 실제 파싱·점수 판정은 순수 함수 `pickVpnService(fromScutilList:)` 로
    /// 분리해 단위 테스트가 가능하게 한다(RC3).
    static func autodetectVpnService() -> String? {
        guard let out = Subprocess.capture("/usr/sbin/scutil", ["--nc", "list"]) else {
            return nil
        }
        return pickVpnService(fromScutilList: out)
    }

    /// FortiClient/SSL VPN 이 **아닌** 것으로 알려진 provider 식별자 조각들. 이들이
    /// 줄에 있으면 제외한다 — 사내 SSL VPN(FortiClient) 을 노리는데 Tailscale·
    /// WireGuard 등을 잘못 무는 것을 막는다(RC3 실측: bare "vpn" 이 Tailscale 을 물었다).
    private static let nonSslVpnProviders = [
        "tailscale", "wireguard", "zerotier", "unicorn", "t:mullvad", "mullvad",
        "nordvpn", "expressvpn", "cloudflare", "warp", "netbird", "twingate",
    ]

    /// `scutil --nc list` stdout 을 파싱해 FortiClient/SSL VPN 서비스 1개의 식별자를
    /// 고른다(순수 함수 — I/O 없음, 테스트 대상). 못 찾으면 nil.
    ///
    /// `scutil --nc list` 한 줄 예(실측):
    ///   `* (Connected)     ... VPN (io.tailscale.ipn.macos) "Tailscale" [VPN:...]`
    ///   `(Invalid)         ... VPN (com.unicorn-soft.unicornhttpsformac) "Unicorn HTTPS" [VPN:...]`
    ///   `* (Disconnected)  ... VPN (com.fortinet.forticlient.macos.vpn) "FortiSSLVPN" [VPN:...]`
    ///
    /// **RC3 — 점수 체계**: 모든 VPN 줄이 "VPN" 을 포함하므로 bare `"vpn"` = 1 tier 는
    /// 아무 줄에나 걸려 오탐한다 → **제거**. 대신 괄호 안 provider id 를 신호로 쓴다:
    ///   `forticlient`/`com.fortinet`(3) > `ipsec`/`ssl`(2). 그 외(생 "vpn" 뿐)는 후보
    /// 아님. `nonSslVpnProviders` 에 걸리는 줄은 점수와 무관하게 배제한다.
    static func pickVpnService(fromScutilList out: String) -> String? {
        var bestIdentifier: String?
        var bestScore = 0
        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let lower = line.lowercased()
            // 알려진 비-SSL-VPN provider 는 먼저 배제(Tailscale·WireGuard 등).
            if Self.nonSslVpnProviders.contains(where: { lower.contains($0) }) { continue }
            let score: Int
            if lower.contains("forticlient") || lower.contains("com.fortinet") {
                score = 3
            } else if lower.contains("ipsec") || lower.contains("ssl") {
                score = 2
            } else {
                continue   // bare "vpn" 만으론 후보로 삼지 않는다(RC3 — 오탐 방지).
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
