// PolicyTests.swift — standalone swiftc test program for the framework-free
// pure policy layer (SafetyPolicy.swift). Compiled together with that source as
// the main file (top-level code is the program entry point). No XCTest, no
// SwiftPM — see scripts/test.sh. Exits 0 on success, 1 (with a descriptive
// message) on the first failed assertion.

import Foundation

// MARK: - tiny assert harness

var currentSuite = "?"
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL [\(currentSuite)]: \(msg)\n".utf8))
    exit(1)
}
func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
    if !cond { fail(msg()) }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got != want { fail("\(what): got \(got), want \(want)") }
}

// MARK: - decideKeepAwake builder (full defaults so each test varies one axis)

func awake(safetyReleaseActive: Bool = false,
           cooldownActive: Bool = false,
           manualToggle: Bool = false,
           manualOverrideOff: Bool = false,
           remoteCountsAsActivity: Bool = true,
           remoteActive: Bool = false,
           agentMode: AgentMode = .strict,
           activeAgentsNonEmpty: Bool = false,
           laxProcessAlive: Bool = false) -> Bool {
    decideKeepAwake(AwakeInputs(
        safetyReleaseActive: safetyReleaseActive,
        cooldownActive: cooldownActive,
        manualToggle: manualToggle,
        manualOverrideOff: manualOverrideOff,
        remoteCountsAsActivity: remoteCountsAsActivity,
        remoteActive: remoteActive,
        agentMode: agentMode,
        activeAgentsNonEmpty: activeAgentsNonEmpty,
        laxProcessAlive: laxProcessAlive))
}

func testDecideKeepAwake() {
    currentSuite = "decideKeepAwake"

    // --- the 6 ordering branches, each in isolation ---

    // 1) safetyRelease active ⇒ false (wins over everything)
    expectEqual(awake(safetyReleaseActive: true), false, "1: safetyRelease⇒false")

    // 2) cooldown active ⇒ false
    expectEqual(awake(cooldownActive: true), false, "2: cooldown⇒false")

    // 3) manualToggle ⇒ true
    expectEqual(awake(manualToggle: true), true, "3: manualToggle⇒true")

    // 4) manualOverrideOff (no manual toggle) ⇒ false
    expectEqual(awake(manualOverrideOff: true), false, "4: manualOverrideOff⇒false")

    // 5) remote active (knob enabled) ⇒ true
    expectEqual(awake(remoteActive: true), true, "5: remote⇒true")
    //    remote active but knob disabled ⇒ falls through (no other signal) ⇒ false
    expectEqual(awake(remoteCountsAsActivity: false, remoteActive: true), false,
                "5: remote-but-knob-off⇒false")

    // 6) Strict: any active agent ⇒ true; none ⇒ false
    expectEqual(awake(agentMode: .strict, activeAgentsNonEmpty: true), true,
                "6: strict active⇒true")
    expectEqual(awake(agentMode: .strict, activeAgentsNonEmpty: false), false,
                "6: strict idle⇒false")

    //    Lax: active OR process alive ⇒ true; neither ⇒ false
    expectEqual(awake(agentMode: .lax, activeAgentsNonEmpty: false, laxProcessAlive: true),
                true, "6: lax process-alive⇒true")
    expectEqual(awake(agentMode: .lax, activeAgentsNonEmpty: true, laxProcessAlive: false),
                true, "6: lax active⇒true")
    expectEqual(awake(agentMode: .lax, activeAgentsNonEmpty: false, laxProcessAlive: false),
                false, "6: lax idle⇒false")

    // --- ordering / priority cases ---

    // ADR-0014: manualOverrideOff=true + active agent ⇒ false (auto suppressed)
    expectEqual(awake(manualOverrideOff: true, activeAgentsNonEmpty: true), false,
                "ADR-0014: overrideOff beats active agent")
    //    …and beats an active remote too
    expectEqual(awake(manualOverrideOff: true, remoteActive: true), false,
                "ADR-0014: overrideOff beats remote")
    //    …but manualToggle (checked first) still wins over overrideOff
    expectEqual(awake(manualToggle: true, manualOverrideOff: true), true,
                "manualToggle beats overrideOff (toggle checked first)")

    // safety-release wins over EVERYTHING
    expectEqual(awake(safetyReleaseActive: true, manualToggle: true,
                      remoteActive: true, activeAgentsNonEmpty: true), false,
                "safety-release wins over manual+remote+agent")

    // cooldown wins over manual toggle (and below)
    expectEqual(awake(cooldownActive: true, manualToggle: true), false,
                "cooldown beats manualToggle")
    expectEqual(awake(cooldownActive: true, remoteActive: true,
                      activeAgentsNonEmpty: true), false,
                "cooldown beats remote+agent")

    // manualToggle beats agent + remote
    expectEqual(awake(manualToggle: true, remoteActive: true,
                      activeAgentsNonEmpty: true), true,
                "manualToggle beats agent+remote")

    print("OK: decideKeepAwake")
}

