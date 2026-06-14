import AppKit
import OSLog

/// Settings → Safety pane. ADR-0004 surface.
///
/// Master toggle + battery slider + thermal cutoff dropdown + max-duration
/// dropdown + read-only current-state / last-release lines.
final class SafetyPaneViewController: TimedRefreshPaneViewController {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "settings")
    private let store: StateStore

    /// Canonical (English, persisted) thermal-cutoff values, parallel to the
    /// popup's localized display titles. Logic maps by index — never localize.
    private static let thermalValues = ["nominal", "fair", "serious", "critical"]
    /// Canonical max-duration minutes, parallel to the duration popup.
    private static let durationValues = [0, 15, 30, 60, 120, 240]

    private let masterCheckbox = NSButton(checkboxWithTitle:
        NSL("safety.master", "Auto-release when conditions become unsafe"),
        target: nil, action: nil)

    private let notifyCheckbox = NSButton(checkboxWithTitle:
        NSL("safety.notify", "Notify me on auto-release"),
        target: nil, action: nil)

    private let batteryHeader = NSTextField(labelWithString: NSL("safety.batteryThreshold", "Battery threshold"))
    private let batterySlider = NSSlider(value: 30, minValue: 5, maxValue: 80, target: nil, action: nil)
    private let batteryValue = NSTextField(labelWithString: "30%")

    private let thermalHeader = NSTextField(labelWithString: NSL("safety.thermalCutoff", "Sleep once it gets this hot"))
    private let thermalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// One-line caption under the thermal popup explaining the scale direction
    /// and that a "stage" is a heat-pressure estimate, not a fixed °C
    /// (user feedback 2026-06-12: stages weren't self-explanatory).
    private let thermalCaption = NSTextField(wrappingLabelWithString: "")

    private let durationHeader = NSTextField(labelWithString: NSL("safety.maxDuration", "Maximum awake time"))
    private let durationPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let stateHeader = NSTextField(labelWithString: NSL("safety.currentState", "Current state"))
    private let stateBody = NSTextField(labelWithString: "")
    /// v0.4.0 — mini 60-second thermal chart. CPU / GPU / battery °C as lines;
    /// fallback to 5-step pressure bars when SMC is unavailable.
    private let thermalChart = ThermalChartView()

    private let releaseHeader = NSTextField(labelWithString: NSL("safety.lastRelease", "Last auto-release"))
    private let releaseBody = NSTextField(labelWithString: NSL("safety.none", "(none)"))


    init(store: StateStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        root.autoresizingMask = [.width, .height]   // fill the tab (see AgentsPane note)

        masterCheckbox.target = self
        masterCheckbox.action = #selector(masterToggled)

        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(notifyToggled)

        batteryHeader.font = NSFont.boldSystemFont(ofSize: 13)
        batterySlider.target = self
        batterySlider.action = #selector(batteryChanged)
        batterySlider.allowsTickMarkValuesOnly = true
        batterySlider.numberOfTickMarks = (80 - 5) / 5 + 1
        batterySlider.translatesAutoresizingMaskIntoConstraints = false
        batterySlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        batteryValue.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let batteryRow = NSStackView(views: [batterySlider, batteryValue])
        batteryRow.orientation = .horizontal
        batteryRow.spacing = 12

        thermalHeader.font = NSFont.boldSystemFont(ofSize: 13)
        // Cutoff dropdown — same stage words as the live "Current state" readout
        // (정상/양호/심각/위험) so the two scales line up, plus a direction hint
        // on the extremes. Separate keys from `thermal.*` so the live labels
        // stay plain.
        thermalPopup.addItems(withTitles: [
            NSL("thermal.cutoff.nominal", "Nominal — soonest, safest"),
            NSL("thermal.cutoff.fair", "Fair"),
            NSL("thermal.cutoff.serious", "Serious"),
            NSL("thermal.cutoff.critical", "Critical — latest"),
        ])
        thermalPopup.target = self
        thermalPopup.action = #selector(thermalChanged)
        thermalCaption.stringValue = NSL("safety.thermalCutoff.caption",
            "Lower stages sleep sooner and safer; higher stages stay awake longer. "
            + "A stage is macOS's heat-pressure estimate from many sensors, not a "
            + "fixed temperature — the actual °C is shown under 'Current state' below.")
        thermalCaption.font = NSFont.systemFont(ofSize: 10)
        thermalCaption.textColor = .secondaryLabelColor
        thermalCaption.maximumNumberOfLines = 0
        thermalCaption.preferredMaxLayoutWidth = 460

        durationHeader.font = NSFont.boldSystemFont(ofSize: 13)
        durationPopup.addItems(withTitles: [
            NSL("duration.unlimited", "Unlimited"),
            NSLf("duration.minutes", "%d min", 15),
            NSLf("duration.minutes", "%d min", 30),
            NSLf("duration.minutes", "%d min", 60),
            NSLf("duration.minutes", "%d min", 120),
            NSLf("duration.minutes", "%d min", 240),
        ])
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)

        stateHeader.font = NSFont.boldSystemFont(ofSize: 13)
        stateBody.font = NSFont.systemFont(ofSize: 11)
        stateBody.textColor = .secondaryLabelColor
        stateBody.maximumNumberOfLines = 0
        stateBody.preferredMaxLayoutWidth = 460

        releaseHeader.font = NSFont.boldSystemFont(ofSize: 13)
        releaseBody.font = NSFont.systemFont(ofSize: 11)
        releaseBody.textColor = .secondaryLabelColor

        // Each section header carries a visible ⓘ (click popover) in addition
        // to the hover toolTip — same string, two access paths (사용자 피드백
        // 2026-06-11: hover-only help was never discovered).
        let tips = installTooltips()
        let masterRow = InfoButton.wrap(masterCheckbox, tips.master)
        let stack = NSStackView(views: [
            masterRow,
            notifyCheckbox,
            InfoButton.wrap(batteryHeader, tips.battery), batteryRow,
            InfoButton.wrap(thermalHeader, tips.thermal), thermalPopup, thermalCaption,
            InfoButton.wrap(durationHeader, tips.duration), durationPopup,
            InfoButton.wrap(stateHeader, tips.state), stateBody, thermalChart,
            InfoButton.wrap(releaseHeader, tips.release), releaseBody,
        ])
        thermalChart.translatesAutoresizingMaskIntoConstraints = false
        thermalChart.heightAnchor.constraint(equalToConstant: 64).isActive = true
        thermalChart.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(4, after: masterRow)
        stack.setCustomSpacing(12, after: notifyCheckbox)
        stack.setCustomSpacing(12, after: batteryRow)
        stack.setCustomSpacing(3, after: thermalPopup)
        stack.setCustomSpacing(12, after: thermalCaption)
        stack.setCustomSpacing(12, after: durationPopup)
        stack.setCustomSpacing(12, after: stateBody)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])
        self.view = root
    }

    /// Help strings for the less-obvious Safety controls — assigned as hover
    /// toolTips here, and returned so loadView can attach the same text to the
    /// visible ⓘ buttons. "release" = the guard stops forcing the Mac awake.
    private func installTooltips()
        -> (master: String, battery: String, thermal: String,
            duration: String, state: String, release: String) {
        let masterTip = NSL("safety.tip.master",
            "The master switch for every guard below. When on, Electronic Clam "
            + "lets the Mac sleep again once any limit — battery, temperature, or "
            + "awake-time — is crossed.")
        masterCheckbox.toolTip = masterTip
        // The slider value is only the user's *wish*; the guard enforces a
        // state-conditioned floor on top of it (SafetyMonitor
        // .effectiveBatteryThreshold). Say so here, or a 20% slider that trips
        // at 30% with the lid closed looks like a bug.
        let batteryTip = NSL("safety.tip.battery",
            "On battery power, let the Mac sleep when the charge falls to this "
            + "level. Ignored while on AC power.")
            + "\n\n" + NSL("safety.battery.floorHelp",
            "Safety floor: with the lid closed and no external display, the "
            + "guard never goes below 30% — even if the slider is set lower. "
            + "In Low Power Mode the threshold rises another 10 points. The "
            + "slider can tighten the guard, but not loosen it past these "
            + "floors.")
        batteryHeader.toolTip = batteryTip
        batterySlider.toolTip = batteryTip
        let thermalTip = NSL("safety.tip.thermalCutoff",
            "Let the Mac sleep once it reaches this heat stage. Lower stages "
            + "sleep sooner and safer; the live temperature is under 'Current "
            + "state' below.")
        thermalHeader.toolTip = thermalTip
        thermalPopup.toolTip = thermalTip
        let durationTip = NSL("safety.tip.maxDuration",
            "Let the Mac sleep after it's been kept awake this long in one "
            + "continuous stretch. 'Unlimited' never caps it. Not applied while "
            + "docked at a desk (AC + lid open + external display).")
        durationHeader.toolTip = durationTip
        durationPopup.toolTip = durationTip
        let stateTip = NSL("safety.tip.currentState",
            "A live readout of what the guards see right now.")
        stateHeader.toolTip = stateTip
        let cooldownTip = NSL("safety.tip.cooldown",
            "'Cooldown' is a 5-minute pause after a guard lets the Mac sleep, so "
            + "it doesn't re-engage instantly. '—' means no guard has fired this "
            + "session.")
        stateBody.toolTip = cooldownTip
        let releaseTip = NSL("safety.tip.lastRelease",
            "The most recent reason a guard let the Mac sleep this session. "
            + "'(none)' means the guards never had to step in.")
        releaseHeader.toolTip = releaseTip
        return (master: masterTip, battery: batteryTip, thermal: thermalTip,
                duration: durationTip, state: stateTip + "\n\n" + cooldownTip,
                release: releaseTip)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    // 타이머 수명주기는 TimedRefreshPaneViewController 가 소유.
    override func refreshOnAppear() { refresh() }
    override func refreshTick() { refreshDynamic() }

    func refresh() {
        let s = store.safetySettings
        masterCheckbox.state = s.enabled ? .on : .off
        notifyCheckbox.state = s.notifyOnRelease ? .on : .off

        batterySlider.intValue = Int32(s.batteryLow)
        batteryValue.stringValue = "\(s.batteryLow)%"

        let thermalIndex = Self.thermalValues.firstIndex(of: s.thermalCutoff) ?? 1
        thermalPopup.selectItem(at: thermalIndex)

        let durationIndex = Self.durationValues.firstIndex(of: s.maxDurationMin) ?? 0
        durationPopup.selectItem(at: durationIndex)

        refreshDynamic()
    }

    private func refreshDynamic() {
        // Current state line. Use the raw (un-debounced) reading for display so
        // it tracks the OS immediately; the guard decision still uses the
        // debounced `batteryPercent`.
        let displayPercent = store.batteryPercentDisplay
        let battery = displayPercent.map { "\($0)%" } ?? "—"
        // Power line — distinguish raw AC from effective AC (weak adapter).
        let powerWord: String
        if store.acConnected {
            if store.effectiveACConnected {
                powerWord = store.isCharging ? NSL("power.acCharging", "AC (charging)") : NSL("power.ac", "AC")
            } else {
                powerWord = NSL("power.acNotCharging", "AC (not charging)")
            }
        } else {
            powerWord = NSL("power.battery", "Battery")
        }
        // Thermal — one intuitive indicator: the hottest SoC sensor (°C) plus the
        // public 4-step band the user configures in the cutoff dropdown. The
        // private 5-step pressure level still drives the safety *decision* (it
        // trips earlier — SafetyPolicy step 1/4), but showing it here too is
        // jargon and reads like two scales to reconcile; when it fires early the
        // detail surfaces in the "Last auto-release" reason instead.
        let publicDot = colorDot(level: SafetyMonitor.thermalLevelInt(store.thermalState))
        let publicThermal = SafetyMonitor.publicThermalLabel(store.thermalState)
        let peakSoC = [store.cpuTempCelsius, store.gpuTempCelsius].compactMap { $0 }.max()
        let tempPrefix = peakSoC.map { String(format: "%.0f°C · ", $0) } ?? ""
        let thermal = "\(tempPrefix)\(publicDot) \(publicThermal)"
        let batteryDot: String = {
            guard let p = displayPercent else { return "⚪" }
            if p < 15 { return "🔴" }
            if p < 30 { return "🟠" }
            return "🟢"
        }()
        let batTemp = store.batteryTempCelsius.map { String(format: "  %.1f°C", $0) } ?? ""
        let cpuStr = store.cpuTempCelsius.map { String(format: "%.1f°C", $0) } ?? "—"
        let gpuStr = store.gpuTempCelsius.map { String(format: "%.1f°C", $0) } ?? "—"
        let fanStr = store.fanRPM.map { "\($0) RPM" } ?? "—"
        let ext = store.extDisplayPresent ? NSL("presence.present", "present") : NSL("presence.absent", "none")
        let lid = store.lidClosed ? NSL("lid.closed", "closed") : NSL("lid.open", "open")
        let lpm = store.lowPowerMode ? NSL("common.on", "on") : NSL("common.off", "off")
        var cooldown = "—"
        if let until = store.safetyCooldownUntil, until > Date() {
            let secs = Int(until.timeIntervalSince(Date()))
            cooldown = "\(secs / 60)m \(secs % 60)s"
        }
        // Battery floor surfacing: when the state-conditioned floor or the
        // Low Power bump makes the guard trip at a different level than the
        // slider shows, append the value it will actually use — only then, so
        // the line stays quiet in the common case.
        let s = store.safetySettings
        let effectiveBattery = SafetyMonitor.effectiveBatteryThreshold(
            lidClosed: store.lidClosed,
            extDisplayPresent: store.extDisplayPresent,
            lowPowerMode: store.lowPowerMode,
            userLow: s.batteryLow)
        let effNote = (s.enabled && effectiveBattery != s.batteryLow)
            ? "   " + NSLf("safety.battery.floorHelp.effective", "(effective %d%%)", effectiveBattery)
            : ""
        // Diff-guard every assignment below: this runs at 1 Hz, and resetting
        // `stringValue` (even to an identical string) tears down the hover
        // tooltip mid-read. Only touch the views when the content changed.
        let newState =
            "\(batteryDot) \(NSL("safety.line.battery", "Battery")): \(battery)\(batTemp)   \(NSL("safety.line.power", "Power")): \(powerWord)   \(NSL("safety.line.lowPower", "Low Power")): \(lpm)\(effNote)\n" +
            "\(NSL("safety.line.thermal", "Thermal")): \(thermal)\n" +
            "CPU: \(cpuStr)   GPU: \(gpuStr)   \(NSL("safety.line.fan", "Fan")): \(fanStr)\n" +
            "\(NSL("safety.line.lid", "Lid")): \(lid)   \(NSL("safety.line.extDisplay", "Ext display")): \(ext)   \(NSL("safety.line.cooldown", "Cooldown")): \(cooldown)"
        if stateBody.stringValue != newState {
            stateBody.stringValue = newState
        }
        if thermalChart.samples != store.thermalHistory {
            thermalChart.samples = store.thermalHistory   // didSet → needsDisplay
        }
        // Repaint every tick (this runs at 1 Hz while the pane is visible) so the
        // chart scrolls continuously between the ~5s sample arrivals instead of
        // freezing then jumping. Cheap: the timer only runs while shown.
        thermalChart.needsDisplay = true

        // Last release.
        let newRelease: String
        if let r = store.safetyRelease {
            newRelease = NSLf("safety.releaseActive", "%@ (active)", humanReason(r))
        } else {
            newRelease = NSL("safety.noneThisSession", "(none in this session)")
        }
        if releaseBody.stringValue != newRelease {
            releaseBody.stringValue = newRelease
        }
    }

    // thermal label / level helpers — single source in SafetyMonitor
    // (`publicThermalLabel` / `thermalLevelInt`); local copies removed.

    /// Color-coded thermal severity dot for the current state line.
    private func colorDot(level: Int) -> String {
        switch level {
        case 0: return "🟢"
        case 1: return "🟡"
        case 2: return "🟠"
        default: return "🔴"
        }
    }

    private func humanReason(_ r: SafetyReason) -> String {
        switch r {
        case .batteryLow:      return NSL("reason.batteryLow", "Battery low")
        case .thermalSerious:  return NSL("reason.thermalSerious", "Thermal serious")
        case .thermalCritical: return NSL("reason.thermalCritical", "Thermal critical")
        case .timer:           return NSL("reason.maxDuration", "Max continuous awake reached")
        case .watchdog:        return NSL("reason.watchdog", "Helper watchdog")
        }
    }

    // MARK: - Actions

    @objc private func masterToggled() {
        var s = store.safetySettings
        s.enabled = masterCheckbox.state == .on
        store.updateSafetySettings(s)
    }

    @objc private func notifyToggled() {
        var s = store.safetySettings
        s.notifyOnRelease = notifyCheckbox.state == .on
        store.updateSafetySettings(s)
    }

    @objc private func batteryChanged() {
        // Snap to nearest 5%.
        let raw = batterySlider.intValue
        let snapped = (raw / 5) * 5
        if snapped != raw { batterySlider.intValue = snapped }
        batteryValue.stringValue = "\(snapped)%"
        var s = store.safetySettings
        s.batteryLow = Int(snapped)
        store.updateSafetySettings(s)
    }

    @objc private func thermalChanged() {
        let idx = thermalPopup.indexOfSelectedItem
        guard idx >= 0, idx < Self.thermalValues.count else { return }
        var s = store.safetySettings
        s.thermalCutoff = Self.thermalValues[idx]
        store.updateSafetySettings(s)
    }

    @objc private func durationChanged() {
        let idx = durationPopup.indexOfSelectedItem
        guard idx >= 0, idx < Self.durationValues.count else { return }
        var s = store.safetySettings
        s.maxDurationMin = Self.durationValues[idx]
        store.updateSafetySettings(s)
    }
}
