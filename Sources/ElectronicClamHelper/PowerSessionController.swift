import Foundation

/// All power ownership transitions run on PowerSessionRuntime's serial queue.
/// Dependencies are injected so failures and elapsed time can be tested without
/// touching IOKit, a live helper, the filesystem or real timers.
final class PowerSessionController {
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let write: (Bool) -> Bool
    private let read: () -> Bool
    private let load: () -> HoldState?
    private let save: (HoldState?) -> Bool
    private var hold: HoldState?
    private var holdDeadline: TimeInterval?
    private var appAwake = false
    private var lastHeartbeat: TimeInterval = 0
    private var shuttingDown = false
    private var preserveJournalOnShutdown = false
    private(set) var restorePending = false
    private(set) var lastTripReason: String?
    private let cutoff: TimeInterval = 20

    init(now: @escaping () -> Date, uptime: @escaping () -> TimeInterval,
         write: @escaping (Bool) -> Bool, read: @escaping () -> Bool,
         load: @escaping () -> HoldState?, save: @escaping (HoldState?) -> Bool) {
        self.now = now
        self.uptime = uptime
        self.write = write
        self.read = read
        self.load = load
        self.save = save
    }

    var sleepDisabled: Bool { read() }

    var remainingSeconds: Double {
        switch hold {
        case .forever: return -1
        case .until(let epoch):
            let wallRemaining = epoch - now().timeIntervalSince1970
            let elapsedRemaining = holdDeadline.map { $0 - uptime() } ?? wallRemaining
            return max(0, min(wallRemaining, elapsedRemaining))
        default: return 0
        }
    }

    func setAppAwake(_ enabled: Bool) -> Bool {
        guard !shuttingDown else { return false }
        if enabled {
            guard !restorePending, write(true) else { return false }
            appAwake = true
            lastHeartbeat = uptime()
            return true
        }
        appAwake = false
        // A normal GUI off/quit does not cancel an independent CLI hold.
        if remainingSeconds != 0 { return true }
        return requestRestore(reason: nil)
    }

    func heartbeat() {
        // A late heartbeat cannot revoke an already owed restoration.
        if appAwake && !restorePending { lastHeartbeat = uptime() }
    }

    func armHold(seconds: Double) -> Bool {
        guard !shuttingDown, !restorePending, seconds.isFinite,
              seconds < 0 || (60...Double(30 * 24 * 3600)).contains(seconds) else { return false }
        let next: HoldState = seconds < 0 ? .forever
            : .until(epoch: now().timeIntervalSince1970 + seconds)
        // Never enable persistent power without a durable owner.
        guard save(next) else { return false }
        guard write(true) else {
            _ = requestRestore(reason: "hold-failed")
            return false
        }
        hold = next
        holdDeadline = seconds < 0 ? nil : uptime() + seconds
        return true
    }

    /// Single serialized operation: the caller may disconnect immediately after
    /// dispatch; the daemon retains the recovery obligation without another RPC.
    func cancelHoldAndRestore() -> Bool {
        guard !shuttingDown else { return false }
        return requestRestore(reason: nil)
    }

    func restoreAtLaunch() {
        let stored = load()
        switch stored {
        case .forever:
            if write(true) { hold = stored; return }
        case .until(let epoch) where epoch > now().timeIntervalSince1970:
            if write(true) {
                hold = stored
                holdDeadline = uptime() + epoch - now().timeIntervalSince1970
                return
            }
        default: break
        }
        // Even an unavailable read must not be mistaken for a completed restore.
        _ = requestRestore(reason: "helper-restart")
    }

    func tick() {
        if restorePending {
            _ = retryRestore()
            return
        }
        let expiredApp = appAwake && uptime() - lastHeartbeat > cutoff
        if expiredApp { appAwake = false }
        let expiredHold = hold != nil && remainingSeconds == 0
        if remainingSeconds != 0 { return }
        if appAwake {
            // An expired journal cannot revive the hold on restart. Retry its
            // cleanup on future ticks without interrupting a live GUI owner.
            if expiredHold && save(nil) { hold = nil; holdDeadline = nil }
            return
        }
        if expiredHold || expiredApp {
            _ = requestRestore(reason: expiredApp ? "watchdog" : "ttl")
        }
    }

    /// SIGTERM preserves a valid CLI journal for a later daemon restart, while
    /// refusing new owners and retrying the power write before orderly exit.
    func beginShutdown() -> Bool {
        if !shuttingDown {
            // Preserve only a still-valid owner, never a cancelled owner's
            // stale journal left behind by a failed persistence operation.
            preserveJournalOnShutdown = !restorePending && remainingSeconds != 0
        }
        shuttingDown = true
        appAwake = false
        restorePending = true
        lastTripReason = "sigterm"
        return retryRestore()
    }

    private func requestRestore(reason: String?) -> Bool {
        appAwake = false
        hold = nil
        holdDeadline = nil
        restorePending = true
        if let reason = reason { lastTripReason = reason }
        return retryRestore()
    }

    private func retryRestore() -> Bool {
        if shuttingDown && preserveJournalOnShutdown {
            guard write(false) else { return false }
            restorePending = false
            return true
        }
        // Replace a forever/future journal BEFORE discarding ownership. On any
        // disk failure still attempt the safe power write, but retain recovery
        // and return an error until both power and durable state are reconciled.
        let journaled = save(.restorePending)
        let restored = write(false)
        guard journaled, restored, save(nil) else { return false }
        restorePending = false
        return true
    }
}
