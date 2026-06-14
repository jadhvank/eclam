import Foundation
import ServiceManagement

/// Observable-ish state holder. M0 has no Combine — the menu polls via `refresh()`
/// after every mutation and on `menuWillOpen`.
final class StateStore {
    enum RegistrationView: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case registerThrew(String)
        case unknown
    }

    // ADR-0006 §D — agent-awareness mode (`AgentMode`) and ADR-0004 auto-release
    // reason (`SafetyReason`) now live framework-free at top level in
    // `SafetyPolicy.swift`, so the pure policy file compiles standalone with the
    // tests. They keep the same `String` raw values and Codable conformance, so
    // persisted `UserDefaults`/JSON and external `StateStore.AgentMode` /
    // `StateStore.SafetyReason` references are behavior-identical (see the small
    // call-site requalification in this commit).

    /// Menu-bar icon appearance. `system` lets the menu bar tint a template
    /// image (auto light/dark); `light`/`dark` pin a fixed-color glyph for users
    /// whose menu bar tint doesn't match the system appearance (translucent bar
    /// over a contrasting wallpaper). Default `system`.
    enum MenuBarTheme: String, CaseIterable {
        case system, light, dark
    }

    /// ADR-0004 §1·§2·§4 — persisted safety thresholds.
    struct SafetySettings: Codable, Equatable {
        var batteryLow: Int        // % threshold; effective threshold is state-conditioned at evaluation time
        var thermalCutoff: String  // "nominal" / "fair" / "serious" — user-selected default; runtime may tighten
        var maxDurationMin: Int    // 0 = unlimited
        var enabled: Bool          // master toggle
        /// ADR-0004 "## 알림" — post a UNUserNotification on auto-release. Default ON.
        var notifyOnRelease: Bool

        static let `default` = SafetySettings(
            batteryLow: 30,
            thermalCutoff: "fair",
            maxDurationMin: 0,
            enabled: true,
            notifyOnRelease: true)

        // Back-compat decoder: pre-v0.3.1 settings JSON had no `notifyOnRelease`.
        // Default ON when missing.
        enum CodingKeys: String, CodingKey {
            case batteryLow, thermalCutoff, maxDurationMin, enabled, notifyOnRelease
        }
        init(batteryLow: Int, thermalCutoff: String, maxDurationMin: Int,
             enabled: Bool, notifyOnRelease: Bool) {
            self.batteryLow = batteryLow
            self.thermalCutoff = thermalCutoff
            self.maxDurationMin = maxDurationMin
            self.enabled = enabled
            self.notifyOnRelease = notifyOnRelease
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.batteryLow      = try c.decode(Int.self,    forKey: .batteryLow)
            self.thermalCutoff   = try c.decode(String.self, forKey: .thermalCutoff)
            self.maxDurationMin  = try c.decode(Int.self,    forKey: .maxDurationMin)
            self.enabled         = try c.decode(Bool.self,   forKey: .enabled)
            self.notifyOnRelease = try c.decodeIfPresent(Bool.self, forKey: .notifyOnRelease) ?? true
        }
    }

    /// ElectronicClam-managed user toggle for "Keep Mac Awake". The detector layer
    /// produces `activeAgents`; the union of `manualToggle ∨ (mode rule)` is what
    /// flips the helper.
    private(set) var manualToggle: Bool = false

    /// Mirror of helper's reported `SleepDisabled`. We can diverge from it
    /// briefly while a write is in flight.
    private(set) var sleepDisabled: Bool = false

    /// ADR-0025 — helper 가 보고한 CLI TTL hold 잔여 초.
    /// `-1` forever / `0` 없음 / `>0` 남은 초. hold 는 helper 가 소유·복원.
    private(set) var cliHoldRemainingSeconds: Double = 0
    var cliHoldActive: Bool { cliHoldRemainingSeconds != 0 }
    private(set) var registration: RegistrationView = .notRegistered
    private(set) var lastError: String?

    /// v0.5 P1 — 버전 핸드셰이크 결과 (`HelperBridge.performVersionHandshake`
    /// 가 연결 수립/재수립마다 1회 갱신). true ⇒ 살아있는 daemon 이 앱과
    /// 다른(대개 업그레이드 후 잔존한 구버전) 프로토콜을 말한다 —
    /// Settings→General 권한 섹션이 Reinstall Helper 안내를 노출.
    private(set) var helperVersionMismatch: Bool = false

    /// Watched agent identifiers (ADR-0005 §3). M1: a real `AgentDetector` runs
    /// over the corresponding `AgentTrace`s.
    private(set) var watchedAgents: Set<String>

    /// User-added Customize entries; merged with `AgentTrace.M1Defaults` at the
    /// detector boundary.
    private(set) var customTraces: [AgentTrace]

    /// Trace ids currently producing fresh activity (5s-poll resolution).
    /// Empty until `AgentDetector` reports its first non-empty change.
    private(set) var activeAgents: Set<String> = []

    /// ADR-0006 §D. Default Strict.
    private(set) var agentMode: AgentMode

    /// Menu-bar icon appearance (see `MenuBarTheme`). Default `.system`.
    private(set) var menuBarTheme: MenuBarTheme

    /// v0.4.0 — User explicitly forced sleep on despite active auto signals.
    /// Set by a double-left-click on the menu bar icon (ADR-0010). Suppresses
    /// every "would have kept awake" branch except `manualToggle`. Cleared as
    /// soon as the user single-clicks (which means "I changed my mind, follow
    /// the toggle again") or all auto signals naturally clear.
    private(set) var manualOverrideOff: Bool = false

    // MARK: - Remote (ADR-0008, ADR-0016)

    /// True when at least one remote-control channel is currently active.
    private(set) var remoteActive: Bool = false

    /// Per-channel labels (e.g. `["pmset:NetworkClient", "ssh", "tailscale"]`).
    private(set) var remoteChannels: Set<String> = []

    /// ADR-0017 — current SSH idle minutes while the idle knob governs an
    /// SSH-only session; `nil` for a GUI session, when off, or no remote.
    private(set) var remoteIdleMin: Int?

    /// ADR-0016 — single idle-timeout knob (minutes):
    ///   `0`   ⇒ remote never counts (channel off; subsumes the old boolean OFF).
    ///   `N>0` ⇒ remote counts, but an idle SSH session releases after N minutes.
    ///   `-1`  ⇒ never expire (ADR-0008 "stay reachable forever").
    /// Default -1 (never expire — preserves the ADR-0008 stay-reachable default).
    private(set) var remoteIdleTimeoutMin: Int

    /// Sentinel value of `remoteIdleTimeoutMin` meaning "never expire".
    static let remoteIdleNever = -1

    /// Back-compat read for the many call sites that only ask "is remote a
    /// signal at all?" — true unless the knob is `0`. (ADR-0016)
    var remoteCountsAsActivity: Bool { remoteIdleTimeoutMin != 0 }

    // MARK: - Safety (ADR-0004)

    /// Non-nil ⇒ helper has been forced into sleep-allowed by the safety layer.
    /// Overrides every other branch in `shouldKeepAwake`.
    private(set) var safetyRelease: SafetyReason?

    /// After auto-release we refuse to re-enter for 5 minutes per ADR-0004
    /// "자동 해제 후" section.
    private(set) var safetyCooldownUntil: Date?

    /// Persisted user-tunable thresholds.
    private(set) var safetySettings: SafetySettings

    // Environment snapshot (ADR-0004 §1·§2·§3) — pushed by SafetyMonitor.
    /// Debounced battery % — the value the safety *guard* reads. Held by a 30s
    /// window-MAX debounce (`SafetyMonitor.stableBatteryReading`) so a single
    /// low spike can't trip a release. Do NOT use this for the UI: a falling
    /// reading lags up to 30s. Display surfaces use `batteryPercentDisplay`.
    private(set) var batteryPercent: Int?
    /// Raw, un-debounced battery % for *display only* (menu header, Safety pane
    /// "Current state"). Updated on every read so the number tracks the OS
    /// immediately (user feedback 2026-06-12: app showed 100% while macOS
    /// already showed 99%). Never feed this into a safety decision.
    private(set) var batteryPercentDisplay: Int?
    /// Raw `kIOPSPowerSourceStateKey == ACPower`. May report `true` even when
    /// the adapter is too weak to actually charge. See `effectiveACConnected`.
    private(set) var acConnected: Bool = true
    /// v0.3.4 — `kIOPSIsChargingKey`. Combined with `acConnected` to decide
    /// whether the laptop is genuinely on AC or pretend-AC (weak adapter +
    /// heavy load). Always `true` when at 100% on AC (charge stops).
    private(set) var isCharging: Bool = false
    /// v0.3.4 — `ProcessInfo.processInfo.isLowPowerModeEnabled`. User-stated
    /// "battery matters more than performance" — policies tighten one notch.
    private(set) var lowPowerMode: Bool = false
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// ADR-0004 §2 — private 5-step thermal pressure level (0=nominal … 4=sleeping).
    /// `nil` ⇒ subscription failed or no sample yet; fall back to `thermalState`.
    private(set) var thermalPressureLevel: Int?
    private(set) var lidClosed: Bool = false
    private(set) var extDisplayPresent: Bool = false
    /// v0.4.0 — Battery temperature in °C (from `kIOPSTemperatureKey` if the
    /// power source publishes it; raw value is centi-Kelvin so the read code
    /// divides by 100 and subtracts 273.15). `nil` ⇒ no battery / not reported.
    private(set) var batteryTempCelsius: Double?
    /// v0.4.0 — Phase-2 sensor snapshot (SMC). All nil on Intel or when SMC
    /// keys aren't exposed for the current model. Sampled every 5s by the
    /// thermal poller.
    private(set) var cpuTempCelsius: Double?
    private(set) var gpuTempCelsius: Double?
    private(set) var fanRPM: Int?
    /// Rolling 60-second history (one sample per ~5s, ≤12 entries) for the
    /// Settings → Safety mini-chart. Each entry is the snapshot at sample time;
    /// SafetyMonitor pushes; the pane reads.
    private(set) var thermalHistory: [ThermalSample] = []

    public struct ThermalSample: Equatable {
        public let at: Date
        public let cpuC: Double?
        public let gpuC: Double?
        public let batteryC: Double?
        /// 4-step (0=nominal, 3=critical) for color bucketing when SMC is absent.
        public let publicLevel: Int
        public let pressureLevel: Int?
        public init(at: Date, cpuC: Double?, gpuC: Double?, batteryC: Double?,
                    publicLevel: Int, pressureLevel: Int?) {
            self.at = at; self.cpuC = cpuC; self.gpuC = gpuC; self.batteryC = batteryC
            self.publicLevel = publicLevel; self.pressureLevel = pressureLevel
        }
    }

    /// v0.3.4 — "effective AC" treats a weak adapter as battery. AC is real
    /// only when the source claims AC AND (we're actively charging OR battery
    /// is already at ≥95%, which is when charging stops normally).
    var effectiveACConnected: Bool {
        guard acConnected else { return false }
        if isCharging { return true }
        if let p = batteryPercent, p >= 95 { return true }
        return false
    }

    /// Date `shouldKeepAwake` first became true in the current run; used by the
    /// timer-cap policy. Reset to nil when it becomes false.
    private(set) var keepAwakeSince: Date?

    private static let watchedAgentsKey         = "WatchedAgents"
    private static let customTracesKey          = "CustomAgentTraces"
    private static let agentModeKey             = "AgentMode"
    private static let menuBarThemeKey          = "MenuBarTheme"
    private static let remoteIdleTimeoutKey     = "RemoteIdleTimeoutMin"
    private static let remoteCountsLegacyKey    = "RemoteCountsAsActivity"  // pre-ADR-0016
    private static let safetySettingsKey        = "SafetySettings"
    /// v0.5 ADR-0006 §B — the documented "Default (5)" detection set. This was
    /// left at `["claude"]` when the v0.5 agent trim landed, so codex / cursor /
    /// opencode were never watched unless the user opened Settings → Agents.
    private static let defaultWatchedAgents: Set<String> = Set(AgentTrace.M1Defaults.map(\.id))
    /// One-shot marker for the `["claude"]`-stored-default migration below.
    private static let watchedAgentsMigratedKey = "WatchedAgentsDefaultV2Migrated"

    var onChange: (() -> Void)?

    init() {
        if let stored = UserDefaults.standard.array(forKey: Self.watchedAgentsKey) as? [String] {
            var set = Set(stored)
            // Migration: installs that persisted the old single-agent default
            // (exactly `["claude"]`, the only way to get that set without a
            // deliberate choice was the stale default) are upgraded once to the
            // documented 5-agent default. The marker makes a later deliberate
            // claude-only choice stick.
            if set == ["claude"],
               !UserDefaults.standard.bool(forKey: Self.watchedAgentsMigratedKey) {
                set = Self.defaultWatchedAgents
                UserDefaults.standard.set(Array(set).sorted(), forKey: Self.watchedAgentsKey)
            }
            self.watchedAgents = set
        } else {
            self.watchedAgents = Self.defaultWatchedAgents
        }
        UserDefaults.standard.set(true, forKey: Self.watchedAgentsMigratedKey)

        if let data = UserDefaults.standard.data(forKey: Self.customTracesKey),
           let decoded = try? JSONDecoder().decode([AgentTrace].self, from: data) {
            self.customTraces = decoded
        } else {
            self.customTraces = []
        }

        if let raw = UserDefaults.standard.string(forKey: Self.agentModeKey),
           let parsed = AgentMode(rawValue: raw) {
            self.agentMode = parsed
        } else {
            self.agentMode = .strict
        }

        if let raw = UserDefaults.standard.string(forKey: Self.menuBarThemeKey),
           let parsed = MenuBarTheme(rawValue: raw) {
            self.menuBarTheme = parsed
        } else {
            self.menuBarTheme = .system
        }

        // ADR-0016 — single idle-timeout knob. Default is "never expire", which
        // preserves the ADR-0008 stay-reachable behaviour and never surprises a
        // returning user by sleeping mid-session. One-time migration from the
        // pre-0016 boolean: false → 0 (off), true/unset → -1 (never expire).
        if UserDefaults.standard.object(forKey: Self.remoteIdleTimeoutKey) != nil {
            self.remoteIdleTimeoutMin = UserDefaults.standard.integer(forKey: Self.remoteIdleTimeoutKey)
        } else if let legacy = UserDefaults.standard.object(forKey: Self.remoteCountsLegacyKey) as? Bool {
            self.remoteIdleTimeoutMin = legacy ? Self.remoteIdleNever : 0
        } else {
            self.remoteIdleTimeoutMin = Self.remoteIdleNever
        }

        if let data = UserDefaults.standard.data(forKey: Self.safetySettingsKey),
           let decoded = try? JSONDecoder().decode(SafetySettings.self, from: data) {
            self.safetySettings = decoded
        } else {
            self.safetySettings = .default
        }
    }

    /// Snapshot of trace pool — defaults + external declarations + user-added —
    /// keyed by id. 충돌 시 우선순위: custom > traces.d(외부 선언이 기본 glob 을
    /// 덮어쓸 수 있게) > defaults. proposal §1 / `traces/README.md`.
    func allKnownTraces() -> [AgentTrace] {
        var byId: [String: AgentTrace] = [:]
        for t in AgentTrace.M1Defaults { byId[t.id] = t }
        for t in ExternalTraces.load()  { byId[t.id] = t }
        for t in customTraces           { byId[t.id] = t }
        return Array(byId.values)
    }

    /// Subset of `allKnownTraces()` filtered by `watchedAgents` — exactly what
    /// `AgentDetector.setTraces` should receive.
    func tracesToWatch() -> [AgentTrace] {
        allKnownTraces().filter { watchedAgents.contains($0.id) }
    }

    /// Computed desired daemon state. Order matters — safety overrides win.
    ///   1. `safetyRelease != nil` ⇒ false (auto-released)
    ///   2. inside cooldown      ⇒ false
    ///   3. manualToggle         ⇒ true
    ///   4. remote (if enabled)  ⇒ true
    ///   5. Strict: any watched agent active ⇒ true
    ///   6. Lax: (TODO M2) currently same as Strict
    var shouldKeepAwake: Bool {
        // Behaviour is defined by the pure `decideKeepAwake` (SafetyPolicy.swift);
        // this builds the value-type snapshot from live state and delegates.
        let cooldownActive = safetyCooldownUntil.map { $0 > Date() } ?? false

        // Preserve today's short-circuit: the only branch that runs the `ps`
        // scan (`LaxProcessAlive.anyAlive`) is Lax + no fresh activity, and only
        // when every earlier branch falls through. Compute `laxProcessAlive`
        // lazily so `ps` isn't run unless that exact branch is reachable.
        let laxBranchReachable = safetyRelease == nil
            && !cooldownActive
            && !manualToggle
            && !manualOverrideOff
            && !(remoteCountsAsActivity && remoteActive)
            && agentMode == .lax
            && activeAgents.isEmpty
        let laxProcessAlive = laxBranchReachable
            ? LaxProcessAlive.anyAlive(traces: tracesToWatch())
            : false

        return decideKeepAwake(AwakeInputs(
            safetyReleaseActive: safetyRelease != nil,
            cooldownActive: cooldownActive,
            manualToggle: manualToggle,
            manualOverrideOff: manualOverrideOff,
            remoteCountsAsActivity: remoteCountsAsActivity,
            remoteActive: remoteActive,
            agentMode: agentMode,
            activeAgentsNonEmpty: !activeAgents.isEmpty,
            laxProcessAlive: laxProcessAlive))
    }

    // MARK: - Mutations

    func setManualToggle(_ on: Bool) {
        guard manualToggle != on else { return }
        manualToggle = on
        onChange?()
    }

    /// v0.4.0 — double-left-click handler. Forces sleep even when auto signals
    /// (agent activity, remote session) would otherwise keep us awake.
    func setManualOverrideOff(_ on: Bool) {
        guard manualOverrideOff != on else { return }
        manualOverrideOff = on
        // Setting override-off implicitly turns the manual toggle off too;
        // they are semantically incompatible.
        if on { manualToggle = false }
        onChange?()
    }

    func update(activeAgents: Set<String>) {
        guard self.activeAgents != activeAgents else { return }
        self.activeAgents = activeAgents
        onChange?()
    }

    func update(agentMode: AgentMode) {
        guard self.agentMode != agentMode else { return }
        self.agentMode = agentMode
        UserDefaults.standard.set(agentMode.rawValue, forKey: Self.agentModeKey)
        onChange?()
    }

    func setMenuBarTheme(_ theme: MenuBarTheme) {
        guard self.menuBarTheme != theme else { return }
        self.menuBarTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.menuBarThemeKey)
        // onChange → AppDelegate → menuBar.refresh() re-renders the glyph.
        onChange?()
    }

    func addCustomTrace(_ trace: AgentTrace) {
        customTraces.removeAll { $0.id == trace.id }
        customTraces.append(trace)
        persistCustomTraces()
        // Auto-enable the new entry.
        watchedAgents.insert(trace.id)
        persistWatched()
        onChange?()
    }

    func removeCustomTrace(id: String) {
        customTraces.removeAll { $0.id == id }
        persistCustomTraces()
        watchedAgents.remove(id)
        persistWatched()
        onChange?()
    }

    private func persistCustomTraces() {
        if let data = try? JSONEncoder().encode(customTraces) {
            UserDefaults.standard.set(data, forKey: Self.customTracesKey)
        }
    }

    private func persistWatched() {
        UserDefaults.standard.set(Array(watchedAgents), forKey: Self.watchedAgentsKey)
    }

    func update(sleepDisabled: Bool) {
        guard self.sleepDisabled != sleepDisabled else { return }
        self.sleepDisabled = sleepDisabled
        onChange?()
    }

    /// v0.5 P1 — 버전 핸드셰이크 결과 반영. 변화 없으면 no-op (일치 시 기존
    /// 동작 비용 0 — onChange 재수렴조차 일으키지 않는다).
    func update(helperVersionMismatch: Bool) {
        guard self.helperVersionMismatch != helperVersionMismatch else { return }
        self.helperVersionMismatch = helperVersionMismatch
        onChange?()
    }

    /// ADR-0025 — CLI TTL hold 잔여 (-1 forever / 0 none / >0 sec).
    /// onChange 는 "활성 여부 또는 분 단위 버킷"이 바뀔 때만 — 10s 폴링마다
    /// 메뉴를 다시 그리지 않기 위한 양자화.
    func update(cliHoldRemaining: Double) {
        let bucket: (Double) -> Int = { $0 < 0 ? -1 : Int($0 / 60) }
        let changed = bucket(cliHoldRemainingSeconds) != bucket(cliHoldRemaining)
            || (cliHoldRemainingSeconds == 0) != (cliHoldRemaining == 0)
        cliHoldRemainingSeconds = cliHoldRemaining
        if changed { onChange?() }
    }

    func update(registrationStatus: SMAppService.Status, registrationError: Error?) {
        let resolved: RegistrationView
        if let err = registrationError {
            resolved = .registerThrew(err.localizedDescription)
        } else {
            switch registrationStatus {
            case .enabled:          resolved = .enabled
            case .requiresApproval: resolved = .requiresApproval
            case .notRegistered:    resolved = .notRegistered
            case .notFound:         resolved = .notFound
            @unknown default:       resolved = .unknown
            }
        }
        // ADR-0018 — re-polling now happens on every activation / menu open, so
        // only fire `onChange` (→ convergence + subsystem start) on a real
        // transition. Mirrors the `update(sleepDisabled:)` change guard above.
        guard resolved != registration else { return }
        registration = resolved
        onChange?()
    }

    func update(lastError: String?) {
        self.lastError = lastError
        onChange?()
    }

    func toggleAgent(_ id: String) {
        if watchedAgents.contains(id) {
            watchedAgents.remove(id)
        } else {
            watchedAgents.insert(id)
        }
        persistWatched()
        onChange?()
    }

    func isAgentWatched(_ id: String) -> Bool {
        watchedAgents.contains(id)
    }

    // MARK: - Remote (ADR-0008) setters

    /// Thread-safe entry point for `RemoteWatcher`. Marshalled to main so that
    /// `onChange` always fires on the menu thread.
    func setRemote(active: Bool, channels: Set<String>, idleMin: Int? = nil) {
        let work = {
            let changed = (self.remoteActive != active)
                || (self.remoteChannels != channels)
                || (self.remoteIdleMin != idleMin)
            guard changed else { return }
            self.remoteActive = active
            self.remoteChannels = channels
            self.remoteIdleMin = idleMin
            self.onChange?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// ADR-0016 — set the idle-timeout knob (minutes; 0 = off, -1 = never expire).
    func setRemoteIdleTimeoutMin(_ minutes: Int) {
        guard self.remoteIdleTimeoutMin != minutes else { return }
        self.remoteIdleTimeoutMin = minutes
        UserDefaults.standard.set(minutes, forKey: Self.remoteIdleTimeoutKey)
        onChange?()
    }

    // MARK: - Safety (ADR-0004) setters

    /// Thread-safe entry point for `SafetyMonitor`. `reason == nil` clears
    /// `safetyRelease` but DOES NOT clear `safetyCooldownUntil` — the 5-minute
    /// cooldown is intentionally sticky to prevent flapping. ADR-0004.
    func setSafety(release reason: SafetyReason?) {
        let work = {
            let changed = (self.safetyRelease != reason)
            if reason != nil {
                // Start (or refresh) the 5-min cooldown on every set-to-non-nil.
                self.safetyCooldownUntil = Date().addingTimeInterval(5 * 60)
            }
            if changed {
                self.safetyRelease = reason
                self.onChange?()
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Allow the SafetyMonitor to advance the cooldown clock without changing
    /// `safetyRelease` (e.g. on watchdog auto-clear). Internal helper.
    func clearSafetyCooldownIfElapsed() {
        if let until = safetyCooldownUntil, until <= Date() {
            safetyCooldownUntil = nil
            onChange?()
        }
    }

    func setEnvironment(battery: Int?,
                        batteryDisplay: Int? = nil,
                        acConnected: Bool,
                        isCharging: Bool,
                        lowPowerMode: Bool,
                        thermal: ProcessInfo.ThermalState,
                        lidClosed: Bool,
                        extDisplay: Bool,
                        batteryTempCelsius: Double? = nil,
                        cpuTempCelsius: Double? = nil,
                        gpuTempCelsius: Double? = nil,
                        fanRPM: Int? = nil) {
        // When the caller doesn't pass a raw display value, fall back to the
        // (possibly debounced) `battery` so display never goes blank.
        let display = batteryDisplay ?? battery
        let work = {
            let changed = self.batteryPercent != battery
                || self.batteryPercentDisplay != display
                || self.acConnected != acConnected
                || self.isCharging != isCharging
                || self.lowPowerMode != lowPowerMode
                || self.thermalState != thermal
                || self.lidClosed != lidClosed
                || self.extDisplayPresent != extDisplay
                || self.batteryTempCelsius != batteryTempCelsius
                || self.cpuTempCelsius != cpuTempCelsius
                || self.gpuTempCelsius != gpuTempCelsius
                || self.fanRPM != fanRPM
            guard changed else { return }
            self.batteryPercent = battery
            self.batteryPercentDisplay = display
            self.acConnected = acConnected
            self.isCharging = isCharging
            self.lowPowerMode = lowPowerMode
            self.thermalState = thermal
            self.lidClosed = lidClosed
            self.extDisplayPresent = extDisplay
            self.batteryTempCelsius = batteryTempCelsius
            self.cpuTempCelsius = cpuTempCelsius
            self.gpuTempCelsius = gpuTempCelsius
            self.fanRPM = fanRPM
            self.onChange?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// v0.4.0 — append one sample to the rolling thermal history. Caller is
    /// expected to throttle (~5s). Trims to the most recent 60 seconds.
    func pushThermalSample(_ sample: ThermalSample) {
        let work = {
            self.thermalHistory.append(sample)
            let cutoff = sample.at.addingTimeInterval(-60)
            self.thermalHistory.removeAll { $0.at < cutoff }
            self.onChange?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Thread-safe entry point for SafetyMonitor's 5-step layered observer.
    /// Pass `nil` to indicate the private notify subscription failed.
    func setThermalPressureLevel(_ level: Int?) {
        let work = {
            guard self.thermalPressureLevel != level else { return }
            self.thermalPressureLevel = level
            self.onChange?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func updateSafetySettings(_ next: SafetySettings) {
        guard self.safetySettings != next else { return }
        self.safetySettings = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.safetySettingsKey)
        }
        onChange?()
    }

    /// Records the moment `shouldKeepAwake` last transitioned `false → true`,
    /// for the timer-cap policy. AppDelegate's convergence engine calls this
    /// right before writing to the helper.
    func markKeepAwakeTransition(nowAwake: Bool) {
        if nowAwake {
            if keepAwakeSince == nil { keepAwakeSince = Date() }
        } else {
            keepAwakeSince = nil
        }
    }
}