// MARK: - SafetyPolicy.evaluate

func env(masterEnabled: Bool = true,
         thermalLevel: Int = 0,
         thermalCutoffLevel: Int = 2,           // .serious by default
         thermalPressureLevel: Int? = nil,
         effectiveACConnected: Bool = true,
         batteryPercent: Int? = 80,
         batteryThreshold: Int = 30,
         maxDurationMin: Int = 0,
         safeScenario: Bool = false,
         keepAwakeElapsedMinutes: Double? = nil) -> SafetyEnvironment {
    SafetyEnvironment(
        masterEnabled: masterEnabled,
        thermalLevel: thermalLevel,
        thermalCutoffLevel: thermalCutoffLevel,
        thermalPressureLevel: thermalPressureLevel,
        effectiveACConnected: effectiveACConnected,
        batteryPercent: batteryPercent,
        batteryThreshold: batteryThreshold,
        maxDurationMin: maxDurationMin,
        safeScenario: safeScenario,
        keepAwakeElapsedMinutes: keepAwakeElapsedMinutes)
}

func testSafetyPolicy() {
    currentSuite = "SafetyPolicy.evaluate"

    // baseline: nothing trips
    expectEqual(SafetyPolicy.evaluate(env()), nil, "baseline⇒nil")

    // --- battery threshold boundary (on battery) ---
    // at threshold (<=) ⇒ trips
    expectEqual(SafetyPolicy.evaluate(env(effectiveACConnected: false,
                                          batteryPercent: 30, batteryThreshold: 30)),
                .batteryLow, "battery == threshold trips")
    // below threshold ⇒ trips
    expectEqual(SafetyPolicy.evaluate(env(effectiveACConnected: false,
                                          batteryPercent: 29, batteryThreshold: 30)),
                .batteryLow, "battery < threshold trips")
    // one above threshold ⇒ no trip
    expectEqual(SafetyPolicy.evaluate(env(effectiveACConnected: false,
                                          batteryPercent: 31, batteryThreshold: 30)),
                nil, "battery > threshold no trip")

    // --- AC-connected suppresses battery release ---
    expectEqual(SafetyPolicy.evaluate(env(effectiveACConnected: true,
                                          batteryPercent: 5, batteryThreshold: 30)),
                nil, "AC connected suppresses battery release")
    // nil battery reading ⇒ no battery trip even on battery power
    expectEqual(SafetyPolicy.evaluate(env(effectiveACConnected: false,
                                          batteryPercent: nil, batteryThreshold: 30)),
                nil, "nil battery reading ⇒ no trip")

    // --- critical thermal trips regardless of master toggle ---
    // public level 3 (.critical), master OFF
    expectEqual(SafetyPolicy.evaluate(env(masterEnabled: false, thermalLevel: 3)),
                .thermalCritical, "public critical trips with master OFF")
    // 5-step pressure == 4 (.sleeping), master OFF
    expectEqual(SafetyPolicy.evaluate(env(masterEnabled: false, thermalLevel: 0,
                                          thermalPressureLevel: 4)),
                .thermalCritical, "5-step sleeping trips with master OFF")
    // critical even outranks an on-battery low-battery situation
    expectEqual(SafetyPolicy.evaluate(env(thermalLevel: 3, effectiveACConnected: false,
                                          batteryPercent: 2, batteryThreshold: 30)),
                .thermalCritical, "critical outranks battery")

    // --- master toggle off suppresses everything EXCEPT critical ---
    expectEqual(SafetyPolicy.evaluate(env(masterEnabled: false,
                                          effectiveACConnected: false,
                                          batteryPercent: 2, batteryThreshold: 30)),
                nil, "master OFF suppresses battery release")
    expectEqual(SafetyPolicy.evaluate(env(masterEnabled: false, thermalLevel: 2,
                                          thermalCutoffLevel: 2)),
                nil, "master OFF suppresses thermal-serious")

    // --- thermal serious: public ≥ cutoff OR 5-step ≥ trapping(3) ---
    expectEqual(SafetyPolicy.evaluate(env(thermalLevel: 2, thermalCutoffLevel: 2)),
                .thermalSerious, "public level == cutoff trips serious")
    expectEqual(SafetyPolicy.evaluate(env(thermalLevel: 1, thermalCutoffLevel: 2)),
                nil, "public level < cutoff no serious")
    expectEqual(SafetyPolicy.evaluate(env(thermalLevel: 0, thermalPressureLevel: 3)),
                .thermalSerious, "5-step trapping(3) trips serious")
    expectEqual(SafetyPolicy.evaluate(env(thermalLevel: 0, thermalPressureLevel: 2)),
                nil, "5-step heavy(2) below trapping no serious")

    // battery outranks thermal-serious (battery checked first)
    expectEqual(SafetyPolicy.evaluate(env(thermalLevel: 2, thermalCutoffLevel: 2,
                                          effectiveACConnected: false,
                                          batteryPercent: 10, batteryThreshold: 30)),
                .batteryLow, "battery checked before thermal-serious")

    // --- timer cap ---
    // elapsed >= cap, not safe scenario ⇒ trips
    expectEqual(SafetyPolicy.evaluate(env(maxDurationMin: 60, safeScenario: false,
                                          keepAwakeElapsedMinutes: 60)),
                .timer, "timer at cap trips")
    expectEqual(SafetyPolicy.evaluate(env(maxDurationMin: 60, safeScenario: false,
                                          keepAwakeElapsedMinutes: 59.9)),
                nil, "timer below cap no trip")
    // safe desk scenario (AC + lid open + ext display) suppresses the cap
    expectEqual(SafetyPolicy.evaluate(env(maxDurationMin: 60, safeScenario: true,
                                          keepAwakeElapsedMinutes: 999)),
                nil, "safe scenario suppresses timer cap")
    // maxDuration 0 (unlimited) ⇒ never trips
    expectEqual(SafetyPolicy.evaluate(env(maxDurationMin: 0, safeScenario: false,
                                          keepAwakeElapsedMinutes: 9999)),
                nil, "maxDuration 0 ⇒ never trips")
    // not currently keeping awake (nil elapsed) ⇒ no timer trip
    expectEqual(SafetyPolicy.evaluate(env(maxDurationMin: 60, safeScenario: false,
                                          keepAwakeElapsedMinutes: nil)),
                nil, "nil elapsed ⇒ no timer trip")

    // --- external-display / lid combination via safeScenario gate ---
    // (lid open + ext display + AC ⇒ safeScenario true ⇒ timer suppressed; tested above)
    // not-safe (e.g. lid closed) ⇒ timer enforced
    expectEqual(SafetyPolicy.evaluate(env(maxDurationMin: 30, safeScenario: false,
                                          keepAwakeElapsedMinutes: 45)),
                .timer, "non-safe scenario enforces timer cap")

    print("OK: SafetyPolicy.evaluate")
}

