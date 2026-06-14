// SafetyPolicy.swift — framework-free pure decision logic (ADR-0004 / ADR-0006 /
// ADR-0014). Imports ONLY Swift's standard library: no AppKit, no IOKit, no
// Foundation. This lets `scripts/test.sh` compile it together with the test
// program via swiftc without dragging in the GUI/system frameworks.
//
// The two decisions that decide whether the Mac stays awake — and whether the
// safety layer forces it back to sleep — live here as pure functions over plain
// value-type snapshots. The framework-coupled layers (`StateStore`,
// `SafetyMonitor`) build a snapshot from live state and delegate to these. All
// time reads (`Date()`), process probes (`LaxProcessAlive`/`ps`), IOKit reads,
// and store mutation stay in the callers; nothing impure leaks in here.

// MARK: - Shared pure value types
//
// These enums used to be nested inside `StateStore`, which imports
// ServiceManagement. They are plain `String`-raw enums with no framework
// dependency, so they move here to keep the policy file standalone-compilable.
// `StateStore` re-exposes them via `typealias` so every existing
// `StateStore.SafetyReason` / `StateStore.AgentMode` call site is unchanged.

/// ADR-0006 §D — agent-awareness mode.
public enum AgentMode: String {
    case strict  // default; only "activity within freshness" counts
    case lax     // process alive is enough
}

/// ADR-0004 — auto-release reason. `nil` ⇒ no safety override active.
public enum SafetyReason: String, Codable {
    case batteryLow      // "🔋 18%"
    case thermalSerious  // "🌡 .serious + lid"
    case thermalCritical // "🌡 .critical"
    case timer           // "⏱ 60m"
    case watchdog        // "helper timeout"
}

// MARK: - Awake decision (StateStore.shouldKeepAwake)

/// Plain value-type snapshot of everything `StateStore.shouldKeepAwake` reads.
/// Built by `StateStore` from live state; consumed by `decideKeepAwake`.
///
/// `cooldownActive` and `laxProcessAlive` are pre-computed by the caller so this
/// struct (and the decision over it) stays free of `Date()` / `ps` side effects.
/// The caller preserves today's short-circuit: it only computes `laxProcessAlive`
/// (which runs `ps`) when the lax branch can actually be reached.
public struct AwakeInputs {
    /// True when `safetyRelease != nil` (the safety layer has auto-released).
    public let safetyReleaseActive: Bool
    /// True when inside the 5-minute post-release cooldown
    /// (`safetyCooldownUntil > now`).
    public let cooldownActive: Bool
    /// ElectronicClam-managed user "Keep Mac Awake" toggle.
    public let manualToggle: Bool
    /// v0.4.0 — user force-slept despite live auto signals (ADR-0014).
    public let manualOverrideOff: Bool
    /// ADR-0016 — remote counts as activity unless the idle knob is 0.
    public let remoteCountsAsActivity: Bool
    /// At least one remote-control channel is currently active.
    public let remoteActive: Bool
    /// Strict vs Lax (ADR-0006 §D).
    public let agentMode: AgentMode
    /// True when at least one watched agent is reporting fresh activity.
    public let activeAgentsNonEmpty: Bool
    /// Lax-branch only: is any watched agent's process alive? Caller passes the
    /// `LaxProcessAlive.anyAlive(...)` result; in Strict mode (or when an earlier
    /// branch wins) this is never read, so the caller may pass `false`.
    public let laxProcessAlive: Bool

    public init(safetyReleaseActive: Bool,
                cooldownActive: Bool,
                manualToggle: Bool,
                manualOverrideOff: Bool,
                remoteCountsAsActivity: Bool,
                remoteActive: Bool,
                agentMode: AgentMode,
                activeAgentsNonEmpty: Bool,
                laxProcessAlive: Bool) {
        self.safetyReleaseActive = safetyReleaseActive
        self.cooldownActive = cooldownActive
        self.manualToggle = manualToggle
        self.manualOverrideOff = manualOverrideOff
        self.remoteCountsAsActivity = remoteCountsAsActivity
        self.remoteActive = remoteActive
        self.agentMode = agentMode
        self.activeAgentsNonEmpty = activeAgentsNonEmpty
        self.laxProcessAlive = laxProcessAlive
    }
}

