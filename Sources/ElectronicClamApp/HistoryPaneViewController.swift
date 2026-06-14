import AppKit
import OSLog
import UniformTypeIdentifiers

/// Settings → History pane. ADR-0013 surface.
///
/// Top: live current episode — awake duration, clamshell (lid-closed) time and
/// share, and what's currently holding it awake. Bottom: a table of the most
/// recent awake episodes with the reason each one ended.
final class HistoryPaneViewController: TimedRefreshPaneViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "settings")
    private let store: StateStore
    private let history: AwakeHistoryStore

    private let nowLabel  = NSTextField(labelWithString: "")
    private let clamLabel = NSTextField(labelWithString: "")
    private let holdLabel = NSTextField(labelWithString: "")

    private let weekSummaryLabel = NSTextField(labelWithString: "")

    private let timelineHeader = NSTextField(labelWithString: "")
    private let timelineView = EpisodeTimelineView()
    private let legendLabel = NSTextField(labelWithString: "")

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let exportButton = NSButton(title: "", target: nil, action: nil)
    private let footnote = NSTextField(labelWithString: "")

    /// Snapshot the table renders from; refreshed on the 1s tick.
    private var rows: [AwakeEpisode] = []

    private let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()


    init(store: StateStore, history: AwakeHistoryStore) {
        self.store = store
        self.history = history
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        // Let NSTabView stretch the root to fill the tab (see AgentsPane note).
        root.autoresizingMask = [.width, .height]

        nowLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        clamLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clamLabel.textColor = .secondaryLabelColor
        holdLabel.font = NSFont.systemFont(ofSize: 12)
        holdLabel.textColor = .secondaryLabelColor

        weekSummaryLabel.font = NSFont.systemFont(ofSize: 11)
        weekSummaryLabel.textColor = .secondaryLabelColor

        timelineHeader.stringValue = NSL("history.timeline", "Last 24 hours")
        timelineHeader.font = NSFont.boldSystemFont(ofSize: 13)
        timelineView.translatesAutoresizingMaskIntoConstraints = false
        legendLabel.font = NSFont.systemFont(ofSize: 10)
        legendLabel.attributedStringValue = legendAttributed()

        let recentHeader = NSTextField(labelWithString: NSL("history.recent", "Recent sessions"))
        recentHeader.font = NSFont.boldSystemFont(ofSize: 13)

        // Log table -----------------------------------------------------------
        addColumn("period", title: NSL("history.col.when", "When"), width: 130, min: 110)
        addColumn("dur",    title: NSL("history.col.awake", "Awake"), width: 70, min: 60)
        addColumn("lid",    title: NSL("history.col.lid", "Lid closed"), width: 110, min: 90)
        addColumn("reason", title: NSL("history.col.ended", "Ended"), width: 240, min: 150)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsColumnSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        // Last column ("Ended") absorbs spare width so the table fills the pane
        // instead of leaving a gap on the right or scrolling sideways.
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        clearButton.title = NSL("history.clear", "Clear history")
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small

        exportButton.title = NSL("history.exportCsv", "Export CSV…")
        exportButton.target = self
        exportButton.action = #selector(exportCsvTapped)
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .small

        footnote.stringValue = NSL("history.footnote", "Last 50 sessions · stored locally in Application Support")
        footnote.font = NSFont.systemFont(ofSize: 10)
        footnote.textColor = .tertiaryLabelColor
        let bottomRow = NSStackView(views: [footnote, NSView(), exportButton, clearButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill

        let stack = NSStackView(views: [
            nowLabel, clamLabel, holdLabel,
            weekSummaryLabel,
            timelineHeader, timelineView, legendLabel,
            recentHeader, scrollView, bottomRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(2, after: nowLabel)
        stack.setCustomSpacing(2, after: clamLabel)
        stack.setCustomSpacing(8, after: holdLabel)
        stack.setCustomSpacing(8, after: weekSummaryLabel)
        stack.setCustomSpacing(3, after: timelineView)
        stack.setCustomSpacing(16, after: legendLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            timelineView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            timelineView.heightAnchor.constraint(equalToConstant: 56),
            bottomRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        self.view = root
    }

    private func addColumn(_ id: String, title: String, width: CGFloat, min: CGFloat) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = min
        col.maxWidth = 100_000
        tableView.addTableColumn(col)
    }

    // 타이머 수명주기는 TimedRefreshPaneViewController 가 소유.
    override func refreshTick() { refresh() }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
    }

    func refresh() {
        let now = Date()
        if let cur = history.liveCurrent(now: now) {
            nowLabel.stringValue = NSLf("history.nowAwake", "Now awake  %@", hms(cur.duration))
            nowLabel.textColor = .labelColor
            let total = cur.duration
            let pct = total > 0 ? Int((cur.clamshellSeconds / total * 100).rounded()) : 0
            clamLabel.stringValue = NSLf("history.clamshell",
                "  └ Clamshell (lid closed)  %@  (%d%%)", hms(cur.clamshellSeconds), pct)
            clamLabel.isHidden = false
            holdLabel.stringValue = NSLf("history.holding", "  └ Holding: %@", currentHolding())
            holdLabel.isHidden = false
        } else {
            nowLabel.stringValue = NSL("history.notAwake", "Not awake right now")
            nowLabel.textColor = .secondaryLabelColor
            clamLabel.isHidden = true
            holdLabel.isHidden = true
        }
        // Weekly summary line
        let ws = history.weeklySummary(now: now)
        if ws.totalAwake > 0 || ws.safetyTrips > 0 {
            let tripsStr = ws.safetyTrips > 0
                ? NSLf("history.weekTrips", " · %1$d guard trips", ws.safetyTrips)
                : ""
            weekSummaryLabel.stringValue = NSLf(
                "history.weekSummary",
                "This week: awake %1$@ · agents %2$@ · clamshell %3$@%4$@",
                shortDur(ws.totalAwake), shortDur(ws.byAgent), shortDur(ws.clamshell), tripsStr)
            weekSummaryLabel.isHidden = false
        } else {
            weekSummaryLabel.isHidden = true
        }

        rows = history.displayRows(now: now)
        timelineView.episodes = rows
        tableView.reloadData()
    }

    /// What is currently keeping the Mac awake, by the same priority order as
    /// `StateStore.shouldKeepAwake`.
    private func currentHolding() -> String {
        if store.manualToggle { return NSL("hold.manual", "manual toggle") }
        if store.remoteCountsAsActivity && store.remoteActive {
            let ch = store.remoteChannels.sorted().joined(separator: ", ")
            return ch.isEmpty ? NSL("hold.remoteBare", "remote") : NSLf("hold.remote", "remote (%@)", ch)
        }
        if !store.activeAgents.isEmpty {
            return NSLf("hold.agent", "agent (%@)", store.activeAgents.sorted().joined(separator: ", "))
        }
        return "—"
    }

    /// Color legend for the episode timeline, matching `EpisodeTimelineView`.
    private func legendAttributed() -> NSAttributedString {
        let out = NSMutableAttributedString()
        func chip(_ color: NSColor, _ label: String) {
            out.append(NSAttributedString(string: "● ", attributes: [
                .foregroundColor: color, .font: NSFont.systemFont(ofSize: 10)]))
            out.append(NSAttributedString(string: label + "   ", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 10)]))
        }
        chip(.systemBlue,   NSL("cause.manual", "manual toggle"))
        chip(.systemGreen,  NSL("cause.agent", "agent"))
        chip(.systemPurple, NSL("cause.remote", "remote"))
        return out
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let colId = tableColumn?.identifier.rawValue else { return nil }
        let ep = rows[row]
        let id = NSUserInterfaceItemIdentifier(colId + "Cell")
        let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? makeLabel(id)
        label.textColor = .labelColor
        switch colId {
        case "period":
            let start = hm.string(from: ep.startedAt)
            let end = ep.isOngoing ? NSL("history.now", "now") : hm.string(from: ep.endedAt ?? ep.startedAt)
            label.stringValue = "\(start)–\(end)"
            label.toolTip = NSLf("history.startedBy", "Started by %@", causeText(ep.startCause, ep.startDetail))
        case "dur":
            label.stringValue = compactDur(ep.duration)
        case "lid":
            let pct = ep.duration > 0 ? Int((ep.clamshellSeconds / ep.duration * 100).rounded()) : 0
            label.stringValue = ep.clamshellSeconds < 1 ? "—" : "\(compactDur(ep.clamshellSeconds)) (\(pct)%)"
            label.textColor = ep.clamshellSeconds < 1 ? .secondaryLabelColor : .labelColor
        case "reason":
            if ep.isOngoing {
                label.stringValue = NSL("history.ongoing", "● ongoing")
                label.textColor = .systemGreen
            } else if let r = ep.endReason {
                let (emoji, text, color) = reasonStyle(r)
                let detail = ep.endDetail.map { " \($0)" } ?? ""
                label.stringValue = "\(emoji) \(text)\(detail)"
                label.textColor = color
            } else {
                label.stringValue = "—"
            }
        default:
            return nil
        }
        return label
    }

    private func makeLabel(_ id: NSUserInterfaceItemIdentifier) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.identifier = id
        l.lineBreakMode = .byTruncatingTail
        l.font = NSFont.systemFont(ofSize: 12)
        return l
    }

    // MARK: - Actions

    @objc private func exportCsvTapped() {
        let panel = NSSavePanel()
        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            return f.string(from: Date())
        }()
        panel.nameFieldStringValue = "eclam-history-\(dateStr).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let now = Date()
        let allRows = history.displayRows(now: now)
        let csv = buildCsv(allRows, now: now)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSL("history.exportCsv.error", "Export failed")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func clearTapped() {
        let confirm = NSAlert()
        confirm.messageText = NSL("history.clear.title", "Clear awake history?")
        confirm.informativeText = NSL("history.clear.body",
            "Removes all recorded past sessions. The current session (if awake) is kept.")
        confirm.addButton(withTitle: NSL("history.clear.confirm", "Clear"))
        confirm.addButton(withTitle: NSL("common.cancel", "Cancel"))
        if confirm.runModal() == .alertFirstButtonReturn {
            history.clear()
            refresh()
        }
    }

    // MARK: - CSV export

    /// Build RFC 4180-compliant CSV for all episodes.
    private func buildCsv(_ eps: [AwakeEpisode], now: Date) -> String {
        let iso: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }()

        func quote(_ s: String) -> String {
            let needs = s.contains(",") || s.contains("\"") || s.contains("\n")
            if needs { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return s
        }

        var lines: [String] = [
            "started_at,ended_at,duration_s,clamshell_s,start_cause,start_detail,end_reason,end_detail"
        ]
        for ep in eps {
            let startStr  = iso.string(from: ep.startedAt)
            let endStr    = ep.endedAt.map { iso.string(from: $0) } ?? ""
            let durStr    = String(Int(ep.duration.rounded()))
            let clamStr   = String(Int(ep.clamshellSeconds.rounded()))
            let causeStr  = ep.startCause.rawValue
            let detailStr = ep.startDetail ?? ""
            let reasonStr = ep.endReason?.rawValue ?? ""
            let endDetStr = ep.endDetail ?? ""
            let row = [startStr, endStr, durStr, clamStr,
                       quote(causeStr), quote(detailStr),
                       quote(reasonStr), quote(endDetStr)].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Formatting

    /// Short "Xh Ym" formatter for the weekly summary line.
    private func shortDur(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// `H:MM:SS` / `MM:SS` live clock for the header.
    private func hms(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }

    /// Compact duration for table cells: `2h05`, `56m`, `42s`.
    private func compactDur(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s >= 3600 { return String(format: "%dh%02d", s / 3600, (s % 3600) / 60) }
        if s >= 60   { return "\(s / 60)m" }
        return "\(s)s"
    }

    private func causeText(_ c: AwakeStartCause, _ detail: String?) -> String {
        let base: String
        switch c {
        case .manual: base = NSL("cause.manual", "manual toggle")
        case .agent:  base = NSL("cause.agent", "agent")
        case .remote: base = NSL("cause.remote", "remote")
        case .unknown: base = NSL("cause.unknown", "unknown")
        }
        if let d = detail, !d.isEmpty { return "\(base) (\(d))" }
        return base
    }

    private func reasonStyle(_ r: AwakeEndReason) -> (String, String, NSColor) {
        switch r {
        case .manualOff:         return ("✋", NSL("end.manualOff", "manual off"), .secondaryLabelColor)
        case .forceSleep:        return ("😴", NSL("end.forceSleep", "force sleep"), .secondaryLabelColor)
        case .agentCeased:       return ("🤖", NSL("end.agentDone", "agent done"), .secondaryLabelColor)
        case .remoteEnded:       return ("🖥", NSL("end.remoteEnded", "remote ended"), .secondaryLabelColor)
        case .remoteNetworkLost: return ("📡", NSL("end.networkLost", "network lost"), .systemOrange)
        case .batteryLow:        return ("🔋", NSL("end.batteryLow", "battery low"), .systemOrange)
        case .thermalSerious:    return ("🌡", NSL("end.thermal", "thermal"), .systemOrange)
        case .thermalCritical:   return ("🔥", NSL("end.thermalCritical", "thermal critical"), .systemRed)
        case .timer:             return ("⏱", NSL("end.durationCap", "duration cap"), .secondaryLabelColor)
        case .watchdog:          return ("🐕", NSL("end.watchdog", "watchdog"), .systemRed)
        case .appQuit:           return ("⏻", NSL("end.appQuit", "app quit"), .secondaryLabelColor)
        case .unknown:           return ("·", NSL("end.unknown", "ended"), .secondaryLabelColor)
        }
    }
}
