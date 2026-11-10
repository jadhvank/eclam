import Foundation

@main
enum HelperUpgradeTests {
    static func main() {
        func scenario(_ label: String, previous: String?, alive: [Bool], installOK: Bool,
                      expectedInstalls: Int, expectedSaved: String?, expectedOK: Bool) {
            var probes = alive
            var installs = 0
            var saved: String?
            let ok = HelperUpgrade.ensureCurrent(fingerprint: "path:new-sha", previous: previous,
                reachable: { probes.removeFirst() },
                reinstall: { installs += 1; return installOK },
                save: { saved = $0 })
            precondition(ok == expectedOK, label + ": outcome")
            precondition(installs == expectedInstalls, label + ": reinstall count")
            precondition(saved == expectedSaved, label + ": receipt")
            precondition(probes.isEmpty, label + ": probe contract")
        }
        scenario("same helper, warm launch", previous: "path:new-sha", alive: [true], installOK: true,
                 expectedInstalls: 0, expectedSaved: nil, expectedOK: true)
        scenario("migration from 0.7", previous: nil, alive: [true], installOK: true,
                 expectedInstalls: 1, expectedSaved: "path:new-sha", expectedOK: true)
        scenario("changed helper bytes", previous: "path:old-sha", alive: [true], installOK: true,
                 expectedInstalls: 1, expectedSaved: "path:new-sha", expectedOK: true)
        scenario("moved bundle", previous: "other-path:new-sha", alive: [true], installOK: true,
                 expectedInstalls: 1, expectedSaved: "path:new-sha", expectedOK: true)
        scenario("registration failed", previous: nil, alive: [], installOK: false,
                 expectedInstalls: 1, expectedSaved: nil, expectedOK: false)
        scenario("registered but unreachable", previous: nil, alive: [false], installOK: true,
                 expectedInstalls: 1, expectedSaved: nil, expectedOK: false)
        scenario("same helper died", previous: "path:new-sha", alive: [false, true], installOK: true,
                 expectedInstalls: 1, expectedSaved: "path:new-sha", expectedOK: true)
        var approved: String?
        precondition(HelperUpgrade.finishApproval(fingerprint: "new", pending: "new", enabled: true,
            reachable: { true }, save: { approved = $0 }))
        precondition(approved == "new")
        precondition(HelperUpgrade.ensureCurrent(fingerprint: "new", previous: approved,
            reachable: { true }, reinstall: { preconditionFailure("approved helper must not reinstall") },
            save: { _ in preconditionFailure("already recorded") }))
        for (pending, enabled, reachable) in [("old", true, true), ("new", false, true), ("new", true, false)] {
            precondition(!HelperUpgrade.finishApproval(fingerprint: "new", pending: pending, enabled: enabled,
                reachable: { reachable }, save: { _ in preconditionFailure("unverified approval") }))
        }
        print("OK: Helper upgrade migration, unchanged launch, changes, failures and recovery")
    }
}
