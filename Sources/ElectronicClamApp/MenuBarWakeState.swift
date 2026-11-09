/// The selected mode is distinct from effective wakefulness (safety can pause
/// any mode). The setting enables the extra mode; it does not acquire a hold.
enum MenuBarWakeMode: Int, CaseIterable {
    case off, awake, display, automatic

    var next: Self {
        switch self {
        case .off: return .awake
        case .awake: return .display
        case .display: return .automatic
        case .automatic: return .off
        }
    }
}

struct MenuBarWakeState {
    private(set) var mode: MenuBarWakeMode = .automatic
    private(set) var caffeineEnabled: Bool

    init(savedCaffeineEnabled: Bool?) {
        caffeineEnabled = savedCaffeineEnabled ?? true
    }

    var manualAwake: Bool { mode == .awake || mode == .display }
    var forceOff: Bool { mode == .off }
    var wantsDisplay: Bool { caffeineEnabled && mode == .display }
    // Legacy OFF suppresses only the current activity. The four-mode cycle's
    // OFF stays off until the user explicitly selects another mode.
    var canResumeAutomaticWhenIdle: Bool { !caffeineEnabled && forceOff }

    mutating func select(_ mode: MenuBarWakeMode) {
        self.mode = mode == .display && !caffeineEnabled ? .awake : mode
    }

    mutating func setCaffeineEnabled(_ enabled: Bool) {
        caffeineEnabled = enabled
        if !enabled && mode == .display { mode = .awake }
    }

    mutating func click(effectiveAwake: Bool, cliHoldActive: Bool) {
        if caffeineEnabled {
            select(mode.next)
        } else {
            select(effectiveAwake || cliHoldActive ? .off : .awake)
        }
    }
}