// MARK: - SafetyPolicy.shouldCancelHoldOnConverge (P1 — CLI hold safety hole)

func testShouldCancelHoldOnConverge() {
    currentSuite = "shouldCancelHoldOnConverge"

    func cancel(_ target: Bool, _ holdActive: Bool, _ reason: SafetyReason?) -> Bool {
        SafetyPolicy.shouldCancelHoldOnConverge(
            target: target, cliHoldActive: holdActive, safetyRelease: reason)
    }

    // --- hardware-protection trips with target=false & hold active ⇒ cancel ---
    expectEqual(cancel(false, true, .thermalCritical), true, "thermalCritical ⇒ cancel")
    expectEqual(cancel(false, true, .batteryLow), true, "batteryLow ⇒ cancel")
    expectEqual(cancel(false, true, .thermalSerious), true, "thermalSerious ⇒ cancel")

    // --- excluded reasons ⇒ never cancel (respect --forever / helper-owned) ---
    expectEqual(cancel(false, true, .timer), false, "timer cap ⇒ no cancel (--forever intent)")
    expectEqual(cancel(false, true, .watchdog), false, "watchdog ⇒ no cancel (helper-owned)")
    expectEqual(cancel(false, true, nil), false, "no reason (plain off) ⇒ no cancel (keep hold on GUI quit)")

    // --- gate: target=true (staying awake) ⇒ never cancel, regardless of reason ---
    expectEqual(cancel(true, true, .thermalCritical), false, "target=true ⇒ no cancel")

    // --- gate: no active hold ⇒ nothing to cancel ---
    expectEqual(cancel(false, false, .thermalCritical), false, "no hold ⇒ no cancel")
    expectEqual(cancel(false, false, nil), false, "no hold + no reason ⇒ no cancel")

    print("OK: SafetyPolicy.shouldCancelHoldOnConverge")
}

// MARK: - run
//
// `@main` entry point. When swiftc compiles multiple input files together, bare
// top-level statements are only allowed in a file literally named `main.swift`;
// this file isn't, so we use an explicit `@main` type instead.

@main
enum PolicyTestMain {
    static func main() {
        testDecideKeepAwake()
        testSafetyPolicy()
        testShouldCancelHoldOnConverge()
        print("OK: all policy suites")
    }
}
