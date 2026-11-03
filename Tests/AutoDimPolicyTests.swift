import Foundation

@main
enum AutoDimPolicyTests {
    static func main() {
        var passed = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            passed += 1
        }
        for bits in 0..<64 {
            let keep = bits & 1 != 0, held = bits & 2 != 0, option = bits & 4 != 0
            let builtin = bits & 8 != 0, busy = bits & 16 != 0, idle = bits & 32 != 0
            check(AutoDimPolicy.shouldStart(keep: keep, displayHeld: held, keepDisplayOption: option,
                                           builtinAvailable: builtin, alreadyDimmed: busy,
                                           idleSeconds: idle ? 60 : 59.9, thresholdSeconds: 60)
                  == (keep && held && !option && builtin && !busy && idle), "all gates must hold")
        }
        for threshold: TimeInterval? in [nil, 0, -1, .nan, .infinity] {
            check(!AutoDimPolicy.shouldStart(keep: true, displayHeld: true, keepDisplayOption: false,
                                            builtinAvailable: true, alreadyDimmed: false,
                                            idleSeconds: 600, thresholdSeconds: threshold), "invalid/never threshold disables")
        }
        for idle: TimeInterval in [-1, .nan, .infinity] {
            check(!AutoDimPolicy.shouldStart(keep: true, displayHeld: true, keepDisplayOption: false,
                                            builtinAvailable: true, alreadyDimmed: false,
                                            idleSeconds: idle, thresholdSeconds: 60), "invalid input age disables")
        }
        var period = AutoDimIdlePeriod()
        period.reset(at: 100)
        check(period.idleSeconds(at: 159, systemIdle: 900) == 59, "wake without input still gets a full grace")
        check(period.idleSeconds(at: 160, systemIdle: 0.1) == 0.1, "new input starts a new idle period")
        check(period.idleSeconds(at: 161, systemIdle: 1.1) == 1.1, "input age advances normally")
        check(period.idleSeconds(at: 90, systemIdle: 900) == 0, "backward clock resets grace")
        check(period.idleSeconds(at: 149, systemIdle: 959) == 59, "backward clock cannot bypass grace")
        check(period.idleSeconds(at: .nan, systemIdle: 900) == nil, "invalid clock disables")
        check(period.idleSeconds(at: 500, systemIdle: 900) == 0, "first valid clock after invalid sample resets grace")
        check(period.idleSeconds(at: 501, systemIdle: -1) == nil, "invalid idle disables")
        check(period.idleSeconds(at: 502, systemIdle: 900) == 0, "invalid idle cannot preserve stale grace")
        check(AutoDimPolicy.thresholdSeconds(minutes: 0) == nil, "system Never means disabled")
        check(AutoDimPolicy.thresholdSeconds(minutes: nil) == nil, "system read failure means disabled")
        check(AutoDimPolicy.thresholdSeconds(minutes: 2) == 120, "system minutes become seconds")
        print("AutoDimPolicy tests: \(passed) passed")
    }
}
