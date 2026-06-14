import AppKit
import OSLog

/// Two-pane Settings window for M1 (ADR-0006 §D, §E).
///   General: about box (name / version / copyright / repo link).
///   Agents:  mode radio, watched-agents table, hook install buttons.
final class SettingsWindowController: NSWindowController {

    enum Pane: Int { case general = 0, agents = 1, remote = 2, safety = 3, notifications = 4, history = 5 }

    private static let repoURLString = "https://github.com/jadhvank/eclam"

    private let store: StateStore
    private let history: AwakeHistoryStore
    private let onRelocalize: () -> Void
    // var: relocalize() 가 새 언어로 패널을 통째로 재생성한다 (ADR-0011 §C v3).
    private var agentsViewController: AgentsPaneViewController
    private var remoteViewController: RemotePaneViewController
    private var safetyViewController: SafetyPaneViewController
    private var telegramViewController: TelegramPaneViewController
    private var historyViewController: HistoryPaneViewController
    private var generalViewController: GeneralPaneViewController
    private let tabView = NSTabView()

    init(store: StateStore, history: AwakeHistoryStore, onRelocalize: @escaping () -> Void) {
        self.store = store
        self.history = history
        self.onRelocalize = onRelocalize
        self.agentsViewController = AgentsPaneViewController(store: store)
        self.remoteViewController = RemotePaneViewController(store: store)
        self.safetyViewController = SafetyPaneViewController(store: store)
        self.telegramViewController = TelegramPaneViewController()
        self.historyViewController = HistoryPaneViewController(store: store, history: history)
        self.generalViewController = GeneralPaneViewController(store: store, onLanguageChanged: onRelocalize)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = NSL("settings.title", "Electronic Clam Settings")
        window.isReleasedWhenClosed = false
        // Accessory (menu-bar) apps easily lose active status, and AppKit
        // suppresses tooltips in windows of inactive apps by default — so the
        // Settings tooltips never appeared even though every control sets one
        // (2026-06-11 사용자 보고).
        window.allowsToolTipsWhenApplicationIsInactive = true
        window.minSize = NSSize(width: 560, height: 480)
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// ADR-0018 — re-render the General pane's permission row. Called on app
    /// reactivation so returning from System Settings updates the row live.
    func refreshGeneralPane() {
        generalViewController.refresh()
    }

    func show(pane: Pane = .general) {
        window?.center()
        tabView.selectTabViewItem(at: pane.rawValue)
        agentsViewController.refresh()
        remoteViewController.refresh()
        safetyViewController.refresh()
        telegramViewController.refresh()
        historyViewController.refresh()
        generalViewController.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let window = window, let contentView = window.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = NSL("tab.general", "General")
        generalTab.view = generalViewController.view
        tabView.addTabViewItem(generalTab)

        let agentsTab = NSTabViewItem(identifier: "agents")
        agentsTab.label = NSL("tab.agents", "Agents")
        agentsTab.view = agentsViewController.view
        tabView.addTabViewItem(agentsTab)

        let remoteTab = NSTabViewItem(identifier: "remote")
        remoteTab.label = NSL("tab.remote", "Remote")
        remoteTab.view = remoteViewController.view
        tabView.addTabViewItem(remoteTab)

        let safetyTab = NSTabViewItem(identifier: "safety")
        safetyTab.label = NSL("tab.safety", "Safety")
        safetyTab.view = safetyViewController.view
        tabView.addTabViewItem(safetyTab)

        let telegramTab = NSTabViewItem(identifier: "notifications")
        telegramTab.label = NSL("tab.notifications", "Notifications")
        telegramTab.view = telegramViewController.view
        tabView.addTabViewItem(telegramTab)

        let historyTab = NSTabViewItem(identifier: "history")
        historyTab.label = NSL("tab.history", "History")
        historyTab.view = historyViewController.view
        tabView.addTabViewItem(historyTab)

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    /// ADR-0011 §C v3 — 재시작도, 창 재생성도 없는 라이브 언어 전환.
    /// 이전 구현은 창을 닫고 새로 만들었는데(탭 위치 유실 + 깜빡임), NSL 이
    /// loadView 시점에 박히는 구조라 패널 VC 만 새로 만들어 탭의 view 를
    /// 갈아끼우면 충분하다. 옛 view 가 윈도우에서 빠질 때 viewWillDisappear 가
    /// 발화해 TimedRefresh 타이머도 자연 정리된다. 선택 탭은 보존.
    func relocalize() {
        let selectedIndex = tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) } ?? 0

        agentsViewController = AgentsPaneViewController(store: store)
        remoteViewController = RemotePaneViewController(store: store)
        safetyViewController = SafetyPaneViewController(store: store)
        telegramViewController = TelegramPaneViewController()
        historyViewController = HistoryPaneViewController(store: store, history: history)
        generalViewController = GeneralPaneViewController(store: store, onLanguageChanged: onRelocalize)

        let panes: [(String, NSViewController)] = [
            (NSL("tab.general", "General"), generalViewController),
            (NSL("tab.agents", "Agents"), agentsViewController),
            (NSL("tab.remote", "Remote"), remoteViewController),
            (NSL("tab.safety", "Safety"), safetyViewController),
            (NSL("tab.notifications", "Notifications"), telegramViewController),
            (NSL("tab.history", "History"), historyViewController),
        ]
        for (i, (label, vc)) in panes.enumerated() {
            let item = tabView.tabViewItem(at: i)
            item.label = label
            item.view = vc.view
        }
        window?.title = NSL("settings.title", "Electronic Clam Settings")
        tabView.selectTabViewItem(at: selectedIndex)
        generalViewController.refresh()
    }
}
