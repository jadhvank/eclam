import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Read-only public power policy. Re-read each active tick, so current power-source
/// settings (including Never) replace old values without a cached AC/battery guess.
enum SystemDisplayIdlePolicy {
    static func thresholdSeconds() -> TimeInterval? {
        let connection = IOPMFindPowerManagement(0)
        guard connection != 0 else { return nil }
        defer { IOServiceClose(connection) }
        var minutes: UInt = 0
        guard IOPMGetAggressiveness(connection, UInt(kPMMinutesToDim), &minutes) == kIOReturnSuccess else {
            return nil
        }
        return AutoDimPolicy.thresholdSeconds(minutes: minutes)
    }
}

/// Schedules policy checks only; the AppDelegate-owned dimmer remains the sole
/// brightness/journal/resource owner for both manual and automatic episodes.
final class AutoDimCoordinator {
    struct Conditions {
        var keep: Bool
        var displayHeld: Bool
        var keepDisplayOption: Bool
        static let disabled = Conditions(keep: false, displayHeld: false, keepDisplayOption: false)
    }

    private let dimmer: BlankDisplayDimmer
    private let conditions: () -> Conditions
    private let threshold: () -> TimeInterval?
    private let scheduler: DimmerScheduling
    private let uptime: () -> TimeInterval
    private let idleSeconds: () -> TimeInterval
    private let lidState: () -> LidState
    private let beginActivity: (ProcessInfo.ActivityOptions) -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?
    private var poll: DimmerCancellation?
    private var idlePeriod = AutoDimIdlePeriod()
    private var wasEligible = false
    private var stopped = false
    private var lastLidState: LidState = .unavailable

    init(dimmer: BlankDisplayDimmer, conditions: @escaping () -> Conditions,
         threshold: @escaping () -> TimeInterval? = SystemDisplayIdlePolicy.thresholdSeconds,
         scheduler: DimmerScheduling = MainDimmerScheduler(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         idleSeconds: @escaping () -> TimeInterval = {
             CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                    eventType: CGEventType(rawValue: ~0)!)
         },
         lidState: @escaping () -> LidState = { LidStateReader.read() },
         beginActivity: @escaping (ProcessInfo.ActivityOptions) -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: $0, reason: "Electric Clam - automatic dim observation")
         },
         endActivity: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.dimmer = dimmer
        self.conditions = conditions
        self.threshold = threshold
        self.scheduler = scheduler
        self.uptime = uptime
        self.idleSeconds = idleSeconds
        self.lidState = lidState
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        let resetGrace: () -> Void = { [weak self] in
            guard let self, !self.stopped else { return }
            self.idlePeriod.reset(at: self.uptime())
        }
        dimmer.onEpisodeFinished = resetGrace
        dimmer.onReturnGraceRequested = resetGrace
    }

    deinit { endObservation() }

    /// Called after holder convergence, and by each timer tick using fresh inputs.
    func update() {
        guard !stopped else { return }
        let current = conditions()
        // An anchor may finish appearing after convergence. Keep observing while
        // work allows automatic dim, even before an independent holder exists.
        let observing = current.keep && !current.keepDisplayOption
        let enabled = current.keep && current.displayHeld && !current.keepDisplayOption
        if observing {
            // Display/system keep assertions do not prevent App Nap. Protect the
            // pre-dim observation timer without adding either sleep-prevention bit.
            if activity == nil { activity = beginActivity(.userInitiatedAllowingIdleSystemSleep) }
            if poll == nil {
                poll = scheduler.repeating(1) { [weak self] in self?.update() }
            }
        } else {
            endObservation()
        }
        let time = uptime()
        if observing {
            let lid = lidState()
            if lastLidState == .closed && lid == .open { idlePeriod.reset(at: time) }
            // Preserve a known closed sample through an unavailable observation.
            if lid != .unavailable { lastLidState = lid }
        } else {
            lastLidState = .unavailable
        }
        let limit = enabled ? threshold() : nil
        let builtin = enabled && dimmer.builtinAvailableForAutomaticDim
        let eligible = enabled && builtin && limit.map { $0.isFinite && $0 > 0 } == true
        guard eligible else {
            wasEligible = false
            idlePeriod.reset(at: time)
            dimmer.restoreAutomaticDim()
            return
        }
        if !wasEligible { idlePeriod.reset(at: time) }
        wasEligible = true
        let idle = idlePeriod.idleSeconds(at: time, systemIdle: idleSeconds())
        if AutoDimPolicy.shouldStart(keep: current.keep, displayHeld: current.displayHeld,
                                     keepDisplayOption: current.keepDisplayOption,
                                     builtinAvailable: builtin, alreadyDimmed: !dimmer.canStartAutomaticDim,
                                     idleSeconds: idle, thresholdSeconds: limit) {
            dimmer.dim(origin: .automatic)
            // Failed writes/reads must not turn an expired idle period into a
            // rapid retry loop. Recovery remains the dimmer's responsibility.
            if !dimmer.isDimmed { idlePeriod.reset(at: time) }
        }
    }

    /// AppDelegate stops scheduling before its existing bounded dimmer cleanup.
    func stop() {
        stopped = true
        endObservation()
        dimmer.onEpisodeFinished = nil
        dimmer.onReturnGraceRequested = nil
    }

    private func endObservation() {
        poll?.cancel()
        poll = nil
        if let activity { endActivity(activity) }
        activity = nil
    }
}
