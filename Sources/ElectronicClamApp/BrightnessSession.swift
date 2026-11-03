import Foundation

/// Recovery data for the physical built-in panel; transient CGDisplayIDs are never persisted.
struct BrightnessSnapshot: Codable, Equatable {
    let displayUUID: String
    let original: Float
    let lastApplied: Float
    let capturedAt: Date

    static let tolerance: Float = 0.01
    static let maximumRecoveryAge: TimeInterval = 24 * 60 * 60

    static func isValidBrightness(_ value: Float) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    var isStructurallyValid: Bool {
        UUID(uuidString: displayUUID) != nil
            && Self.isValidBrightness(original) && Self.isValidBrightness(lastApplied)
            && capturedAt.timeIntervalSince1970.isFinite
    }

    func isValid(at now: Date) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return isStructurallyValid && age.isFinite && age >= 0 && age <= Self.maximumRecoveryAge
    }

    func matchesPanel(_ uuid: String) -> Bool {
        guard let expected = UUID(uuidString: displayUUID), let actual = UUID(uuidString: uuid) else {
            return false
        }
        return expected == actual
    }

    func matches(_ value: Float, _ expected: Float) -> Bool {
        Self.isValidBrightness(value) && abs(value - expected) <= Self.tolerance
    }
}

enum BrightnessSessionState: Equatable {
    case idle
    /// nil is allowed only for an explicitly requested, headless Dim.
    case dimmed(BrightnessSnapshot?)
    case restorePending(BrightnessSnapshot)

    var snapshot: BrightnessSnapshot? {
        switch self {
        case .idle: return nil
        case .dimmed(let snapshot): return snapshot
        case .restorePending(let snapshot): return snapshot
        }
    }
}

/// Input timing only: no event contents or permissions are needed. A fresh sample
/// must advance the last-input timestamp, rather than merely have a low idle age.
struct DimReturnTrigger {
    private var lastInputAt: TimeInterval?
    private var lastLidState: LidState

    init(uptime: TimeInterval, idleSeconds: TimeInterval, lidState: LidState) {
        lastInputAt = Self.inputTime(uptime: uptime, idleSeconds: idleSeconds)
        lastLidState = lidState
    }

    mutating func sample(uptime: TimeInterval, idleSeconds: TimeInterval,
                         lidState: LidState) -> (newInput: Bool, lidOpened: Bool) {
        var newInput = false
        if let timestamp = Self.inputTime(uptime: uptime, idleSeconds: idleSeconds) {
            if let previous = lastInputAt { newInput = timestamp > previous + 0.01 }
            // Retain the baseline across numerical jitter; consume each new event once.
            lastInputAt = max(lastInputAt ?? timestamp, timestamp)
        }
        let lidOpened = lastLidState == .closed && lidState == .open
        // An unavailable sample cannot prove that a previously closed lid opened.
        if lidState != .unavailable { lastLidState = lidState }
        return (newInput, lidOpened)
    }

    private static func inputTime(uptime: TimeInterval, idleSeconds: TimeInterval) -> TimeInterval? {
        guard uptime.isFinite, idleSeconds.isFinite, uptime >= 0, idleSeconds >= 0 else { return nil }
        return uptime - idleSeconds
    }
}

/// Shared type; the IORegistry reader lives separately so timing policy tests stay pure.
enum LidState { case open, closed, unavailable }
