@main enum MenuBarWakeStateTests {
    static func main() {
        var state = MenuBarWakeState(savedCaffeineEnabled: nil)
        precondition(state.caffeineEnabled && !state.wantsDisplay)
        precondition(!MenuBarWakeState(savedCaffeineEnabled: false).caffeineEnabled)
        precondition(MenuBarWakeState(savedCaffeineEnabled: true).caffeineEnabled)

        state.select(.off)
        for expected: MenuBarWakeMode in [.awake, .display, .automatic, .off] {
            state.click(effectiveAwake: true, cliHoldActive: false)
            precondition(state.mode == expected)
            precondition(state.wantsDisplay == (expected == .display))
            precondition(state.manualAwake == (expected == .awake || expected == .display))
        }
        precondition(state.forceOff && !state.canResumeAutomaticWhenIdle)

        // Safety pauses must not change the selected mode or break the cycle.
        state.select(.display)
        state.click(effectiveAwake: false, cliHoldActive: false)
        precondition(state.mode == .automatic && !state.wantsDisplay)

        // Disabling the feature releases display protection but keeps manual
        // work awake; reenabling merely makes the fourth mode available.
        state.select(.display)
        state.setCaffeineEnabled(false)
        precondition(state.mode == .awake && state.manualAwake && !state.wantsDisplay)
        state.setCaffeineEnabled(true)
        precondition(state.mode == .awake && !state.wantsDisplay)

        state.setCaffeineEnabled(false)
        state.click(effectiveAwake: true, cliHoldActive: false)
        precondition(state.mode == .off && state.canResumeAutomaticWhenIdle)
        state.click(effectiveAwake: false, cliHoldActive: false)
        precondition(state.mode == .awake)
        state.select(.automatic)
        state.click(effectiveAwake: true, cliHoldActive: false)
        precondition(state.mode == .off)
        state.select(.automatic)
        state.click(effectiveAwake: false, cliHoldActive: true)
        precondition(state.mode == .off)
        state.select(.display)
        precondition(state.mode == .awake && !state.wantsDisplay)

        // Mode intent must still pass through the existing safety policy.
        for mode in MenuBarWakeMode.allCases {
            var control = MenuBarWakeState(savedCaffeineEnabled: true)
            control.select(mode)
            for activity in [false, true] {
                for safety in [false, true] {
                    for cooldown in [false, true] {
                        let awake = decideKeepAwake(AwakeInputs(
                            safetyReleaseActive: safety, cooldownActive: cooldown,
                            manualToggle: control.manualAwake, manualOverrideOff: control.forceOff,
                            remoteCountsAsActivity: true, remoteActive: activity,
                            agentMode: .strict, activeAgentsNonEmpty: activity, laxProcessAlive: false))
                        let expected = !safety && !cooldown &&
                            (mode == .awake || mode == .display || (mode == .automatic && activity))
                        precondition(awake == expected)
                        precondition((awake && control.wantsDisplay) == (expected && mode == .display))
                    }
                }
            }
        }
        print("PASS menu mode cycle, opt-out toggle, default/migration, display gate, safety pause and CLI hold")
    }
}
