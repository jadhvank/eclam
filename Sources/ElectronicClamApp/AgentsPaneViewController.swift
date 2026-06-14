import AppKit
import OSLog

/// Agents pane — Strict/Lax radio, watched-agents table, and a collapsed-by-
/// default "Advanced" disclosure holding the optional hook installers.
/// ADR-0006 §D + §E (hooks demoted to opt-in Advanced, v0.5).
final class AgentsPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "settings")
    private let store: StateStore

    private let strictRadio = NSButton(radioButtonWithTitle: NSL("agents.mode.strict", "Strict — only count agents with recent activity"),
                                       target: nil, action: nil)
    private let laxRadio    = NSButton(radioButtonWithTitle: NSL("agents.mode.lax", "Lax — keep awake while any watched agent process is running"),
                                       target: nil, action: nil)

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let claudeStatus = NSTextField(labelWithString: "")
    private let codexStatus  = NSTextField(labelWithString: "")
    private let hermesStatus = NSTextField(labelWithString: "")
    private let claudeButton = NSButton(title: "Install Claude hook", target: nil, action: nil)
    private let codexButton  = NSButton(title: "Install Codex hook", target: nil, action: nil)
    private let hermesButton = NSButton(title: "Install Hermes hook", target: nil, action: nil)
    /// One-click cleanup. Removes our entries from all three agent configs
    /// regardless of which are currently installed. Visible only when at
    /// least one hook is installed.
    private let uninstallAllButton = NSButton(title: NSL("agents.uninstallAll", "Uninstall all hooks"), target: nil, action: nil)
    /// proposal §1 — 감지 진단 1클릭 (`eclam debug agents` 의 GUI 노출).
    private let detectNowButton = NSButton(title: NSL("agents.detectNow", "Detect Now…"), target: nil, action: nil)

    /// v0.5 (ADR-0006 §E amend) — hooks DEMOTED to an opt-in "Advanced"
    /// disclosure. File-watching already detects every agent (the glob-mtime
    /// branch of §A); hooks are only a latency/fallback booster, so they start
    /// collapsed and out of the main flow. `hookStack` is the collapsible body.
    private let hooksDisclosure = NSButton()
    private let hookStack = NSStackView()
    private var hooksExpanded = false
    private let hooksCaption = NSTextField(labelWithString:
        NSL("agents.hooks.caption",
        "Electronic Clam detects agents automatically by watching their "
        + "session logs — no hook needed. Hooks only make detection instant "
        + "and add a fallback when file access is restricted."))

    /// Subtitle under the watched-agents table asserting the default path.
    private let watchedCaption = NSTextField(labelWithString:
        NSL("agents.watched.caption",
        "Detected automatically by watching each agent's session log."))

    /// Footnote on the detection cadence (user feedback 2026-06-12: the ~5s poll
    /// felt "slow" — stating the interval sets expectations).
    private let pollNote = NSTextField(labelWithString:
        NSL("agents.pollNote",
        "Detection refreshes about every 5 seconds (30 s while the screen is "
        + "locked), so a just-started agent can take a few seconds to show. "
        + "Agents with a hook installed register instantly."))

    /// ADR-0006 §I — trust onboarding hint, shown only while the Codex hook
    /// is installed. Claude has no equivalent trust gate.
    private let codexTrustHint = NSTextField(labelWithString:
        NSL("agents.codexTrust",
        "After install, run /hooks in Codex CLI to trust this hook.\n" +
        "Re-trust needed when Electronic Clam updates the hook code."))

    /// ADR-0006 §E (v0.3.2) — Hermes also has a first-use trust prompt for
    /// shell-command hooks. Bypass options exist but we keep the default
    /// behavior (interactive approval) so users opt in explicitly.
    private let hermesTrustHint = NSTextField(labelWithString:
        NSL("agents.hermesTrust",
        "After install, approve the hook prompt the next time you run Hermes\n" +
        "(or set hooks_auto_accept: true in ~/.hermes/config.yaml)."))

    private let addButton    = NSButton(title: NSL("agents.addCustom", "Add Custom Agent…"), target: nil, action: nil)
    private let removeButton = NSButton(title: NSL("agents.remove", "Remove"), target: nil, action: nil)

    private var rows: [AgentTrace] = []

    init(store: StateStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        // NSTabView positions tab views by frame/autoresizing — let it stretch
        // the root to fill the tab (translates stays default true) so the inner
        // Auto Layout (and the table) fills the window width instead of
        // shrink-wrapping to the widest label.
        root.autoresizingMask = [.width, .height]

        // Mode group ------------------------------------------------------------
        let modeHeader = sectionLabel(NSL("agents.section.mode", "Detection mode"))
        strictRadio.target = self
        strictRadio.action = #selector(modeRadioChanged(_:))
        strictRadio.tag = 0
        laxRadio.target = self
        laxRadio.action = #selector(modeRadioChanged(_:))
        laxRadio.tag = 1
        let strictTip = NSL("agents.tip.strict",
            "Counts an agent as active only while its session log is actively "
            + "changing, so a finished or idle agent stops holding the Mac awake.")
        strictRadio.toolTip = strictTip
        let laxTip = NSL("agents.tip.lax",
            "Keeps the Mac awake while a watched agent's process is alive — even "
            + "during long idle waits, like waiting on a model reply.")
        laxRadio.toolTip = laxTip
        // Visible ⓘ next to each mode — same text as the hover toolTip
        // (2026-06-11 사용자 피드백: hover 전용 도움말은 발견 불가).
        let modeStack = NSStackView(views: [InfoButton.wrap(strictRadio, strictTip),
                                            InfoButton.wrap(laxRadio, laxTip)])
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 4
        modeStack.translatesAutoresizingMaskIntoConstraints = false

        // Watched agents table --------------------------------------------------
        let tableHeader = sectionLabel(NSL("agents.section.watched", "Watched agents"))

        let colWatched = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("watched"))
        colWatched.title = ""
        colWatched.width = 24
        colWatched.minWidth = 24
        colWatched.maxWidth = 24
        tableView.addTableColumn(colWatched)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        colName.title = NSL("agents.col.agent", "Agent")
        colName.width = 150
        colName.minWidth = 100
        tableView.addTableColumn(colName)

        let colStatus = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        colStatus.title = NSL("agents.col.status", "Status")
        colStatus.width = 100
        colStatus.minWidth = 80
        tableView.addTableColumn(colStatus)

        let colSource = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        colSource.title = NSL("agents.col.pattern", "Pattern")
        colSource.headerToolTip = NSL("agents.tip.pattern",
            "The file path Electronic Clam watches to tell this agent is working. "
            + "~/ is your home folder.")
        colSource.width = 240
        colSource.minWidth = 200
        colSource.maxWidth = 100_000
        tableView.addTableColumn(colSource)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        // "Pattern" (last) absorbs spare width; the long glob truncates with a
        // tooltip rather than forcing the whole table to scroll sideways.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        addButton.target = self
        addButton.action = #selector(addCustomTapped)
        removeButton.target = self
        removeButton.action = #selector(removeCustomTapped)
        removeButton.isEnabled = false

        let tableButtons = NSStackView(views: [addButton, removeButton])
        tableButtons.orientation = .horizontal
        tableButtons.spacing = 8
        tableButtons.translatesAutoresizingMaskIntoConstraints = false

        // Hook install group — DEMOTED to an opt-in "Advanced" disclosure
        // (ADR-0006 §E amend, v0.5). Collapsed by default; file-watching is the
        // headline path, hooks are the optional latency/fallback booster.
        // NOTE: the "hooks are optional" message lives in `hooksCaption` (a
        // visible caption), so no redundant tooltip is added on the header.
        hooksDisclosure.setButtonType(.pushOnPushOff)
        hooksDisclosure.bezelStyle = .disclosure
        hooksDisclosure.title = ""
        hooksDisclosure.state = .off
        hooksDisclosure.target = self
        hooksDisclosure.action = #selector(toggleHooksExpanded)
        let hookHeaderLabel = sectionLabel(NSL("agents.section.hooksAdvanced", "Agent hooks (optional)"))
        let hookHeaderRow = NSStackView(views: [hooksDisclosure, hookHeaderLabel])
        hookHeaderRow.orientation = .horizontal
        hookHeaderRow.spacing = 4
        hookHeaderRow.alignment = .centerY
        claudeButton.target = self
        claudeButton.action = #selector(claudeButtonTapped)
        codexButton.target = self
        codexButton.action = #selector(codexButtonTapped)
        hermesButton.target = self
        hermesButton.action = #selector(hermesButtonTapped)
        // Hermes has a first-use trust gate (see hermesTrustHint). Reassure the
        // user the hook is skippable. NOTE: the Codex button deliberately gets no
        // tooltip — the Codex hook may be removed (user decision 2026-06-10).
        hermesButton.toolTip = NSL("agents.tip.hookOptional",
            "Skip the hook if the trust step is a hassle — file-watching still "
            + "detects the agent.")
        uninstallAllButton.target = self
        uninstallAllButton.action = #selector(uninstallAllTapped)
        uninstallAllButton.bezelStyle = .rounded
        uninstallAllButton.controlSize = .small
        detectNowButton.target = self
        detectNowButton.action = #selector(detectNowTapped)
        detectNowButton.bezelStyle = .rounded
        detectNowButton.controlSize = .small
        detectNowButton.toolTip = NSL("agents.tip.detectNow",
            "Runs one detection pass and shows exactly which file each agent "
            + "matched (or why it didn't). Same output as `eclam debug agents`.")
        claudeStatus.font = NSFont.systemFont(ofSize: 11)
        claudeStatus.textColor = .secondaryLabelColor
        codexStatus.font = NSFont.systemFont(ofSize: 11)
        codexStatus.textColor = .secondaryLabelColor
        hermesStatus.font = NSFont.systemFont(ofSize: 11)
        hermesStatus.textColor = .secondaryLabelColor

        let claudeRow = NSStackView(views: [claudeButton, claudeStatus])
        claudeRow.orientation = .horizontal
        claudeRow.spacing = 12
        let codexRow = NSStackView(views: [codexButton, codexStatus])
        codexRow.orientation = .horizontal
        codexRow.spacing = 12
        let hermesRow = NSStackView(views: [hermesButton, hermesStatus])
        hermesRow.orientation = .horizontal
        hermesRow.spacing = 12

        codexTrustHint.font = NSFont.systemFont(ofSize: 11)
        codexTrustHint.textColor = .secondaryLabelColor
        codexTrustHint.maximumNumberOfLines = 0
        codexTrustHint.lineBreakMode = .byWordWrapping
        codexTrustHint.preferredMaxLayoutWidth = 420
        codexTrustHint.isHidden = true

        hermesTrustHint.font = NSFont.systemFont(ofSize: 11)
        hermesTrustHint.textColor = .secondaryLabelColor
        hermesTrustHint.maximumNumberOfLines = 0
        hermesTrustHint.lineBreakMode = .byWordWrapping
        hermesTrustHint.preferredMaxLayoutWidth = 420
        hermesTrustHint.isHidden = true

        for caption in [hooksCaption, watchedCaption, pollNote] {
            caption.font = NSFont.systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.maximumNumberOfLines = 0
            caption.lineBreakMode = .byWordWrapping
            caption.preferredMaxLayoutWidth = 460
        }

        // Indent the hints to align with the button's text, not its leading edge.
        let codexHintRow = NSStackView(views: [codexTrustHint])
        codexHintRow.orientation = .horizontal
        codexHintRow.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)

        let hermesHintRow = NSStackView(views: [hermesTrustHint])
        hermesHintRow.orientation = .horizontal
        hermesHintRow.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)

        let uninstallAllRow = NSStackView(views: [uninstallAllButton, detectNowButton])
        uninstallAllRow.orientation = .horizontal
        uninstallAllRow.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)

        for v in [hooksCaption, claudeRow, codexRow, codexHintRow, hermesRow, hermesHintRow, uninstallAllRow] {
            hookStack.addArrangedSubview(v)
        }
        hookStack.orientation = .vertical
        hookStack.alignment = .leading
        hookStack.spacing = 6
        hookStack.translatesAutoresizingMaskIntoConstraints = false
        hookStack.isHidden = true   // collapsed until the user expands "Advanced"

        // Root layout -----------------------------------------------------------
        let outer = NSStackView(views: [
            modeHeader, modeStack,
            tableHeader, watchedCaption, scrollView, tableButtons,
            hookHeaderRow, hookStack,
            pollNote,
        ])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.setCustomSpacing(2, after: tableHeader)
        outer.setCustomSpacing(14, after: modeStack)
        outer.setCustomSpacing(14, after: tableButtons)
        outer.setCustomSpacing(16, after: hookStack)
        outer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            outer.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            scrollView.heightAnchor.constraint(equalToConstant: 160),
            scrollView.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        // Surface the Advanced section for users who already rely on a hook, so
        // its status/uninstall stays discoverable despite the default collapse.
        if HookInstaller.isInstalled(.claude)
            || HookInstaller.isInstalled(.codex)
            || HookInstaller.isInstalled(.hermes) {
            setHooksExpanded(true)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
    }

    // MARK: - Refresh

    func refresh() {
        // Recompute rows: defaults first, then customs sorted by label.
        let defaultIds = Set(AgentTrace.M1Defaults.map(\.id))
        let customs = store.customTraces.sorted { $0.label < $1.label }
        rows = AgentTrace.M1Defaults + customs.filter { !defaultIds.contains($0.id) }

        switch store.agentMode {
        case .strict:
            strictRadio.state = .on; laxRadio.state = .off
        case .lax:
            strictRadio.state = .off; laxRadio.state = .on
        }

        tableView.reloadData()
        refreshHookButtons()
        removeButton.isEnabled = canRemoveSelectedRow()
    }

    private func refreshHookButtons() {
        let claudeOn = HookInstaller.isInstalled(.claude)
        let codexOn  = HookInstaller.isInstalled(.codex)
        let hermesOn = HookInstaller.isInstalled(.hermes)
        claudeButton.title = claudeOn ? NSLf("agents.uninstallHook", "Uninstall %@ hook", "Claude") : NSLf("agents.installHook", "Install %@ hook", "Claude")
        codexButton.title  = codexOn  ? NSLf("agents.uninstallHook", "Uninstall %@ hook", "Codex")  : NSLf("agents.installHook", "Install %@ hook", "Codex")
        hermesButton.title = hermesOn ? NSLf("agents.uninstallHook", "Uninstall %@ hook", "Hermes") : NSLf("agents.installHook", "Install %@ hook", "Hermes")
        claudeStatus.stringValue = claudeOn ? NSL("agents.installed", "Installed") : NSL("agents.notInstalled", "Not installed")
        codexStatus.stringValue  = codexOn  ? NSL("agents.installed", "Installed") : NSL("agents.notInstalled", "Not installed")
        hermesStatus.stringValue = hermesOn ? NSL("agents.installed", "Installed") : NSL("agents.notInstalled", "Not installed")
        // Show trust-onboarding hints only while the relevant hook is installed.
        codexTrustHint.isHidden  = !codexOn
        hermesTrustHint.isHidden = !hermesOn
        // "Uninstall all hooks" only visible when at least one is installed.
        uninstallAllButton.isHidden = !(claudeOn || codexOn || hermesOn)
        if HookInstaller.hookBinaryPath() == nil {
            claudeButton.isEnabled = false
            codexButton.isEnabled = false
            hermesButton.isEnabled = false
            claudeStatus.stringValue = NSL("agents.hookMissing", "Hook binary missing from app bundle")
            codexStatus.stringValue  = NSL("agents.hookMissing", "Hook binary missing from app bundle")
            hermesStatus.stringValue = NSL("agents.hookMissing", "Hook binary missing from app bundle")
            codexTrustHint.isHidden = true
            hermesTrustHint.isHidden = true
        } else {
            claudeButton.isEnabled = true
            codexButton.isEnabled = true
            hermesButton.isEnabled = true
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let trace = rows[row]
        guard let colId = tableColumn?.identifier.rawValue else { return nil }
        switch colId {
        case "watched":
            let id = NSUserInterfaceItemIdentifier("watchedCell")
            let check = tableView.makeView(withIdentifier: id, owner: nil) as? NSButton
                ?? makeCheckbox(identifier: id)
            check.state = store.isAgentWatched(trace.id) ? .on : .off
            check.tag = row
            return check
        case "name":
            let id = NSUserInterfaceItemIdentifier("nameCell")
            let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField)
                ?? makeLabel(identifier: id)
            label.stringValue = trace.label
            return label
        case "status":
            let id = NSUserInterfaceItemIdentifier("statusCell")
            let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField)
                ?? makeLabel(identifier: id)
            label.stringValue = store.activeAgents.contains(trace.id) ? NSL("agents.activeRow", "● active") : "—"
            label.textColor = store.activeAgents.contains(trace.id) ? .systemGreen : .secondaryLabelColor
            return label
        case "source":
            let id = NSUserInterfaceItemIdentifier("sourceCell")
            let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField)
                ?? makeLabel(identifier: id)
            label.stringValue = trace.globPattern
            label.toolTip = trace.globPattern
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            return label
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = canRemoveSelectedRow()
    }

    private func canRemoveSelectedRow() -> Bool {
        let sel = tableView.selectedRow
        guard sel >= 0, sel < rows.count else { return false }
        // Only Customize-only entries are removable.
        let trace = rows[sel]
        return store.customTraces.contains { $0.id == trace.id }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: 13)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func makeCheckbox(identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowCheckboxToggled(_:)))
        b.identifier = identifier
        return b
    }

    private func makeLabel(identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.identifier = identifier
        l.lineBreakMode = .byTruncatingMiddle
        return l
    }

    // MARK: - Actions

    @objc private func modeRadioChanged(_ sender: NSButton) {
        let next: AgentMode = (sender.tag == 1) ? .lax : .strict
        store.update(agentMode: next)
    }

    @objc private func rowCheckboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < rows.count else { return }
        store.toggleAgent(rows[row].id)
    }

    @objc private func claudeButtonTapped() {
        toggleHook(.claude)
    }

    @objc private func codexButtonTapped() {
        toggleHook(.codex)
    }

    @objc private func hermesButtonTapped() {
        toggleHook(.hermes)
    }

    @objc private func toggleHooksExpanded() {
        setHooksExpanded(!hooksExpanded)
    }

    /// Expand/collapse the Advanced hooks section (ADR-0006 §E amend).
    private func setHooksExpanded(_ expanded: Bool) {
        hooksExpanded = expanded
        hooksDisclosure.state = expanded ? .on : .off
        hookStack.isHidden = !expanded
    }

    /// proposal §1 — `eclam debug agents` 를 자기 바이너리 재호출로 실행해
    /// 모노스페이스 시트로 표시. 감지가 "왜 안 잡히는지"를 사용자가 직접 본다.
    @objc private func detectNowTapped() {
        let exe = Bundle.main.executablePath ?? ""
        let out = Subprocess.capture(exe, ["debug", "agents"])
            ?? "unavailable: could not run debug snapshot"
        let alert = NSAlert()
        alert.messageText = NSL("agents.detectNow.title", "Detection snapshot")
        alert.alertStyle = .informational
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = out
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.runModal()
    }

    @objc private func uninstallAllTapped() {
        let confirm = NSAlert()
        confirm.messageText = NSL("agents.uninstallAll.title", "Uninstall all Electronic Clam hooks?")
        confirm.informativeText = NSL("agents.uninstallAll.body",
            "Removes Electronic Clam hook entries from "
            + "~/.claude/settings.json, ~/.codex/config.toml, and "
            + "~/.hermes/config.yaml. Your other settings are preserved.")
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: NSL("agents.uninstall", "Uninstall"))
        confirm.addButton(withTitle: NSL("common.cancel", "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        var failures: [String] = []
        for target in [HookInstaller.Target.claude, .codex, .hermes] {
            guard HookInstaller.isInstalled(target) else { continue }
            do {
                try HookInstaller.uninstall(target)
            } catch {
                failures.append("\(target.label): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = NSL("agents.uninstallFail", "Some hooks could not be uninstalled")
            alert.informativeText = failures.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSL("common.ok", "OK"))
            alert.runModal()
        }
        refreshHookButtons()
    }

    private func toggleHook(_ target: HookInstaller.Target) {
        let installed = HookInstaller.isInstalled(target)
        do {
            if installed {
                try HookInstaller.uninstall(target)
            } else {
                try HookInstaller.install(target)
            }
        } catch {
            log.error("hook \(target.rawValue, privacy: .public) toggle failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = installed
                ? NSLf("agents.couldNotUninstall", "Could not uninstall %@ hook", target.label)
                : NSLf("agents.couldNotInstall", "Could not install %@ hook", target.label)
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSL("common.ok", "OK"))
            alert.runModal()
        }
        refreshHookButtons()
    }

    @objc private func addCustomTapped() {
        let alert = NSAlert()
        alert.messageText = NSL("agents.addCustom.title", "Add custom agent")
        alert.informativeText = NSL("agents.addCustom.body", "Enter a unique id, label, and a glob path. Use ~/ for your home directory.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSL("agents.add", "Add"))
        alert.addButton(withTitle: NSL("common.cancel", "Cancel"))

        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = 6
        form.translatesAutoresizingMaskIntoConstraints = false
        let idField    = NSTextField(string: "")
        let labelField = NSTextField(string: "")
        let globField  = NSTextField(string: "~/")
        idField.placeholderString    = NSL("agents.ph.id", "id (e.g. my-agent)")
        labelField.placeholderString = NSL("agents.ph.label", "Label (e.g. My Agent)")
        globField.placeholderString  = NSL("agents.ph.glob", "Glob (e.g. ~/.my-agent/logs/*.log)")
        for field in [idField, labelField, globField] {
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            form.addArrangedSubview(field)
        }
        alert.accessoryView = form
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let id = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let glob = globField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !label.isEmpty, !glob.isEmpty else {
            // Silent ignore on incomplete input — keeps cancel path frictionless.
            return
        }
        let trace = AgentTrace(id: id, label: label, globPattern: glob, freshness: 60, hookKey: nil)
        store.addCustomTrace(trace)
        refresh()
    }

    @objc private func removeCustomTapped() {
        let sel = tableView.selectedRow
        guard sel >= 0, sel < rows.count else { return }
        let trace = rows[sel]
        // Guard against accidentally pruning a default.
        guard store.customTraces.contains(where: { $0.id == trace.id }) else { return }
        store.removeCustomTrace(id: trace.id)
        refresh()
    }
}
