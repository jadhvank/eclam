import AppKit
import OSLog

/// Settings → Remote pane. ADR-0008 / ADR-0016 surface.
///
/// Two-tier UI over the single `remoteIdleTimeoutMin` knob (ADR-0016):
///   ☑ master checkbox  — "count remote sessions as activity" (off ⇒ value 0)
///      ◉ never expire  — value `StateStore.remoteIdleNever` (-1)
///      ○ idle timeout  — value N minutes, picked from a popup
/// The data model is untouched; this controller only maps the orthogonal
/// decisions (count at all? / expire when idle?) onto the existing value space.
/// A pane-local UserDefaults key remembers the last non-off choice so toggling
/// the master checkbox off→on restores what the user had before.
///
/// Below the controls: a read-only list of currently-detected channels,
/// refreshed every 5s while on screen.
final class RemotePaneViewController: NSViewController {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "settings")
    private let store: StateStore

    /// Pane-local memory of the last non-off value (-1 or minutes) so the
    /// master checkbox can restore it. Not part of the data model.
    private static let lastChoiceKey = "remotePane.lastIdleChoice"

    /// Popup minute presets for the "allow sleep after idle" radio.
    private let idleMinuteValues = [15, 30, 60, 120]

    private let masterCheckbox = NSButton(checkboxWithTitle:
        NSL("remote.master", "Count remote sessions as activity"),
        target: nil, action: nil)
    private let neverRadio = NSButton(radioButtonWithTitle:
        NSL("remote.optNeverIdle", "Keep awake even when idle (stay connected)"),
        target: nil, action: nil)
    private let idleRadio = NSButton(radioButtonWithTitle:
        NSL("remote.optIdleSleep", "Allow sleep when idle for"),
        target: nil, action: nil)
    private let idlePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let helpLabel = NSTextField(labelWithString:
        NSL("remote.help",
        "When you SSH, VNC, or Screen Share into this Mac, Electronic Clam " +
        "keeps it awake so the session doesn't drop."))
    private let channelsHeader = NSTextField(labelWithString: NSL("remote.channels", "Detected channels"))
    private let channelsBody = NSTextField(labelWithString: NSL("remote.noneDetected", "(none currently detected)"))
    private var refreshTimer: Timer?

    init(store: StateStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        root.autoresizingMask = [.width, .height]   // fill the tab (see AgentsPane note)

        masterCheckbox.font = NSFont.boldSystemFont(ofSize: 13)
        masterCheckbox.target = self
        masterCheckbox.action = #selector(masterToggled)
        let masterTip = NSL("remote.tip.master",
            "Remote sessions are detected via pmset assertions, who(1), the Tailscale CLI, Claude Code and Codex remote-control, and known remote-control daemons. Turn this off to ignore remote connections entirely.")
        masterCheckbox.toolTip = masterTip

        // The two radios live in different superviews (the idle one shares a row
        // with its popup), so AppKit's automatic radio grouping doesn't apply —
        // mutual exclusion is enforced manually in radioChanged(_:).
        neverRadio.target = self
        neverRadio.action = #selector(radioChanged(_:))
        let neverTip = NSL("remote.tip.neverIdle",
            "Screen-Sharing style: the Mac stays awake for as long as the session is connected, even if nothing is happening.")
        neverRadio.toolTip = neverTip

        idleRadio.target = self
        idleRadio.action = #selector(radioChanged(_:))
        let idleTip = NSL("remote.tip.idleSleep",
            "An idle SSH shell releases the Mac after this timeout — but a remote build or agent keeps it awake regardless, and Screen Sharing / VNC never time out.")
        idleRadio.toolTip = idleTip

        idlePopup.target = self
        idlePopup.action = #selector(idleMinutesChanged)
        idlePopup.removeAllItems()
        idlePopup.addItems(withTitles: idleMinuteValues.map {
            NSLf("duration.minutes", "%d min", $0)
        })
        idlePopup.toolTip = idleRadio.toolTip

        let idleRow = NSStackView(views: [idleRadio, idlePopup, InfoButton(idleTip)])
        idleRow.orientation = .horizontal
        idleRow.alignment = .firstBaseline
        idleRow.spacing = 6

        let radioStack = NSStackView(views: [InfoButton.wrap(neverRadio, neverTip), idleRow])
        radioStack.orientation = .vertical
        radioStack.alignment = .leading
        radioStack.spacing = 6
        radioStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        helpLabel.font = NSFont.systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.maximumNumberOfLines = 0
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.preferredMaxLayoutWidth = 460

        channelsHeader.font = NSFont.boldSystemFont(ofSize: 13)
        let channelsTip = NSL("remote.tip.channels",
            "The remote-access paths currently detected (shown for diagnostics). Refreshes every few seconds while this pane is open.")
        channelsHeader.toolTip = channelsTip

        channelsBody.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        channelsBody.textColor = .secondaryLabelColor
        channelsBody.maximumNumberOfLines = 0
        channelsBody.lineBreakMode = .byWordWrapping
        channelsBody.preferredMaxLayoutWidth = 460
        channelsBody.toolTip = channelsHeader.toolTip

        let stack = NSStackView(views: [InfoButton.wrap(masterCheckbox, masterTip),
                                        radioStack, helpLabel,
                                        InfoButton.wrap(channelsHeader, channelsTip),
                                        channelsBody])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: radioStack)
        stack.setCustomSpacing(16, after: helpLabel)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        syncControls()

        let newBody: String
        if store.remoteChannels.isEmpty {
            newBody = NSL("remote.noneDetected", "(none currently detected)")
        } else {
            newBody = store.remoteChannels.sorted().joined(separator: "\n")
        }
        // Diff guard — the 5s timer must not re-assign an unchanged value, or
        // it would tear down any tooltip the user is hovering over.
        if channelsBody.stringValue != newBody {
            channelsBody.stringValue = newBody
        }
    }

    // MARK: - store → controls

    /// Map `store.remoteIdleTimeoutMin` onto the two-tier controls.
    private func syncControls() {
        let value = store.remoteIdleTimeoutMin
        let on = value != 0
        masterCheckbox.state = on ? .on : .off
        neverRadio.isEnabled = on
        idleRadio.isEnabled = on

        // Even while disabled, the radios reflect the choice that *would* be
        // restored when the master is switched back on.
        let shown = on ? value : lastNonOffChoice()
        let never = (shown == StateStore.remoteIdleNever)
        neverRadio.state = never ? .on : .off
        idleRadio.state = never ? .off : .on
        idlePopup.isEnabled = on && !never

        if !never, let idx = idleMinuteValues.firstIndex(of: shown) {
            if idlePopup.indexOfSelectedItem != idx { idlePopup.selectItem(at: idx) }
        } else if never {
            // Keep the popup on the last minute choice (or default) so flipping
            // to the idle radio lands somewhere sensible.
            let fallback = lastMinutesChoice()
            if let idx = idleMinuteValues.firstIndex(of: fallback),
               idlePopup.indexOfSelectedItem != idx {
                idlePopup.selectItem(at: idx)
            }
        }
    }

    /// Last non-off value the user picked (-1 or minutes). Defaults to "never".
    private func lastNonOffChoice() -> Int {
        let v = UserDefaults.standard.integer(forKey: Self.lastChoiceKey)
        return v == 0 ? StateStore.remoteIdleNever : v
    }

    /// Last *minute* choice, for pre-selecting the popup. Defaults to 15.
    private func lastMinutesChoice() -> Int {
        let v = lastNonOffChoice()
        return idleMinuteValues.contains(v) ? v : idleMinuteValues[0]
    }

    // MARK: - controls → store

    private func apply(_ value: Int) {
        if value != 0 {
            UserDefaults.standard.set(value, forKey: Self.lastChoiceKey)
        }
        store.setRemoteIdleTimeoutMin(value)
        log.info("remoteIdleTimeoutMin set to \(value, privacy: .public)")
        syncControls()
    }

    @objc private func masterToggled() {
        apply(masterCheckbox.state == .on ? lastNonOffChoice() : 0)
    }

    @objc private func radioChanged(_ sender: NSButton) {
        if sender === neverRadio {
            apply(StateStore.remoteIdleNever)
        } else {
            let idx = idlePopup.indexOfSelectedItem
            let minutes = idleMinuteValues.indices.contains(idx)
                ? idleMinuteValues[idx] : lastMinutesChoice()
            apply(minutes)
        }
    }

    @objc private func idleMinutesChanged() {
        let idx = idlePopup.indexOfSelectedItem
        guard idleMinuteValues.indices.contains(idx) else { return }
        apply(idleMinuteValues[idx])
    }
}
