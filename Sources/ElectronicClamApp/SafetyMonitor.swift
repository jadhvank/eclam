import AppKit
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import IOKit
import IOKit.ps
import OSLog

// ADR-0004 §2 — private 5-step thermal pressure notification. Layered on top
// of the public 4-step `ProcessInfo.thermalState`, not a replacement.
// `<notify.h>` is not exposed via Darwin umbrella on the swiftc CLI; declare
// the symbols we need by hand. Stable libSystem ABI.
@_silgen_name("notify_register_dispatch")
private func _notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func _notify_cancel(_ token: Int32) -> UInt32

@_silgen_name("notify_get_state")
private func _notify_get_state(_ token: Int32, _ outState: UnsafeMutablePointer<UInt64>) -> UInt32

private let _NOTIFY_STATUS_OK: UInt32 = 0
private let kThermalPressureNotifyName = "com.apple.system.thermalpressurelevel"

/// ADR-0004 — state-conditioned battery/thermal/timer auto-release.
///
/// Inputs:
///   - `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource`
///     for battery % and AC vs Battery (event-driven, no polling).
///   - `ProcessInfo.thermalStateDidChangeNotification` for thermal.
///   - `NSApplication.didChangeScreenParametersNotification` for ext display.
///   - 1-second decision tick to evaluate the state-conditioned table and the
///     timer cap (the only time-based trigger).
///
/// Outputs:
///   - `StateStore.setEnvironment(...)` whenever any input changes.
///   - `StateStore.setSafety(release: <reason>)` when a guard trips.
///   - Clears `safetyRelease` once conditions have recovered AND cooldown has
///     elapsed (see ADR-0004 "자동 해제 후").
final class SafetyMonitor {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "safety")
    private let store: StateStore

    private var batteryRunLoopSource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var tickTimer: Timer?
    /// 1 Hz tick counter. Every `sampleEveryTicks` ticks the tick also re-reads
    /// the environment (SMC temps, battery, lid…) so the thermal chart's rolling
    /// 60 s window keeps getting fresh samples and the safety inputs don't go
    /// stale between sparse OS edge notifications. ADR-0024.
    private var tickCount: UInt = 0
    private let sampleEveryTicks: UInt = 5

    /// 5-step thermal pressure subscription (ADR-0004 §2 layered fallback).
    /// `0` ⇒ no subscription. `nil`-result `thermalPressureLevel` in StateStore
    /// signals "subscription unavailable" to consumers.
    private var thermalPressureToken: Int32 = 0
    private var thermalPressureSubscribed: Bool = false
    /// Logs the first 5-step sample exactly once, per smoke-test requirement.
    private var thermalPressureFirstSampleLogged: Bool = false

    /// Debounce for battery sample dips. ADR-0004 §1.
    private let batteryDebounce: TimeInterval = 30
    private var batterySampleHistory: [(Date, Int)] = []
    /// Sticky AC-unplug edge: when AC drops, we re-evaluate immediately
    /// without waiting on debounce.
    private var lastSeenAC: Bool = true
    /// True once any battery sample has been committed this run. Only the
    /// genuine first sample may bypass the 30s debounce — previously a
    /// transient nil read (`store.batteryPercent == nil`) let the *next*
    /// sample through unconditionally, so a single low spike right after a
    /// failed read could trip a spurious `.batteryLow`.
    private var hasCommittedBatterySample = false

    init(store: StateStore) {
        self.store = store
    }

    func start() {
        installBatteryCallback()
        installThermalObserver()
        installThermalPressureObserver()
        installScreenObserver()
        installLowPowerModeObserver()
        startTickTimer()
        // Prime the snapshot once.
        refreshEnvironment(force: true)
        log.info("SafetyMonitor started")
    }

    /// v0.3.4 — Low Power Mode is broadcast via `NSNotification.Name.NSProcessInfoPowerStateDidChange`.
    /// We re-evaluate the environment whenever the user toggles it.
    private var lowPowerObserver: NSObjectProtocol?
    private func installLowPowerModeObserver() {
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.refreshEnvironment(force: false)
        }
    }

    func stop() {
        if let src = batteryRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            batteryRunLoopSource = nil
        }
        if let obs = thermalObserver {
            NotificationCenter.default.removeObserver(obs)
            thermalObserver = nil
        }
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
        if let obs = lowPowerObserver {
            NotificationCenter.default.removeObserver(obs)
            lowPowerObserver = nil
        }
        if thermalPressureSubscribed {
            _ = _notify_cancel(thermalPressureToken)
            thermalPressureToken = 0
            thermalPressureSubscribed = false
        }
        tickTimer?.invalidate()
        tickTimer = nil
        log.info("SafetyMonitor stopped")
    }

    // MARK: - Battery (IOPS callback)

    private func installBatteryCallback() {
        // IOPSNotificationCreateRunLoopSource fires whenever power source state
        // changes (capacity tick, AC plug/unplug, etc.).
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<SafetyMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.refreshEnvironment(force: false)
        }, context)?.takeRetainedValue() else {
            log.error("IOPSNotificationCreateRunLoopSource returned nil; battery guard inactive")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        batteryRunLoopSource = source
    }

    /// Reads the current battery %, AC state, thermal, lid/display from the
    /// system and updates StateStore.
    func refreshEnvironment(force: Bool) {
        let battery = readBatteryPercent()
        let ac = readACConnected()
        let thermal = ProcessInfo.processInfo.thermalState
        let ext = computeExternalDisplayPresent()
        let lid = computeLidClosed()

        // Battery debounce: only commit a NEW battery sample if it's been
        // stable for `batteryDebounce` seconds. AC edges bypass the debounce.
        if let b = battery {
            batterySampleHistory.append((Date(), b))
            // Trim to the debounce window.
            let cutoff = Date().addingTimeInterval(-batteryDebounce)
            batterySampleHistory.removeAll { $0.0 < cutoff }
        }
        let debouncedBattery: Int?
        if force {
            debouncedBattery = battery
        } else if ac != lastSeenAC {
            // AC edge: surface the raw value immediately.
            debouncedBattery = battery
        } else if let b = battery, let prior = store.batteryPercent, b >= prior {
            // Rising — accept immediately.
            debouncedBattery = b
        } else if let b = battery, !hasCommittedBatterySample {
            // Genuine first sample of this run — nothing to debounce against.
            debouncedBattery = b
        } else if !batterySampleHistory.isEmpty,
                  let stable = stableBatteryReading() {
            debouncedBattery = stable
        } else {
            debouncedBattery = store.batteryPercent ?? battery
        }
        if debouncedBattery != nil { hasCommittedBatterySample = true }
        lastSeenAC = ac
        // v0.4.0 — Phase 1: battery °C (public). Phase 2: SMC CPU/GPU/fan
        // (Apple Silicon only; nil on unsupported hardware).
        let batteryC = readBatteryTempCelsius()
        let cpuC = SMCReader.cpuTemperatureCelsius()
        let gpuC = SMCReader.gpuTemperatureCelsius()
        let rpm = SMCReader.fan0RPM()
        store.setEnvironment(battery: debouncedBattery,
                             batteryDisplay: battery,
                             acConnected: ac,
                             isCharging: readIsCharging(),
                             lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                             thermal: thermal,
                             lidClosed: lid,
                             extDisplay: ext,
                             batteryTempCelsius: batteryC,
                             cpuTempCelsius: cpuC,
                             gpuTempCelsius: gpuC,
                             fanRPM: rpm)
        // Push one sample to the rolling 60-second history for the chart.
        store.pushThermalSample(.init(
            at: Date(),
            cpuC: cpuC, gpuC: gpuC, batteryC: batteryC,
            publicLevel: Self.thermalLevelInt(thermal),
            pressureLevel: store.thermalPressureLevel))
        scheduleEvaluate()
    }

    private func stableBatteryReading() -> Int? {
        // Window MAXIMUM: a falling value commits only once every higher sample
        // has aged out of the 30s window — i.e. the drop has been stable for
        // `batteryDebounce` seconds, which is the contract stated where this is
        // called. This shields the guard from single low spikes / misreads;
        // a genuine drop commits ≤30s late (≈0.5%p), which the thresholds
        // absorb. (The previous window-*minimum* adopted any dip instantly,
        // making the debounce a no-op for exactly the spikes it existed to
        // filter; rising values never reach here — accepted upstream.)
        guard !batterySampleHistory.isEmpty else { return nil }
        return batterySampleHistory.map { $0.1 }.max()
    }

    private func readBatteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let cap = desc[kIOPSCurrentCapacityKey] as? Int {
                return cap
            }
        }
        return nil
    }

    /// v0.4.0 — battery temperature in °C from `kIOPSTemperatureKey` if the
    /// power source publishes it. Some Macs report centi-Kelvin (3032 → 30.17°C
    /// after `value/100 - 273.15`); others report deci-°C (302 → 30.2°C). We
    /// auto-detect by magnitude: > 1000 ⇒ centi-Kelvin, > 100 ⇒ deci-°C,
    /// otherwise the raw value is already °C.
    private func readBatteryTempCelsius() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard let raw = (desc[kIOPSTemperatureKey] as? NSNumber)?.doubleValue else { continue }
            if raw > 1000 { return (raw / 100.0) - 273.15 }
            if raw > 100  { return raw / 10.0 }
            return raw
        }
        return nil
    }

    private func readACConnected() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            // No power source info — assume AC (the safer default for an
            // unknown environment is "user knows what they're doing").
            return true
        }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == (kIOPSACPowerValue as String)
            }
        }
        return true
    }

    /// v0.3.4 — `kIOPSIsChargingKey`. False on a desktop / battery-only laptop,
    /// false also at 100% (charge maintains). Combined with `acConnected` and
    /// `batteryPercent` upstream in `StateStore.effectiveACConnected`.
    private func readIsCharging() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let charging = desc[kIOPSIsChargingKey] as? Bool { return charging }
        }
        return false
    }

    // MARK: - Thermal

    private func installThermalObserver() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.refreshEnvironment(force: false)
        }
    }

    // MARK: - Thermal pressure (5-step, private notify — ADR-0004 §2)
    //
    // Layered on top of the public `ProcessInfo.thermalState`. Apple's internal
    // pressure level reports finer granularity (.nominal/.moderate/.heavy/
    // .trapping/.sleeping) and tends to flip earlier than the public 4-step
    // value. We subscribe additively: if the channel is unavailable we silently
    // fall back to the existing 4-step logic.

    private func installThermalPressureObserver() {
        let block: @convention(block) (Int32) -> Void = { [weak self] tok in
            guard let self = self else { return }
            var state: UInt64 = 0
            let status = _notify_get_state(tok, &state)
            if status == _NOTIFY_STATUS_OK {
                let level = Self.clampThermalPressure(state)
                self.store.setThermalPressureLevel(level)
                self.scheduleEvaluate()
            } else {
                self.log.error("notify_get_state(thermalpressurelevel) status=\(status, privacy: .public)")
            }
        }
        var token: Int32 = 0
        let status = kThermalPressureNotifyName.withCString { cstr -> UInt32 in
            _notify_register_dispatch(cstr, &token, DispatchQueue.main, block)
        }
        if status != _NOTIFY_STATUS_OK {
            // Subscription unavailable — leave `thermalPressureLevel` nil so
            // consumers fall back to the public 4-step value.
            log.info("notify_register_dispatch(\(kThermalPressureNotifyName, privacy: .public)) status=\(status, privacy: .public); 5-step pressure unavailable")
            store.setThermalPressureLevel(nil)
            return
        }
        thermalPressureToken = token
        thermalPressureSubscribed = true

        // Immediate read so we don't wait for the first edge — also serves as
        // the smoke test that the channel is wired (logged once).
        var state: UInt64 = 0
        let getStatus = _notify_get_state(token, &state)
        if getStatus == _NOTIFY_STATUS_OK {
            let level = Self.clampThermalPressure(state)
            store.setThermalPressureLevel(level)
            if !thermalPressureFirstSampleLogged {
                thermalPressureFirstSampleLogged = true
                log.info("thermal pressure 5-step subscribed: initial level=\(level, privacy: .public) (\(Self.thermalPressureLabel(level), privacy: .public))")
            }
        } else {
            log.error("initial notify_get_state(thermalpressurelevel) status=\(getStatus, privacy: .public)")
        }
    }

    private static func clampThermalPressure(_ raw: UInt64) -> Int {
        // Undocumented channel — defensively clamp into our known label range.
        if raw > 4 { return 4 }
        return Int(raw)
    }

    /// 5-step label per macOS internal names. Used by the header reason text.
    static func thermalPressureLabel(_ level: Int) -> String {
        switch level {
        case 0: return "nominal"
        case 1: return "moderate"
        case 2: return "heavy"
        case 3: return "trapping"
        case 4: return "sleeping"
        default: return "nominal"
        }
    }

    // MARK: - Screen / lid

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.refreshEnvironment(force: false)
        }
    }

    private func computeExternalDisplayPresent() -> Bool {
        let screens = NSScreen.screens
        if screens.count > 1 { return true }
        // Single screen + that screen is not "Built-in" ⇒ clamshell with one
        // external (rare M2 air case where lid closed and one external).
        if let main = NSScreen.main, !main.localizedName.lowercased().contains("built-in") {
            return true
        }
        return false
    }

    /// ADR-0021 — two-track lid detection. Track A is the authoritative
    /// `AppleClamshellState` (IOPMrootDomain SPI); Track B is a public inference
    /// (internal battery ⇒ laptop, no built-in panel showing ⇒ lid closed). We
    /// read BOTH and cross-check so a silently-wrong SPI value — not just a
    /// missing one — is caught and resolved conservatively.
    private func computeLidClosed() -> Bool {
        let hasBuiltIn = NSScreen.screens.contains { isBuiltIn($0) }
        let isLaptop = hasInternalBattery()
        // Track B: no battery ⇒ desktop (no lid); laptop with no built-in panel
        // showing ⇒ lid closed.
        let publicClosed = isLaptop ? !hasBuiltIn : false

        let clam = Self.clamshellState()
        switch clam {
        case .noLid:
            // SPI reports no lid. Trust it for a true desktop; if the public side
            // sees a battery the property mis-read, so use the public inference.
            if isLaptop {
                log.error("clamshell: AppleClamshellState absent but internal battery present; using public lidClosed=\(publicClosed, privacy: .public)")
                return publicClosed
            }
            return false
        case .open, .closed:
            let spiClosed = (clam == .closed)
            if spiClosed != publicClosed {
                // Tracks disagree → pick the safety-conservative answer (closed:
                // tighter battery/thermal guard) and log so SPI drift surfaces.
                log.error("clamshell mismatch: SPI closed=\(spiClosed, privacy: .public) public closed=\(publicClosed, privacy: .public); using conservative=closed")
                return true
            }
            return spiClosed
        }
    }

    private enum ClamshellState { case open, closed, noLid }

    /// Track A — IOPMrootDomain's undocumented `AppleClamshellState` (ADR-0021,
    /// rule #6). Public IOKit functions; only the *key* is undocumented. Read-
    /// only, no entitlement. Absent ⇒ the machine has no lid (a desktop).
    private static func clamshellState() -> ClamshellState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .noLid }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return .noLid
        }
        if let closed = raw as? Bool { return closed ? .closed : .open }
        if let n = raw as? NSNumber { return n.boolValue ? .closed : .open }
        return .noLid
    }

    /// Track B — does this Mac have an internal battery (⇒ it's a laptop)?
    private func hasInternalBattery() -> Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let type = desc[kIOPSTypeKey] as? String, type == (kIOPSInternalBatteryType as String) {
                return true
            }
        }
        return false
    }

    /// Built-in panel test via the public `CGDisplayIsBuiltin`, falling back to
    /// the display's localized name.
    private func isBuiltIn(_ screen: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value {
            return CGDisplayIsBuiltin(id) != 0
        }
        return screen.localizedName.lowercased().contains("built-in")
    }

    // MARK: - Decision tick

    private func startTickTimer() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tickCount &+= 1
            // Every 5th tick re-read the environment: this pushes a fresh thermal
            // sample for the chart (ADR-0024) and refreshes the inputs the safety
            // guard reads. `refreshEnvironment` calls `evaluate()` at its tail, so
            // the 1 Hz safety re-evaluation cadence is preserved on every tick.
            if self.tickCount % self.sampleEveryTicks == 0 {
                self.refreshEnvironment(force: false)
            } else {
                self.scheduleEvaluate()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    /// Coalesces same-turn `evaluate()` triggers onto one trailing main-queue
    /// hop. The 1 Hz tick, the IOPS battery callback, the thermal/-pressure/
    /// screen/low-power observers and `refreshEnvironment`'s tail can all fire
    /// in a single runloop turn; correctness used to rest solely on the
    /// `safetyRelease != X` equality guards inside `evaluateCore` (docs/TODO.md
    /// P1). Every trigger source runs on the main thread, so a plain Bool flag
    /// suffices.
    private var evaluatePending = false
    private func scheduleEvaluate() {
        guard !evaluatePending else { return }
        evaluatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.evaluatePending = false
            self.evaluate()
        }
    }

    /// Evaluate ADR-0004 §1·§2·§4 against the current snapshot and either
    /// trip safetyRelease or clear it. Call via `scheduleEvaluate()`.
    private func evaluate() {
        let priorRelease = store.safetyRelease
        evaluateCore()
        // Edge detection for notification (ADR-0004 "## 알림"):
        // post only on transitions nil → non-nil. Identifier reuse keeps the
        // banner coalesced even when the same reason re-trips inside cooldown.
        if priorRelease == nil,
           let now = store.safetyRelease,
           store.safetySettings.notifyOnRelease {
            let detail = releaseDetail(for: now)
            Task { await ReleaseNotifier.shared.notify(reason: now, detail: detail) }
        }
    }

    private func evaluateCore() {
        let s = store.safetySettings

        // Build the framework-free snapshot from live state, then delegate the
        // ADR-0004 §1·§2·§4 decision to the pure `SafetyPolicy.evaluate`
        // (SafetyPolicy.swift). All the framework-coupled resolution — IOKit
        // reads behind `store`, `effectiveACConnected`, the state-conditioned
        // battery threshold, the Low-Power-tightened thermal cutoff, the public
        // thermal level mapping, and the timer elapsed minutes — happens HERE so
        // the policy function stays a truth table. The per-branch logging,
        // `safetyRelease != X` equality guards, master-off clear, and the
        // watchdog / sticky-cooldown clearing below all preserve today's
        // behaviour exactly.
        let pressure = store.thermalPressureLevel
        let thermalLevel = Self.thermalLevelInt(store.thermalState)
        let thermalCutoff = Self.thermalLevelInt(effectiveThermalCutoffWithLowPower(settings: s))
        let battery = store.batteryPercent
        let batteryThreshold = batteryThresholdWithLowPower(settings: s)
        // v0.3.4 E — the safest scenario (AC + lid open + ext display) is
        // "user is at a desk and meant to keep working"; skip the timer cap there.
        let safeScenario = store.effectiveACConnected
            && !store.lidClosed
            && store.extDisplayPresent
        let elapsedMinutes = store.keepAwakeSince.map {
            Date().timeIntervalSince($0) / 60.0
        }
        let env = SafetyEnvironment(
            masterEnabled: s.enabled,
            thermalLevel: thermalLevel,
            thermalCutoffLevel: thermalCutoff,
            thermalPressureLevel: pressure,
            effectiveACConnected: store.effectiveACConnected,
            batteryPercent: battery,
            batteryThreshold: batteryThreshold,
            maxDurationMin: s.maxDurationMin,
            safeScenario: safeScenario,
            keepAwakeElapsedMinutes: elapsedMinutes)

        let decided = SafetyPolicy.evaluate(env)

        // 1) Thermal `.critical` — always trips, regardless of toggle/cooldown.
        if decided == .thermalCritical {
            if store.safetyRelease != .thermalCritical {
                log.error("safety trip: thermal critical (public=\(String(describing: self.store.thermalState), privacy: .public), pressure=\(String(describing: pressure), privacy: .public))")
                store.setSafety(release: .thermalCritical)
            }
            return
        }

        // If master toggle off, we still expose `.critical` above but skip the
        // rest of the policy. (Mirrors the pure function returning nil here, but
        // the clear is unconditional — distinct from the step-6 clearing below.)
        guard s.enabled else {
            store.setSafety(release: nil)
            return
        }

        // 2) Battery policy (state-conditioned).
        if decided == .batteryLow {
            if store.safetyRelease != .batteryLow {
                log.warning("safety trip: battery \(battery ?? -1, privacy: .public)% ≤ threshold \(batteryThreshold, privacy: .public)%")
                store.setSafety(release: .batteryLow)
            }
            return
        }

        // 3) Thermal policy (state-conditioned, .critical already handled).
        if decided == .thermalSerious {
            if store.safetyRelease != .thermalSerious {
                log.warning("safety trip: thermal public=\(thermalLevel, privacy: .public)/cutoff=\(thermalCutoff, privacy: .public) pressure=\(String(describing: pressure), privacy: .public)")
                store.setSafety(release: .thermalSerious)
            }
            return
        }

        // 4) Timer cap.
        if decided == .timer {
            if store.safetyRelease != .timer {
                log.info("safety trip: timer cap \(s.maxDurationMin, privacy: .public)m reached")
                store.setSafety(release: .timer)
            }
            return
        }

        // No condition triggered (`decided == nil`) — but the 5-min cooldown
        // still suppresses re-entry. Clear `safetyRelease` only if cooldown has
        // elapsed.
        if let release = store.safetyRelease {
            if release == .watchdog {
                // Watchdog is a separate channel (helper-side), not
                // re-evaluated against environment. Leave it for the user
                // toggle / cooldown elapsed to clear.
                store.clearSafetyCooldownIfElapsed()
                if store.safetyCooldownUntil == nil {
                    store.setSafety(release: nil)
                }
                return
            }
            // Conditions recovered — clear the trip flag. The cooldown clock
            // continues running and is enforced by StateStore.shouldKeepAwake.
            store.setSafety(release: nil)
        }
        store.clearSafetyCooldownIfElapsed()
    }

    /// Human-readable detail for a release reason (notification body suffix).
    private func releaseDetail(for reason: SafetyReason) -> String? {
        switch reason {
        case .batteryLow:
            if let pct = store.batteryPercent { return "Battery \(pct)%" }
            return nil
        case .thermalSerious:
            // Prefer the 5-step label when we have it; fall back to public.
            if let p = store.thermalPressureLevel, p >= 3 {
                return "Thermal \(Self.thermalPressureLabel(p))"
            }
            return "Thermal \(Self.publicThermalLabel(store.thermalState))"
        case .thermalCritical:
            if let p = store.thermalPressureLevel, p >= 4 {
                return "Thermal \(Self.thermalPressureLabel(p))"
            }
            return "Thermal critical"
        case .timer:
            let m = store.safetySettings.maxDurationMin
            return m > 0 ? "Reached \(m)m cap" : nil
        case .watchdog:
            return "Helper unresponsive"
        }
    }

    /// Localized public 4-step label — the single source for user-facing
    /// thermal text. (The Settings pane used to keep its own *localized* copy
    /// while this one was English-only, so notification detail and the pane
    /// disagreed in non-English locales.)
    static func publicThermalLabel(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return NSL("thermal.nominal", "nominal")
        case .fair: return NSL("thermal.fair", "fair")
        case .serious: return NSL("thermal.serious", "serious")
        case .critical: return NSL("thermal.critical", "critical")
        @unknown default: return "?"
        }
    }

    // MARK: - Tables (ADR-0004 §1·§2)

    /// §1 state-conditioned battery threshold. Static & pure so the Settings →
    /// Safety pane can show the *effective* value the guard actually trips on
    /// (`safety.battery.floorHelp.effective`) without duplicating this table.
    ///
    /// Floor table:
    ///   lid closed + no ext display → 30%   (bag-like: highest risk)
    ///   lid closed + ext display    → 10%
    ///   lid open                    → 10%
    ///   (AC connected handled upstream)
    ///
    /// The state-conditioned base is a FLOOR, not a default: the user slider
    /// (`userLow`, default 30; 0 = unset → floor) can only RAISE the effective
    /// threshold above it — it can never lower it below. E.g. with the lid
    /// closed and no external display, a 20% slider still trips at 30%. The
    /// result is capped at 80%. This is deliberate (safety guard, ADR-0004 §1)
    /// and surfaced to the user via the battery row's ⓘ help
    /// (`safety.battery.floorHelp`).
    ///
    /// v0.3.4 B — when Low Power Mode is on, the threshold then rises by
    /// another 10 percentage points (capped at 80%). User signaled "battery
    /// matters more"; we honor that even when our policy alone would say
    /// "still fine".
    static func effectiveBatteryThreshold(lidClosed: Bool,
                                          extDisplayPresent: Bool,
                                          lowPowerMode: Bool,
                                          userLow: Int) -> Int {
        let floor = (lidClosed && !extDisplayPresent) ? 30 : 10
        let user = userLow == 0 ? floor : userLow
        let base = Swift.max(floor, Swift.min(80, user))
        return lowPowerMode ? Swift.min(80, base + 10) : base
    }

    private func batteryThresholdWithLowPower(settings: StateStore.SafetySettings) -> Int {
        Self.effectiveBatteryThreshold(lidClosed: store.lidClosed,
                                       extDisplayPresent: store.extDisplayPresent,
                                       lowPowerMode: store.lowPowerMode,
                                       userLow: settings.batteryLow)
    }

    private func effectiveThermalCutoff(settings: StateStore.SafetySettings) -> ProcessInfo.ThermalState {
        // §2 table:
        //   lid closed + no ext display      → .fair (bag-like)
        //   lid closed + AC unplugged        → .fair (v0.3.4 A — dock unplugged
        //                                            mid-clamshell, no airflow)
        //   else                             → .serious
        let bagLike       = store.lidClosed && !store.extDisplayPresent
        let unpoweredLid  = store.lidClosed && !store.effectiveACConnected
        let contextCutoff: ProcessInfo.ThermalState =
            (bagLike || unpoweredLid) ? .fair : .serious
        let userCutoff = parseThermalCutoff(settings.thermalCutoff)
        // Whichever is *more* conservative (lower) wins.
        return min(by: contextCutoff, userCutoff)
    }

    /// v0.3.4 B — Low Power Mode tightens the cutoff one notch: `.serious` →
    /// `.fair`. Already-strict cutoffs (`.fair`, `.nominal`) are unchanged so
    /// we don't end up tripping on a freshly-booted Mac.
    private func effectiveThermalCutoffWithLowPower(settings: StateStore.SafetySettings)
        -> ProcessInfo.ThermalState {
        let base = effectiveThermalCutoff(settings: settings)
        guard store.lowPowerMode else { return base }
        switch base {
        case .serious: return .fair
        default:       return base
        }
    }

    private func parseThermalCutoff(_ s: String) -> ProcessInfo.ThermalState {
        switch s.lowercased() {
        case "nominal":  return .nominal
        case "fair":     return .fair
        case "serious":  return .serious
        case "critical": return .critical
        default:         return .serious
        }
    }

    /// Shared public 4-step thermal rank (0=nominal … 3=critical). Single
    /// source — was duplicated in `SafetyPaneViewController`. (Can't live in
    /// framework-free `SafetyPolicy.swift`: `ProcessInfo` is Foundation.)
    static func thermalLevelInt(_ t: ProcessInfo.ThermalState) -> Int {
        switch t {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private func min(by a: ProcessInfo.ThermalState, _ b: ProcessInfo.ThermalState)
        -> ProcessInfo.ThermalState {
        Self.thermalLevelInt(a) <= Self.thermalLevelInt(b) ? a : b
    }
}
