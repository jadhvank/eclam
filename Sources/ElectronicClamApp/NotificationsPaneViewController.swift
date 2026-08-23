import AppKit

/// Settings → Notifications 탭의 컨테이너. 백엔드(Telegram · Slack)를 위쪽
/// 세그먼트로 고르고, 아래에 해당 백엔드의 패널을 끼운다.
///
/// 백엔드를 최상위 탭으로 하나씩 늘리면 탭 바가 금세 붐비고(언어에 따라 라벨
/// 길이도 제각각) "알림을 어디서 켜는지"가 흩어진다. 그래서 최상위 탭은
/// Notifications 하나로 두고, 백엔드 선택만 이 안에서 한다.
///
/// 마지막으로 본 백엔드는 UserDefaults 에 기억한다 — 설정을 다시 열었을 때
/// 방금 만지던 화면으로 돌아오게 하려는 것뿐이고, 알림 동작과는 무관하다.
final class NotificationsPaneViewController: NSViewController {

    private static let lastBackendKey = "notificationsPane.backend"

    private let telegramViewController = TelegramPaneViewController()
    private let slackViewController = SlackPaneViewController()

    private let selector = NSSegmentedControl()
    private let container = NSView()

    /// 표시 순서 = 세그먼트 순서. Telegram 이 먼저 나온 백엔드라 앞에 둔다.
    private var panes: [NSViewController] { [telegramViewController, slackViewController] }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        root.autoresizingMask = [.width, .height]

        selector.translatesAutoresizingMaskIntoConstraints = false
        selector.segmentStyle = .automatic
        selector.trackingMode = .selectOne
        selector.segmentCount = 2
        selector.setLabel(NSL("notifications.backend.telegram", "Telegram"), forSegment: 0)
        selector.setLabel(NSL("notifications.backend.slack", "Slack"), forSegment: 1)
        selector.target = self
        selector.action = #selector(backendChanged)

        container.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(selector)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            selector.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            container.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        // 자식 VC 로 붙여야 viewWillAppear/Disappear 가 정상 발화한다
        // (TimedRefresh 계열 패널이 타이머를 그 시점에 정리한다).
        for vc in panes { addChild(vc) }
        select(index: restoredBackendIndex())
    }

    /// 현재 보이는 패널만이 아니라 양쪽 다 새로 고친다 — 세그먼트를 바꿨을 때
    /// 이미 최신 상태여야 하고, 두 패널 모두 자기 notifier 만 읽으므로 싸다.
    func refresh() {
        telegramViewController.refresh()
        slackViewController.refresh()
    }

    private func restoredBackendIndex() -> Int {
        let v = UserDefaults.standard.integer(forKey: Self.lastBackendKey)
        return panes.indices.contains(v) ? v : 0
    }

    @objc private func backendChanged(_ sender: NSSegmentedControl) {
        select(index: sender.selectedSegment)
        UserDefaults.standard.set(sender.selectedSegment, forKey: Self.lastBackendKey)
    }

    private func select(index: Int) {
        guard panes.indices.contains(index) else { return }
        selector.selectedSegment = index
        let pane = panes[index].view
        container.subviews.forEach { $0.removeFromSuperview() }
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: container.topAnchor),
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
