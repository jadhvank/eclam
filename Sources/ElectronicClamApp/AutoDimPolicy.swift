import Foundation

/// The holder input is eclam's existing, successfully acquired protection, never
/// Dim's own assertion or another process's aggregate power assertions.
enum AutoDimPolicy {
    static func shouldStart(keep: Bool, displayHeld: Bool, keepDisplayOption: Bool,
                            builtinAvailable: Bool, alreadyDimmed: Bool,
                            idleSeconds: TimeInterval?, thresholdSeconds: TimeInterval?) -> Bool {
        guard keep, displayHeld, !keepDisplayOption, builtinAvailable, !alreadyDimmed,
              let idleSeconds, idleSeconds.isFinite, idleSeconds >= 0,
              let thresholdSeconds, thresholdSeconds.isFinite, thresholdSeconds > 0 else { return false }
        return idleSeconds >= thresholdSeconds
    }

    static func thresholdSeconds(minutes: UInt?) -> TimeInterval? {
        guard let minutes, minutes > 0 else { return nil }
        return TimeInterval(minutes) * 60
    }
}

/// Cap the OS input age by time since restoration/eligibility. Wake and lid-open
/// need not reset the OS age; they must still grant a complete new idle period.
struct AutoDimIdlePeriod {
    private var beganAt: TimeInterval?
    private var lastSampleAt: TimeInterval?

    mutating func reset(at uptime: TimeInterval) {
        beganAt = uptime.isFinite && uptime >= 0 ? uptime : nil
        lastSampleAt = beganAt
    }

    mutating func idleSeconds(at uptime: TimeInterval, systemIdle: TimeInterval) -> TimeInterval? {
        guard uptime.isFinite, uptime >= 0, systemIdle.isFinite, systemIdle >= 0 else {
            beganAt = nil
            lastSampleAt = nil
            return nil
        }
        if beganAt == nil || uptime < (lastSampleAt ?? uptime) { reset(at: uptime) }
        lastSampleAt = uptime
        return min(systemIdle, max(0, uptime - (beganAt ?? uptime)))
    }
}