/// Pure form of `StateStore.shouldKeepAwake`. Order matters — safety overrides
/// win (ADR-0004 §priority, ADR-0014 §click model):
///   1. safetyRelease active  ⇒ false (auto-released)
///   2. inside cooldown       ⇒ false
///   3. manualToggle          ⇒ true
///   4. manualOverrideOff     ⇒ false (user force-slept; suppress auto signals)
///   5. remote (if enabled)   ⇒ true
///   6. Strict: any watched agent active ⇒ true
///      Lax:   active OR a watched process alive ⇒ true
public func decideKeepAwake(_ inputs: AwakeInputs) -> Bool {
    if inputs.safetyReleaseActive { return false }
    if inputs.cooldownActive { return false }
    if inputs.manualToggle { return true }
    // Auto signals only matter when the user hasn't double-clicked to force off.
    if inputs.manualOverrideOff { return false }
    if inputs.remoteCountsAsActivity && inputs.remoteActive { return true }
    switch inputs.agentMode {
    case .strict:
        return inputs.activeAgentsNonEmpty
    case .lax:
        if inputs.activeAgentsNonEmpty { return true }
        return inputs.laxProcessAlive
    }
}

// MARK: - Safety auto-release decision (SafetyMonitor.evaluateCore)

/// Plain value-type snapshot for the ADR-0004 auto-release decision. The caller
/// (`SafetyMonitor`) does all the framework-coupled work first — IOKit reads,
/// `effectiveACConnected`, thermal level mapping, the state-conditioned battery
/// threshold (`batteryThresholdWithLowPower`), the Low-Power-Mode-tightened
/// thermal cutoff (`effectiveThermalCutoffWithLowPower`), and the timer-cap
/// elapsed minutes — then hands the resolved scalars in here.
///
/// Thermal is expressed as integer levels (public 4-step: 0=nominal … 3=critical;
/// 5-step pressure: 0…4, `nil` when the private channel is unavailable) so the
/// struct never references `ProcessInfo.ThermalState`.
public struct SafetyEnvironment {
    /// Master toggle (`SafetySettings.enabled`). Critical thermal trips even when
    /// this is false; everything else is gated on it.
    public let masterEnabled: Bool

    // Thermal.
    /// Public 4-step thermal level: 0=nominal, 1=fair, 2=serious, 3=critical.
    public let thermalLevel: Int
    /// State-conditioned + Low-Power-tightened serious cutoff, as an int level.
    public let thermalCutoffLevel: Int
    /// Private 5-step pressure level (0…4), or `nil` if unavailable.
    public let thermalPressureLevel: Int?

    // Battery.
    /// True when genuinely on AC (`StateStore.effectiveACConnected`). When true
    /// the battery release is suppressed.
    public let effectiveACConnected: Bool
    /// Current battery %, or `nil` if no reading.
    public let batteryPercent: Int?
    /// Resolved battery threshold (state-conditioned, Low-Power-adjusted).
    public let batteryThreshold: Int

    // Timer cap.
    /// `SafetySettings.maxDurationMin` (0 = unlimited).
    public let maxDurationMin: Int
    /// v0.3.4 E — AC + lid open + ext display ⇒ "at a desk", timer cap skipped.
    public let safeScenario: Bool
    /// Minutes since `keepAwakeSince`, or `nil` if not currently keeping awake.
    public let keepAwakeElapsedMinutes: Double?

    public init(masterEnabled: Bool,
                thermalLevel: Int,
                thermalCutoffLevel: Int,
                thermalPressureLevel: Int?,
                effectiveACConnected: Bool,
                batteryPercent: Int?,
                batteryThreshold: Int,
                maxDurationMin: Int,
                safeScenario: Bool,
                keepAwakeElapsedMinutes: Double?) {
        self.masterEnabled = masterEnabled
        self.thermalLevel = thermalLevel
        self.thermalCutoffLevel = thermalCutoffLevel
        self.thermalPressureLevel = thermalPressureLevel
        self.effectiveACConnected = effectiveACConnected
        self.batteryPercent = batteryPercent
        self.batteryThreshold = batteryThreshold
        self.maxDurationMin = maxDurationMin
        self.safeScenario = safeScenario
        self.keepAwakeElapsedMinutes = keepAwakeElapsedMinutes
    }
}

