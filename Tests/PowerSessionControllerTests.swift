import Foundation

private final class Rig {
    var wall = Date(timeIntervalSince1970: 1000)
    var monotonic: TimeInterval = 100
    var disabled = false
    var failOff = false
    var failOn = false
    var failSave = false
    var disk: HoldState?
    var writes: [Bool] = []
    lazy var controller = makeController()
    func makeController() -> PowerSessionController {
        PowerSessionController(now: { self.wall }, uptime: { self.monotonic },
            write: { on in
                self.writes.append(on)
                if on ? self.failOn : self.failOff { return false }
                self.disabled = on
                return true
            }, read: { self.disabled }, load: { self.disk }, save: { state in
                guard !self.failSave else { return false }
                self.disk = state
                return true
            })
    }
    func advance(_ seconds: Double) {
        wall.addTimeInterval(seconds)
        monotonic += seconds
    }
}

@main
enum PowerSessionControllerTests {
    static func main() {
        // A failed watchdog off must survive the next ticks, even fresh beats.
        let watchdog = Rig()
        precondition(watchdog.controller.setAppAwake(true))
        watchdog.failOff = true
        watchdog.advance(26)
        watchdog.controller.tick()
        precondition(watchdog.disabled && watchdog.controller.restorePending)
        watchdog.controller.heartbeat()
        watchdog.controller.tick()
        precondition(watchdog.writes.filter { !$0 }.count == 2)
        watchdog.failOff = false
        watchdog.controller.tick()
        precondition(!watchdog.disabled && !watchdog.controller.restorePending)
        precondition(watchdog.controller.lastTripReason == "watchdog")

        // TTL recovery survives a daemon restart; it must not revive a hold.
        let ttl = Rig()
        precondition(ttl.controller.armHold(seconds: 60))
        ttl.failOff = true
        ttl.advance(61)
        ttl.controller.tick()
        precondition(ttl.controller.restorePending && ttl.disk == .restorePending)
        let restarted = ttl.makeController()
        restarted.restoreAtLaunch()
        precondition(restarted.restorePending && restarted.remainingSeconds == 0)
        ttl.failOff = false
        restarted.tick()
        precondition(!ttl.disabled && ttl.disk == nil)

        // Explicit off is one operation and retains failed restoration, forever too.
        let off = Rig()
        precondition(off.controller.armHold(seconds: -1))
        off.failOff = true
        precondition(!off.controller.cancelHoldAndRestore())
        precondition(off.controller.remainingSeconds == 0 && off.controller.restorePending)
        precondition(off.disk == .restorePending)
        precondition(!off.controller.armHold(seconds: 60))
        precondition(!off.controller.setAppAwake(true))
        off.failOff = false
        off.controller.tick()
        precondition(off.controller.armHold(seconds: 120))
        off.controller.tick()
        precondition(off.disabled && off.controller.remainingSeconds == 120)

        // GUI quit must preserve a CLI hold; expiry must preserve a live GUI owner.
        let owners = Rig()
        precondition(owners.controller.armHold(seconds: 60))
        precondition(owners.controller.setAppAwake(true))
        precondition(owners.controller.setAppAwake(false))
        precondition(owners.disabled && owners.controller.remainingSeconds == 60)
        owners.advance(59)
        precondition(owners.controller.setAppAwake(true))
        owners.advance(2)
        owners.controller.tick()
        precondition(owners.disabled && owners.controller.remainingSeconds == 0)
        owners.advance(21)
        owners.controller.tick()
        precondition(!owners.disabled)

        // A dead GUI does not cancel the independent CLI TTL.
        let independent = Rig()
        precondition(independent.controller.armHold(seconds: 60))
        precondition(independent.controller.setAppAwake(true))
        independent.advance(25)
        independent.controller.tick()
        precondition(independent.disabled)
        independent.advance(36)
        independent.controller.tick()
        precondition(!independent.disabled)

        // Off remains retryable even when the journal cannot be written.
        let disk = Rig()
        precondition(disk.controller.armHold(seconds: -1))
        disk.failSave = true
        precondition(!disk.controller.cancelHoldAndRestore())
        precondition(!disk.disabled && disk.controller.restorePending)
        disk.failSave = false
        disk.controller.tick()
        precondition(disk.disk == nil && !disk.controller.restorePending)

        // Orphan/startup failures and restored-owner write failures retain recovery.
        for state: HoldState? in [nil, .forever, .until(epoch: 2000), .restorePending] {
            let startup = Rig()
            startup.disk = state
            startup.disabled = true
            startup.failOff = true
            startup.failOn = true
            startup.controller.restoreAtLaunch()
            precondition(startup.controller.restorePending)
            startup.failOff = false
            startup.controller.tick()
            precondition(!startup.disabled && startup.disk == nil)
        }
        let restored = Rig()
        restored.disk = .until(epoch: 1060)
        restored.controller.restoreAtLaunch()
        precondition(restored.disabled && restored.controller.remainingSeconds == 60)

        // Reject non-finite values before date arithmetic / persistence / writes.
        let invalid = Rig()
        for duration in [Double.nan, .infinity, -.infinity, 0, 59, 2592001] {
            precondition(!invalid.controller.armHold(seconds: duration))
        }
        precondition(invalid.writes.isEmpty && invalid.disk == nil)

        // The watchdog uses elapsed monotonic time even if the wall clock moves back.
        let clock = Rig()
        precondition(clock.controller.setAppAwake(true))
        clock.wall.addTimeInterval(-3600)
        clock.monotonic += 26
        clock.controller.tick()
        precondition(!clock.disabled)

        let ttlClock = Rig()
        precondition(ttlClock.controller.armHold(seconds: 60))
        ttlClock.wall.addTimeInterval(-3600)
        ttlClock.monotonic += 65
        ttlClock.controller.tick()
        precondition(!ttlClock.disabled, "wall-clock rollback must not extend a running TTL")

        let shutdown = Rig()
        precondition(shutdown.controller.armHold(seconds: -1))
        shutdown.failOff = true
        precondition(!shutdown.controller.beginShutdown())
        precondition(shutdown.controller.restorePending && shutdown.disk == .forever)
        precondition(!shutdown.controller.setAppAwake(true))
        shutdown.failOff = false
        shutdown.controller.tick()
        precondition(!shutdown.disabled && !shutdown.controller.restorePending)
        precondition(shutdown.disk == .forever, "orderly restart preserves CLI lifetime")

        // SIGTERM must finish an already owed journal update, not resurrect an
        // explicitly cancelled forever hold when storage failed transiently.
        let cancelledShutdown = Rig()
        precondition(cancelledShutdown.controller.armHold(seconds: -1))
        cancelledShutdown.failSave = true
        precondition(!cancelledShutdown.controller.cancelHoldAndRestore())
        precondition(cancelledShutdown.disk == .forever)
        cancelledShutdown.failSave = false
        precondition(cancelledShutdown.controller.beginShutdown())
        precondition(cancelledShutdown.disk == nil)
        cancelledShutdown.makeController().restoreAtLaunch()
        precondition(!cancelledShutdown.disabled)

        // Background heartbeat still ticks during a stalled main/safety loop.
        // Production lease + helper must together restore without UI cooperation.
        let stalled = Rig()
        let lease = SafetyHeartbeatLease(uptime: { stalled.monotonic })
        lease.keepAwakeRequested = true
        lease.evaluated(safe: true)
        precondition(stalled.controller.setAppAwake(true))
        for step in 1...8 {
            stalled.advance(5)
            if step % 2 == 0 && lease.shouldHeartbeat { stalled.controller.heartbeat() }
            stalled.controller.tick()
        }
        precondition(!stalled.disabled && stalled.controller.lastTripReason == "watchdog")
        print("PASS power ownership: watchdog, TTL, atomic off, retries, restart, persistence, clock")
    }
}
