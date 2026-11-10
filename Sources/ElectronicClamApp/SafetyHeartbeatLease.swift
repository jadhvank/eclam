import Foundation

/// A live process is insufficient: heartbeats require a recently completed
/// safety evaluation too. Monotonic time avoids extending the lease when the
/// wall clock changes. One lock protects both inputs across main/timer queues.
final class SafetyHeartbeatLease {
    private let lock = NSLock()
    private let uptime: () -> TimeInterval
    private let lifetime: TimeInterval = 15
    private var lastSafeEvaluation: TimeInterval?
    private var requested = false

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    var keepAwakeRequested: Bool {
        get { lock.lock(); defer { lock.unlock() }; return requested }
        set { lock.lock(); requested = newValue; lock.unlock() }
    }

    func evaluated(safe: Bool) {
        lock.lock(); defer { lock.unlock() }
        lastSafeEvaluation = safe ? uptime() : nil
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        lastSafeEvaluation = nil
    }

    var shouldHeartbeat: Bool {
        lock.lock(); defer { lock.unlock() }
        guard requested, let last = lastSafeEvaluation else { return false }
        let age = uptime() - last
        return age >= 0 && age <= lifetime
    }
}
