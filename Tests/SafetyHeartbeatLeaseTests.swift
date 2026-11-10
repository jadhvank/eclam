import Foundation

@main
enum SafetyHeartbeatLeaseTests {
    static func main() {
        var clock: TimeInterval = 100
        let lease = SafetyHeartbeatLease(uptime: { clock })
        lease.keepAwakeRequested = true
        precondition(!lease.shouldHeartbeat, "no evaluation yet")
        lease.evaluated(safe: true)
        clock += 10
        precondition(lease.shouldHeartbeat, "short main delay is tolerated")
        clock += 5
        precondition(lease.shouldHeartbeat, "inclusive 15-second boundary")
        clock += 0.01
        precondition(!lease.shouldHeartbeat, "stalled safety loop stops heartbeat")
        lease.keepAwakeRequested = true
        precondition(!lease.shouldHeartbeat, "convergence cannot renew safety")
        lease.evaluated(safe: true)
        precondition(lease.shouldHeartbeat, "fresh evaluation recovers")
        lease.evaluated(safe: false)
        precondition(!lease.shouldHeartbeat, "unsafe verdict invalidates immediately")
        lease.evaluated(safe: true)
        lease.keepAwakeRequested = false
        precondition(!lease.shouldHeartbeat, "off never beats")
        lease.keepAwakeRequested = true
        lease.invalidate()
        precondition(!lease.shouldHeartbeat, "stop invalidates safety lease")
        let concurrent = SafetyHeartbeatLease(uptime: { 100 })
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            concurrent.keepAwakeRequested = index % 2 == 0
            concurrent.evaluated(safe: index % 3 == 0)
            _ = concurrent.shouldHeartbeat
            if index % 5 == 0 { concurrent.invalidate() }
        }
        concurrent.invalidate()
        precondition(!concurrent.shouldHeartbeat)
        print("PASS safety lease: startup, short delay, stall, recovery, unsafe, stop, concurrent access")
    }
}
