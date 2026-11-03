import Foundation

@main
enum DimReturnTriggerTests {
    static func main() {
        var passed = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            passed += 1
        }
        var trigger = DimReturnTrigger(uptime: 100, idleSeconds: 0.02, lidState: .open)
        check(!trigger.sample(uptime: 100.5, idleSeconds: 0.52, lidState: .open).newInput,
              "Same initiating input must be ignored")
        check(trigger.sample(uptime: 100.6, idleSeconds: 0.01, lidState: .open).newInput,
              "Input under two seconds must restore")
        check(!trigger.sample(uptime: 101.1, idleSeconds: 0.51, lidState: .open).newInput,
              "An input is consumed once, including during restorePending")
        for _ in ["keyboard", "mouse", "trackpad"] {
            var source = DimReturnTrigger(uptime: 100, idleSeconds: 5, lidState: .open)
            check(source.sample(uptime: 100.5, idleSeconds: 0, lidState: .open).newInput,
                  "Any combined-session input must trigger return")
        }
        var lid = DimReturnTrigger(uptime: 100, idleSeconds: 5, lidState: .closed)
        check(!lid.sample(uptime: 100.5, idleSeconds: 5.5, lidState: .unavailable).lidOpened,
              "Unavailable lid sample must not fabricate opening")
        check(lid.sample(uptime: 101, idleSeconds: 6, lidState: .open).lidOpened,
              "Closed/unavailable/open must recognize actual opening")
        check(!lid.sample(uptime: 101.5, idleSeconds: 6.5, lidState: .open).lidOpened,
              "Lid opening is consumed once")
        var invalid = DimReturnTrigger(uptime: .nan, idleSeconds: 0, lidState: .unavailable)
        check(!invalid.sample(uptime: 100, idleSeconds: -1, lidState: .unavailable).newInput,
              "Invalid idle samples must be ignored")
        check(!invalid.sample(uptime: 100, idleSeconds: 1, lidState: .open).newInput,
              "First valid sample establishes a baseline")
        check(invalid.sample(uptime: 101, idleSeconds: 0.1, lidState: .open).newInput,
              "Later fresh input still triggers after invalid samples")
        print("DimReturnTrigger tests: \(passed) passed")
    }
}