/// ADR-0004 auto-release policy. Pure mirror of `SafetyMonitor.evaluateCore`'s
/// decision (steps 1–5), returning the `SafetyReason` the environment trips, or
/// `nil` when no environment condition trips.
///
/// Ordering and semantics match the live code exactly:
///   1. Critical thermal (public `.critical` OR 5-step ≥ sleeping=4) — trips
///      `.thermalCritical` regardless of the master toggle or cooldown.
///   2. Master toggle off ⇒ no further release (returns `nil`).
///   3. Battery: on (effective) battery AND battery% ≤ threshold ⇒ `.batteryLow`.
///   4. Thermal serious: public level ≥ cutoff OR 5-step ≥ trapping=3
///      ⇒ `.thermalSerious`.
///   5. Timer cap: maxDuration set AND not in the safe desk scenario AND
///      currently keeping awake for ≥ maxDuration minutes ⇒ `.timer`.
///   6. Otherwise `nil`.
///
/// NOTE: the live `evaluateCore` step 6 also handles the `.watchdog` channel and
/// the sticky-cooldown clearing — both are time/store-mutation side effects, not
/// an environment decision, so they remain in `SafetyMonitor` and are not part
/// of this pure function. `enum SafetyPolicy` is a namespace only.
public enum SafetyPolicy {
    public static func evaluate(_ env: SafetyEnvironment) -> SafetyReason? {
        // 1) Critical thermal — always trips, regardless of toggle/cooldown.
        let pressure = env.thermalPressureLevel
        if env.thermalLevel >= 3 || (pressure ?? -1) >= 4 {
            return .thermalCritical
        }

        // 2) Master toggle off ⇒ expose `.critical` above but skip the rest.
        guard env.masterEnabled else { return nil }

        // 3) Battery policy (state-conditioned). `effectiveACConnected` treats a
        //    weak adapter as battery upstream.
        if !env.effectiveACConnected, let battery = env.batteryPercent {
            if battery <= env.batteryThreshold {
                return .batteryLow
            }
        }

        // 4) Thermal serious — public 4-step ≥ cutoff OR 5-step ≥ trapping (3).
        let publicTrip = env.thermalLevel >= env.thermalCutoffLevel
        let pressureTrip = (pressure ?? -1) >= 3
        if publicTrip || pressureTrip {
            return .thermalSerious
        }

        // 5) Timer cap.
        if env.maxDurationMin > 0, !env.safeScenario,
           let elapsed = env.keepAwakeElapsedMinutes {
            if elapsed >= Double(env.maxDurationMin) {
                return .timer
            }
        }

        // 6) No environment condition triggered.
        return nil
    }

    /// ADR-0025 / ADR-0004 — should the app cancel an active CLI TTL hold as part
    /// of applying a `setSleepDisabled(false)`?
    ///
    /// The helper ignores plain off-writes while a CLI hold is active ("hold owns
    /// restore", so GUI quit doesn't kill a `--forever` hold). That deferral opens
    /// a safety hole: a hardware-protection trip (thermal-critical / battery-low /
    /// thermal-serious) computes `target == false`, but the off-write is swallowed
    /// and a hot/draining Mac stays awake. To honor the core promise ("sleep when
    /// it's safer to"), the app must `cancelHold()` before the off-write — but
    /// ONLY for genuine hardware-protection trips:
    ///
    ///   - `target == false`        — we're actually trying to sleep, and
    ///   - `cliHoldActive`          — a hold is what would swallow the off-write, and
    ///   - `reason` is hardware     — `.thermalCritical` / `.batteryLow` /
    ///                                `.thermalSerious`.
    ///
    /// Deliberately excluded:
    ///   - `.timer` (the max-duration cap) — cancelling it would defeat the
    ///     `--forever` user's explicit "indefinite" intent. The cap is a soft
    ///     convenience guard, not a hardware protection.
    ///   - `.watchdog` — a helper-side liveness channel, not an app-initiated
    ///     hardware trip; the helper owns that path.
    ///   - `nil` reason — a plain/normal off (GUI quit, user toggle handled
    ///     elsewhere). Cancelling here would regress "GUI quit keeps the hold".
    public static func shouldCancelHoldOnConverge(
        target: Bool, cliHoldActive: Bool, safetyRelease: SafetyReason?
    ) -> Bool {
        guard !target, cliHoldActive else { return false }
        switch safetyRelease {
        case .thermalCritical, .batteryLow, .thermalSerious:
            return true
        case .timer, .watchdog, .none:
            return false
        }
    }
}
