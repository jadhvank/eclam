import AppKit
import OSLog
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "app")
    private let store = StateStore()
    private let history = AwakeHistoryStore()
    private var menuBar: MenuBarController?
    private var bridge: HelperBridge?
    private var settingsWindow: SettingsWindowController?
    private var detector: AgentDetector?
    private var remoteWatcher: RemoteWatcher?
    private var safetyMonitor: SafetyMonitor?
    /// ADR-0037 S1 — 헤드리스 클램쉘 잠금 방지 세션 앵커. converge 마다 keep·외장
    /// 유무에 맞춰 가상 디스플레이를 올리고/내린다(설정 opt-in).
    private var virtualDisplayController: VirtualDisplayController?
    /// ADR-0037 S3 §폴백 — VPN disconnect 안전망 감시자. S1 과 같은 opt-in 게이트로
    /// keep 동안에만 `scutil` 폴링, Connected→Disconnected 에지에서 알림(자동 재연결 X).
    private var vpnWatcher: VpnWatcher?

    /// 10s heartbeat fired while `shouldKeepAwake` is true (ADR-0004 §5).
    ///
    /// 메인 런루프 `Timer` 가 아니라 전용 큐의 `DispatchSourceTimer` 다 — 메인이
    /// 잠깐 바빠도(예: 무거운 메뉴 렌더·일시적 store 폭주) heartbeat 가 계속
    /// 나가 helper watchdog 오발(작업 중 맥 재움)을 추가로 막는 방어선. 게이트는
    /// 메인에서만 갱신되는 `heartbeatArmed` 의 원자적 미러를 읽으므로 타이머 큐
    /// 에서 락·메인 hop 없이 판정한다. `HelperBridge.heartbeat()`/
    /// `refreshCurrentState()` 는 내부에서 XPC 큐로 마샬하므로 호출 스레드 자유.
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatQueue = DispatchQueue(label: "com.jadhvank.eclam.heartbeat")
    /// `shouldKeepAwake`(= helper watchdog 무장 조건)의 원자적 미러. converge
    /// (메인)에서 매 수렴마다 갱신하고, heartbeat 타이머 큐에서 읽는다.
    private let heartbeatArmed = AtomicBool(false)

    /// Debounce window for `shouldKeepAwake` → XPC writes. ADR-0006 spec.
    private var pendingConverge: DispatchWorkItem?
    /// Most recently submitted helper value, to suppress no-op writes.
    private var lastWrittenSleepDisabled: Bool?

    /// v0.3.2 — 250ms debounce for `setActiveAgents` XPC pushes. Avoids
    /// chattering the helper when the detector and SessionWatcher fan out
    /// near-simultaneous tick events.
    private var pendingActiveAgentsPush: DispatchWorkItem?
    private var lastPushedActiveAgents: [String]?

    func applicationDidFinishLaunching(_ note: Notification) {
        // ADR-0011 §C v2 — resolve the active UI language before any NSL is read
        // (the menu is built a few lines down).
        AppLanguage.applyAtStartup()

        let bridge = HelperBridge(store: store)
        self.bridge = bridge

        // CLI↔GUI reconciliation — `eclam on/off` writes the helper directly,
        // so our no-op-write cache can go stale and silently mask a diverged
        // power state. Whenever a refresh reports a value that disagrees with
        // what we last wrote, drop the cache and reconverge: policy is
        // re-asserted and the helper watchdog re-armed instead of the Mac
        // quietly being able to sleep (or not) behind the UI's back.
        bridge.onReportedState = { [weak self] reported, holdRemaining in
            guard let self = self else { return }
            // ADR-0025 — 살아있는 CLI TTL hold 는 "정식" divergence: helper 가
            // 소유·복원하므로 재단언하지 않는다 (재수렴하면 hold 를 죽인다).
            if holdRemaining != 0 { return }
            if let last = self.lastWrittenSleepDisabled, last != reported {
                self.log.notice("helper SleepDisabled=\(reported) diverges from last written \(last) (external writer, e.g. CLI); reconverging")
                self.lastWrittenSleepDisabled = nil
                self.scheduleConverge()
            }
        }

        let menuBar = MenuBarController(
            store: store,
            bridge: bridge,
            onOpenSettings: { [weak self] in self?.openSettings(pane: .general) },
            onOpenAgentsPane: { [weak self] in self?.openSettings(pane: .agents) })
        self.menuBar = menuBar

        // ADR-0028 — Telegram 상태 푸시. History 의 에피소드 탭이 유일한
        // 이벤트 소스: 귀속(원인·사유·디테일)이 끝난 전환만 흘러온다.
        // 기본 OFF — 설정에서 opt-in 전까지 어떤 네트워크 송신도 없다.
        TelegramNotifier.shared.configure(store: store)
        history.onEpisodeStart = { TelegramNotifier.shared.episodeStarted($0) }
        history.onEpisodeEnd = { TelegramNotifier.shared.episodeEnded($0) }

        // Wire detector → store.
        let detector = AgentDetector()
        detector.onChange = { [weak self] active in
            self?.store.update(activeAgents: active)
            // v0.3.2 — propagate to the helper (debounced) so the CLI's
            // `status --json` can read the same set out of band.
            self?.schedulePushActiveAgents(active)
        }
        self.detector = detector

        // ADR-0037 S1 — own the clamshell lock-guard controller. Cheap to hold
        // (creates no display until `apply(...)` decides to); convergeNow drives it.
        self.virtualDisplayController = VirtualDisplayController(store: store)
        // ADR-0037 S3 — own the VPN disconnect safety-net watcher. Cheap to hold
        // (no polling until `apply(...)` arms it); convergeNow drives it beside S1.
        self.vpnWatcher = VpnWatcher(store: store)

        // Wire store → convergence engine (debounced XPC).
        store.onChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.menuBar?.refresh()
                self.scheduleConverge()
                // v0.3.2 — if the helper just transitioned to `.enabled`
                // (e.g. user approved the Login Item), start every long-lived
                // subsystem we previously gated on registration.
                self.startSubsystemsIfNewlyEnabled()
            }
        }

        // Register the daemon once per launch.
        let status = HelperRegistration.registerIfNeeded()
        store.update(registrationStatus: status, registrationError: nil)
        if case .enabled = store.registration {} else { sawUnapprovedThisRun = true }

        // Pull initial helper state; configure detector if enabled.
        bridge.refreshCurrentState()
        if case .enabled = store.registration {
            detector.setTraces(store.tracesToWatch())
            detector.start()
            startRemoteAndSafety()
            startHeartbeat()
            // If the helper auto-restored sleep before we reconnected, surface
            // the cause once so the user sees it in the header.
            bridge.fetchLastTripReason { [weak self] reason in
                guard let self = self, let reason = reason else { return }
                if reason == "watchdog" {
                    self.store.setSafety(release: .watchdog)
                    self.log.warning("helper reported watchdog trip; surfacing to header")
                }
                // "sigterm" 및 그 외 reason 값은 의도적으로 무시 (header 노출 불필요).
            }
        }
        menuBar.refresh()

        // ADR-0018 — first-run approval nudge, deferred to the next runloop so
        // launch finishes (and the menu bar item exists) before the modal.
        // ADR-0038 — if the bundle's install location blocked registration, the
        // relocation alert replaces the approval nudge (the two are exclusive).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.presentInstallLocationAlertIfNeeded() { self.presentApprovalOnboardingIfNeeded() }
        }

        // ADR-0035 — notify-only update check (throttled to once/24h, opt-out).
        // Deferred so launch completes first; never blocks, downloads, or installs.
        DispatchQueue.main.async { UpdateChecker.checkInBackgroundIfDue() }
    }

    /// Persisted gate so the first-run approval alert shows once per unapproved
    /// streak, not on every launch. Cleared the moment we reach `.enabled`.
    private static let onboardingPromptedKey = "OnboardingApprovalPrompted"
    /// proposal §5 — 첫 승인 축하/안내 1회 (영구). 이번 실행에서 미승인
    /// 상태를 실제로 본 경우에만 쏴서, 기존 사용자 업데이트 시 오발사를 막는다.
    private static let onboardingCelebratedKey = "OnboardingEnabledCelebrated"
    private var sawUnapprovedThisRun = false

    /// ADR-0018 — first-run nudge. macOS shows no modal prompt when a *daemon*
    /// needs approval (only a passive Notification Center banner), so we surface
    /// our own alert pointing at the Login Items pane. The menu header and the
    /// Settings permission row remain the always-on fallback if dismissed.
    private func presentApprovalOnboardingIfNeeded() {
        guard case .requiresApproval = store.registration else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.onboardingPromptedKey) else { return }
        defaults.set(true, forKey: Self.onboardingPromptedKey)

        let alert = NSAlert()
        alert.messageText = NSL("onboarding.title", "Approval needed to keep your Mac awake")
        alert.informativeText = NSL("onboarding.message",
            "Electronic Clam needs you to allow its background helper in System Settings → General → Login Items. Open it now and switch Electronic Clam on.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSL("onboarding.openSettings", "Open System Settings"))
        alert.addButton(withTitle: NSL("onboarding.later", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            HelperRegistration.openLoginItemsSettings()
        }
    }

    /// ADR-0038 — if the app is running from a quarantined/translocated location the helper
    /// can't register, so guide the user to move it instead of the normal approval nudge.
    /// Returns true if it presented (caller then suppresses the approval onboarding).
    /// No persistence — while blocked it's fine to show each launch (fatal until fixed).
    private func presentInstallLocationAlertIfNeeded() -> Bool {
        guard let block = HelperRegistration.installBlock else { return false }
        let alert = NSAlert()
        alert.messageText = NSL("installgate.title", "Move Electronic Clam to your Applications folder")
        alert.informativeText = (block.kind == .quarantined)
            ? NSL("installgate.message.quarantined", "Electronic Clam is running from a download location, so macOS won’t let its background helper start. Move it to the Applications folder and open it from there.")
            : NSL("installgate.message.translocated", "macOS is running Electronic Clam from a temporary read-only location. Move it to the Applications folder and reopen it so its helper can start.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSL("installgate.openApps", "Open Applications Folder"))
        alert.addButton(withTitle: NSL("installgate.later", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
        return true
    }

    /// ADR-0018 — reconcile registration whenever the app reactivates. Returning
    /// from approving/revoking the Login Item in System Settings reactivates us,
    /// so this catches both transitions with no timer. Idempotent: `store.update`
    /// only fires `onChange` on a real change.
    func applicationDidBecomeActive(_ note: Notification) {
        reconcileRegistration()
    }

    /// Re-read the daemon status, push it into the store, and live-refresh the
    /// Settings permission row if that window is open.
    private func reconcileRegistration() {
        store.update(registrationStatus: HelperRegistration.status(), registrationError: nil)
        settingsWindow?.refreshGeneralPane()
    }

    func applicationWillTerminate(_ note: Notification) {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        heartbeatArmed.value = false
        remoteWatcher?.stop()
        remoteWatcher = nil
        safetyMonitor?.stop()
        safetyMonitor = nil
        detector?.stop()
        detector = nil
        // ADR-0037 — drop the virtual-display anchor cleanly on quit (the OS would
        // reclaim it on process exit anyway, but unmirror/unregister explicitly).
        virtualDisplayController?.apply(keepAwake: false, externalDisplayPresent: true)
        virtualDisplayController = nil
        // ADR-0037 S3 — stop the VPN watcher's poll timer cleanly on quit.
        vpnWatcher?.apply(keepAwake: false)
        vpnWatcher = nil
        pendingConverge?.cancel()
        pendingConverge = nil
        pendingActiveAgentsPush?.cancel()
        pendingActiveAgentsPush = nil
        // ADR-0013 — close the ongoing awake episode as `appQuit` and flush to disk.
        history.noteAppQuit()
        // Synchronous restore, 200ms per attempt, ≤2 attempts (ADR-0002 §8
        // path 1; retry covers a stale/nil XPC connection at quit).
        bridge?.shutdownAndRestore(timeout: 0.2)
        log.info("applicationWillTerminate complete")
    }

    // MARK: - Remote / Safety / Heartbeat lifecycle

    private func startRemoteAndSafety() {
        if remoteWatcher == nil {
            let w = RemoteWatcher(store: store)
            remoteWatcher = w
            w.start()
        }
        if safetyMonitor == nil {
            let m = SafetyMonitor(store: store)
            safetyMonitor = m
            m.start()
        }
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        t.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10), leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Only beat while we're actively holding sleep off; otherwise the
            // watchdog is disarmed inside the helper anyway. `heartbeatArmed` is
            // converge 가 메인에서 갱신한 `shouldKeepAwake` 미러 — 타이머 큐에서
            // 락·메인 hop 없이 읽으므로 메인이 블록돼도 heartbeat 가 계속 나간다.
            guard self.heartbeatArmed.value else { return }
            self.bridge?.heartbeat()
            // CLI↔GUI reconciliation — poll the helper's actual value while we
            // believe we're holding sleep off, so an out-of-band `eclam off` is
            // detected (and policy re-asserted) within one beat instead of
            // leaving the Mac silently able to sleep. The reverse direction
            // (CLI `on` while we're idle) needs no poll: without heartbeats the
            // helper watchdog restores it anyway.
            self.bridge?.refreshCurrentState()
        }
        t.resume()
        heartbeatTimer = t
    }

    private func openSettings(pane: SettingsWindowController.Pane) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, history: history,
                                                      onRelocalize: { [weak self] in self?.relocalize() })
        }
        settingsWindow?.show(pane: pane)
    }

    /// ADR-0011 §C v3 — re-render the UI in the newly-selected language without
    /// a relaunch *or* a window rebuild. `AppLanguage.bundle` was already swapped
    /// by `setOverride`; the window controller swaps pane views in place
    /// (selected tab preserved, no close/reopen flicker — TODO P2 항목).
    private func relocalize() {
        menuBar?.refresh()
        settingsWindow?.relocalize()
    }

    // MARK: - v0.3.2 — live registration transition

    /// Idempotently brings up detector / remote / safety / heartbeat the moment
    /// the helper becomes `.enabled`. Covers the `.requiresApproval → .enabled`
    /// path that previously required an app relaunch.
    private func startSubsystemsIfNewlyEnabled() {
        guard case .enabled = store.registration else { return }
        // ADR-0018 — re-arm the first-run nudge so a later revocation prompts
        // again on the next launch. Idempotent; harmless to set each tick.
        UserDefaults.standard.set(false, forKey: Self.onboardingPromptedKey)
        if let d = detector, d.timerIsRunning {
            // Already up; nothing to do.
        } else if let d = detector {
            d.setTraces(store.tracesToWatch())
            d.start()
            log.info("registration → .enabled: AgentDetector auto-started")
        }
        if remoteWatcher == nil || safetyMonitor == nil {
            startRemoteAndSafety()
            log.info("registration → .enabled: Remote+Safety auto-started")
        }
        if heartbeatTimer == nil {
            startHeartbeat()
        }
        // proposal §5 — 미승인 → 승인 전이를 이번 실행에서 본 경우 1회(영구)
        // 다음 행동을 안내: 첫 가치 체험(에이전트 감지)까지의 거리 단축.
        if sawUnapprovedThisRun,
           !UserDefaults.standard.bool(forKey: Self.onboardingCelebratedKey) {
            UserDefaults.standard.set(true, forKey: Self.onboardingCelebratedKey)
            let title = NSL("onboarding.enabled.title", "Electronic Clam is ready")
            let body = NSL("onboarding.enabled.body",
                "Run a coding agent (Claude Code, Codex…) — the menu dot turns "
                + "green while it works, and your Mac stays awake. Click the "
                + "shell anytime to toggle.")
            Task { await ReleaseNotifier.shared.notifyInfo(
                identifier: "eclam.onboarding.enabled", title: title, body: body) }
        }
        // Refresh helper state so the menu reflects current SleepDisabled.
        bridge?.refreshCurrentState()
    }

    // MARK: - v0.3.2 — debounced activeAgents push

    private func schedulePushActiveAgents(_ active: Set<String>) {
        pendingActiveAgentsPush?.cancel()
        let snapshot = active.sorted()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.lastPushedActiveAgents == snapshot { return }
            self.lastPushedActiveAgents = snapshot
            self.bridge?.setActiveAgents(snapshot)
        }
        pendingActiveAgentsPush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    // MARK: - Convergence engine
    //
    // ADR-0006: shouldKeepAwake = manualToggle ∨ activity-rule. When it flips,
    // we hit the helper at most once per 500ms regardless of how many store
    // updates fired in that window.

    private func scheduleConverge() {
        pendingConverge?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.convergeNow() }
        pendingConverge = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func convergeNow() {
        // Only act if the helper is reachable.
        guard case .enabled = store.registration else { return }

        // Keep the watched-traces set in sync — cheap.
        detector?.setTraces(store.tracesToWatch())

        // ADR-0010/0014 — `manualOverrideOff` suppresses the *current* auto
        // signals (agent/remote) the user just clicked away. Once those have all
        // cleared it has nothing left to suppress, so clear it (per its contract,
        // StateStore.swift) and let future activity wake the Mac again.
        if store.manualOverrideOff && !store.manualToggle
            && store.activeAgents.isEmpty
            && !(store.remoteCountsAsActivity && store.remoteActive) {
            store.setManualOverrideOff(false)
        }

        let target = store.shouldKeepAwake
        // heartbeat 게이트 미러를 매 수렴마다 갱신 — helper watchdog 무장 조건
        // (keep-awake 명령 중)과 정확히 일치한다. 타이머 큐가 이 값을 읽어
        // 메인 블록 중에도 heartbeat 를 계속 보낸다.
        heartbeatArmed.value = target
        // Record the awake-since timestamp so SafetyMonitor's timer-cap policy
        // can fire. Idempotent on no-change.
        store.markKeepAwakeTransition(nowAwake: target)

        // ADR-0013 — observe awake/lid edges for the History pane. Must run
        // before the no-op early return below so that lid-only ticks (awake
        // unchanged) still accumulate clamshell time.
        history.observe(awake: target, lidClosed: store.lidClosed, store: store)

        // ADR-0037 S1 — 헤드리스 클램쉘 잠금 방지 세션 앵커. keep 신호와 실물 외장
        // 유무(SafetyMonitor 가 채운 `store.extDisplayPresent` 재사용)에 맞춰 가상
        // 디스플레이를 올리거나 내린다. 멱등이라 매 수렴마다 안전하며, 외장
        // hot-plug 처럼 `target` 이 안 바뀌는 변화도 반영하려고 아래 no-op
        // early-return 위에 둔다. helper·SleepDisabled 와 무관.
        virtualDisplayController?.apply(keepAwake: target,
                                        externalDisplayPresent: store.extDisplayPresent)

        // ADR-0037 S3 §폴백 — VPN disconnect 안전망. S1 과 같은 게이트(keep + opt-in)로
        // keep 동안에만 `scutil` 폴링을 켜고, release 되면 끈다. no-op early-return 위에
        // 둬 keep 토글뿐 아니라 opt-in 변경도 반영한다. 알림만, 자동 재연결 안 함.
        vpnWatcher?.apply(keepAwake: target)

        if let last = lastWrittenSleepDisabled, last == target { return }

        // ADR-0025 / ADR-0004 — a hardware-protection trip (thermal-critical /
        // battery-low / thermal-serious) computes target=false, but the helper
        // ignores plain off-writes while a CLI hold is active ("hold owns
        // restore"). Without cancelling the hold first the off-write is swallowed
        // and a hot/draining Mac stays awake even with the GUI running. Cancel the
        // hold ONLY for genuine hardware trips (NOT the `.timer` cap — that would
        // defeat `--forever`'s indefinite intent — and NOT a plain off, which must
        // keep the hold alive across GUI quit).
        if SafetyPolicy.shouldCancelHoldOnConverge(
            target: target,
            cliHoldActive: store.cliHoldActive,
            safetyRelease: store.safetyRelease) {
            bridge?.cancelHold()
        }

        bridge?.setSleepDisabled(target) { [weak self] err in
            if err == nil {
                self?.lastWrittenSleepDisabled = target
            } else {
                // On failure, allow the next change to retry.
                self?.lastWrittenSleepDisabled = nil
            }
        }
    }
}

/// 메인에서 쓰고 heartbeat 타이머 큐에서 읽는 한 비트의 원자적 미러. converge
/// 가 갱신하는 `shouldKeepAwake` 게이트를 락 없는 메인 hop 없이 타이머가 읽게
/// 한다 — 메인이 블록돼도 heartbeat 가 굶지 않는 핵심. NSLock 은 leaf 라 순환
/// 잠금 없음.
final class AtomicBool {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { self._value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
