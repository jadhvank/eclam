import Foundation

private final class OldHelper: NSObject, ElectronicClamHelperProtocol {
    var mutations = 0
    func protocolVersion(reply: @escaping (Int) -> Void) { reply(1) }
    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Error?) -> Void) { mutations += 1; reply(nil) }
    func holdSleepDisabled(forSeconds: Double, reply: @escaping (Error?) -> Void) { mutations += 1; reply(nil) }
    func cancelHold(reply: @escaping (Error?) -> Void) { mutations += 1; reply(nil) }
    func cancelHoldAndRestore(reply: @escaping (Error?) -> Void) { mutations += 1; reply(nil) }
    func currentState(reply: @escaping (Bool, Error?) -> Void) { reply(true, nil) }
    func currentStateWithHold(reply: @escaping (Bool, Double, Error?) -> Void) { reply(true, -1, nil) }
    func pingActivity(source: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func heartbeat(reply: @escaping (Error?) -> Void) { reply(nil) }
    func lastTripReason(reply: @escaping (String?, Error?) -> Void) { reply(nil, nil) }
    func setActiveAgents(_ ids: [String], reply: @escaping (Error?) -> Void) { reply(nil) }
    func activeAgents(reply: @escaping ([String], Error?) -> Void) { reply([], nil) }
}

@main
enum HelperPowerServiceTests {
    static func main() {
        var disabled = false
        var failOff = false
        var disk: HoldState?
        var writes: [Bool] = []
        let controller = PowerSessionController(now: { Date(timeIntervalSince1970: 1000) },
            uptime: { 100 }, write: { on in
                writes.append(on)
                if !on && failOff { return false }
                disabled = on
                return true
            }, read: { disabled }, load: { disk }, save: { disk = $0; return true })
        // Inject the runtime; never instantiate the real-power singleton or timer.
        let runtime = PowerSessionRuntime(controller: controller)
        let service = HelperService(isHook: false, power: runtime)
        service.holdSleepDisabled(forSeconds: -1) { precondition($0 == nil) }
        precondition(disabled && disk == .forever)
        AtomicOffRPC.perform(on: service) { precondition($0 == nil) }
        precondition(!disabled && disk == nil && writes == [true, false])

        service.holdSleepDisabled(forSeconds: 60) { precondition($0 == nil) }
        failOff = true
        AtomicOffRPC.perform(on: service) { precondition($0 != nil) }
        precondition(controller.restorePending && disk == .restorePending)
        // Caller is gone after its one mutation. The helper alone finishes recovery.
        failOff = false
        controller.tick()
        precondition(!disabled && disk == nil)

        service.holdSleepDisabled(forSeconds: 60) { precondition($0 == nil) }
        let hook = HelperService(isHook: true, power: runtime)
        let before = writes.count
        hook.cancelHoldAndRestore { precondition($0 != nil) }
        hook.cancelHold { precondition($0 != nil) }
        hook.setSleepDisabled(false) { precondition($0 != nil) }
        hook.holdSleepDisabled(forSeconds: 60) { precondition($0 != nil) }
        precondition(writes.count == before && disabled)
        service.cancelHold { precondition($0 == nil) }
        precondition(!disabled, "legacy cancel must also be safe")

        let old = OldHelper()
        AtomicOffRPC.perform(on: old) { precondition($0 != nil) }
        precondition(old.mutations == 0, "no two-call fallback against old helper")

        // Simultaneous connections serialize power writes and ownership.
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 2 == 0 { _ = runtime.armHold(seconds: 60) }
            else { _ = runtime.cancelHoldAndRestore() }
        }
        precondition(runtime.cancelHoldAndRestore())
        controller.tick()
        precondition(!runtime.state.disabled && runtime.state.remaining == 0)

        // Exercise the actual daemon timer wiring: once the client leaves,
        // recovery must happen without any explicit test call to tick().
        let allowOff = LockedBox(false)
        let timerPower = LockedBox(true)
        let timerDisk = LockedBox<HoldState?>(.forever)
        let recovered = DispatchSemaphore(value: 0)
        let timedController = PowerSessionController(now: Date.init,
            uptime: { ProcessInfo.processInfo.systemUptime }, write: { on in
                if !on && !allowOff.get() { return false }
                timerPower.set(on)
                if !on { recovered.signal() }
                return true
            }, read: { timerPower.get() }, load: { timerDisk.get() },
            save: { timerDisk.set($0); return true })
        let timedRuntime = PowerSessionRuntime(controller: timedController)
        timedRuntime.start()
        precondition(!timedRuntime.cancelHoldAndRestore())
        allowOff.set(true)
        precondition(recovered.wait(timeout: .now() + 8) == .success,
                     "runtime must schedule retries after caller departure")
        precondition(!timedRuntime.state.disabled && timerDisk.get() == nil)
        print("PASS helper RPC: atomic off, caller disappearance, hook denial, legacy safety, v1 refusal, serialization")
    }
}
