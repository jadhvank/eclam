import AppKit
import OSLog

/// Settings → Slack pane. TelegramPaneViewController 의 형제 (같은 배치·같은 흐름).
///
/// 구성 (위에서 아래로):
///   프라이버시 고지 — 이 기능이 어디로 무엇을 보내는지 명시 (egress 원칙)
///   ☑ master — "내 Slack 봇으로 상태 보내기"
///   설정 필드 — 토큰(secure)·채널·[Look up ID]
///   이벤트 체크박스 4개 — 안전 해제 / 작업 종료 / 작업 시작 / 주기 상태
///   [테스트 전송] + 결과 라벨
///
/// 설정 필드·조회·테스트는 master OFF 여도 활성 — "켜기 전에 배선부터 확인"
/// 하는 온보딩 흐름이 자연스럽다 (sendTest 가 게이트를 우회하는 이유).
final class SlackPaneViewController: NSViewController, NSTextFieldDelegate {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "settings")
    private let notifier = SlackNotifier.shared

    private let privacyLabel = NSTextField(wrappingLabelWithString:
        NSL("slack.privacy",
        "Off by default. When enabled, status messages go only to Slack's API "
        + "using a bot token from a Slack app you create and own — nothing is ever "
        + "sent to the developer or any other server. The token is stored locally "
        + "with user-only file permissions."))

    private let masterCheckbox = NSButton(checkboxWithTitle:
        NSL("slack.master", "Send status to my Slack bot"),
        target: nil, action: nil)

    private let setupHelp = NSTextField(wrappingLabelWithString:
        NSL("slack.setup.help",
        "Setup: ① At api.slack.com/apps, create an app and add the chat:write bot "
        + "scope (add channels:read to look up channel names). ② Install it to your "
        + "workspace and copy the Bot User OAuth Token. ③ Invite the bot to the "
        + "channel with /invite @your-bot, then paste the token and channel below."))

    private let tokenLabel = NSTextField(labelWithString: NSL("slack.tokenLabel", "Bot token"))
    private let tokenField = NSSecureTextField(string: "")
    private let channelLabel = NSTextField(labelWithString: NSL("slack.channelLabel", "Channel"))
    private let channelField = NSTextField(string: "")
    private let lookupButton = NSButton(title: NSL("slack.lookup", "Look up ID"),
                                        target: nil, action: nil)

    private let eventsHeader = NSTextField(labelWithString:
        NSL("slack.eventsHeader", "Send a message when:"))
    private let safetyCheckbox = NSButton(checkboxWithTitle:
        NSL("slack.evtSafety", "A safety guard releases sleep (battery · heat · timer)"),
        target: nil, action: nil)
    private let endCheckbox = NSButton(checkboxWithTitle:
        NSL("slack.evtEnd", "Work ends — agents go idle or the remote session ends"),
        target: nil, action: nil)
    private let startCheckbox = NSButton(checkboxWithTitle:
        NSL("slack.evtStart", "Work starts — an agent or remote session begins"),
        target: nil, action: nil)
    private let digestCheckbox = NSButton(checkboxWithTitle:
        NSL("slack.evtDigest", "Periodic status while working, every"),
        target: nil, action: nil)
    private let digestPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// 마지막 비-off 다이제스트 간격 — 체크박스 off→on 복원용.
    private static let lastDigestChoiceKey = "slackPane.lastDigestChoice"

    private let testButton = NSButton(title: NSL("slack.sendTest", "Send Test Message"),
                                      target: nil, action: nil)
    private let resultLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        root.autoresizingMask = [.width, .height]

        privacyLabel.font = NSFont.systemFont(ofSize: 11)
        privacyLabel.textColor = .secondaryLabelColor
        privacyLabel.preferredMaxLayoutWidth = 460

        masterCheckbox.font = NSFont.boldSystemFont(ofSize: 13)
        masterCheckbox.target = self
        masterCheckbox.action = #selector(controlChanged)
        let masterTip = NSL("slack.tip.master",
            "The master switch. Off means Electronic Clam sends nothing to Slack at all. Setup fields and the test button below stay usable so you can wire things up first.")
        masterCheckbox.toolTip = masterTip

        setupHelp.font = NSFont.systemFont(ofSize: 11)
        setupHelp.textColor = .secondaryLabelColor
        setupHelp.preferredMaxLayoutWidth = 460

        tokenField.placeholderString = "xoxb-…"
        tokenField.delegate = self
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let tokenTip = NSL("slack.tip.token",
            "The Bot User OAuth Token from your Slack app (starts with xoxb-). It authenticates *your* app — keep it private. Stored on this Mac only (user-readable file), never logged.")
        tokenField.toolTip = tokenTip
        tokenLabel.toolTip = tokenTip

        channelField.placeholderString = "#general"
        channelField.delegate = self
        channelField.translatesAutoresizingMaskIntoConstraints = false
        channelField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        lookupButton.target = self
        lookupButton.action = #selector(lookupTapped)
        let lookupTip = NSL("slack.tip.lookup",
            "Turns the channel name into the channel ID Slack prefers. The bot must already be in the channel — invite it with /invite @your-bot. You can also paste a channel ID (C…) directly.")
        lookupButton.toolTip = lookupTip
        channelField.toolTip = lookupTip
        channelLabel.toolTip = lookupTip

        eventsHeader.font = NSFont.boldSystemFont(ofSize: 13)

        safetyCheckbox.target = self
        safetyCheckbox.action = #selector(controlChanged)
        safetyCheckbox.toolTip = NSL("slack.tip.evtSafety",
            "The message you most want when away: a guard just released sleep, so the Mac may go to sleep soon — battery low, overheating, or the max-awake timer.")
        endCheckbox.target = self
        endCheckbox.action = #selector(controlChanged)
        endCheckbox.toolTip = NSL("slack.tip.evtEnd",
            "Fires when the last working agent goes idle or a remote session ends. Episodes shorter than a minute are skipped to avoid noise.")
        startCheckbox.target = self
        startCheckbox.action = #selector(controlChanged)
        startCheckbox.toolTip = NSL("slack.tip.evtStart",
            "Fires when an agent or remote session starts holding the Mac awake. Off by default — it can get chatty. Throttled to one message per 5 minutes.")

        let digestTip = NSL("slack.tip.evtDigest",
            "A heartbeat while something is keeping the Mac awake: a status message at this interval, so a missing heartbeat tells you the Mac or network died. Slack has no silent delivery, so mute the channel if you want it quiet. Stops the moment work ends.")
        digestCheckbox.target = self
        digestCheckbox.action = #selector(controlChanged)
        digestCheckbox.toolTip = digestTip
        digestPopup.target = self
        digestPopup.action = #selector(controlChanged)
        digestPopup.removeAllItems()
        digestPopup.addItems(withTitles: SlackSupport.digestIntervalChoices.map {
            NSLf("duration.minutes", "%d min", $0)
        })
        digestPopup.toolTip = digestTip

        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.toolTip = NSL("slack.tip.sendTest",
            "Sends one test message with the current status line. Works even while the master switch is off, so you can verify the wiring first.")

        resultLabel.font = NSFont.systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.maximumNumberOfLines = 2
        resultLabel.preferredMaxLayoutWidth = 460

        // 필드 그리드 — 라벨 우측 정렬을 위해 NSGridView.
        let grid = NSGridView(views: [
            [tokenLabel, tokenField],
            [channelLabel, NSStackView(views: [channelField, lookupButton])],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        let digestRow = NSStackView(views: [digestCheckbox, digestPopup, InfoButton(digestTip)])
        digestRow.orientation = .horizontal
        digestRow.alignment = .firstBaseline
        digestRow.spacing = 6

        let eventsStack = NSStackView(views: [
            InfoButton.wrap(safetyCheckbox, safetyCheckbox.toolTip ?? ""),
            InfoButton.wrap(endCheckbox, endCheckbox.toolTip ?? ""),
            InfoButton.wrap(startCheckbox, startCheckbox.toolTip ?? ""),
            digestRow,
        ])
        eventsStack.orientation = .vertical
        eventsStack.alignment = .leading
        eventsStack.spacing = 6
        eventsStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let testRow = NSStackView(views: [testButton, resultLabel])
        testRow.orientation = .horizontal
        testRow.alignment = .firstBaseline
        testRow.spacing = 10

        let stack = NSStackView(views: [
            privacyLabel,
            InfoButton.wrap(masterCheckbox, masterTip),
            setupHelp,
            grid,
            eventsHeader,
            eventsStack,
            testRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: privacyLabel)
        stack.setCustomSpacing(12, after: setupHelp)
        stack.setCustomSpacing(16, after: grid)
        stack.setCustomSpacing(16, after: eventsStack)
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

    // MARK: - store ↔ controls

    func refresh() {
        let s = notifier.settings
        masterCheckbox.state = s.enabled ? .on : .off
        // 편집 중이 아닐 때만 필드 동기화 — 입력 중 덮어쓰기 방지.
        if tokenField.currentEditor() == nil, tokenField.stringValue != s.botToken {
            tokenField.stringValue = s.botToken
        }
        if channelField.currentEditor() == nil, channelField.stringValue != s.channel {
            channelField.stringValue = s.channel
        }
        safetyCheckbox.state = s.notifySafety ? .on : .off
        endCheckbox.state = s.notifyAwakeEnd ? .on : .off
        startCheckbox.state = s.notifyAwakeStart ? .on : .off
        digestCheckbox.state = s.digestIntervalMin > 0 ? .on : .off
        let shown = s.digestIntervalMin > 0 ? s.digestIntervalMin : lastDigestChoice()
        if let idx = SlackSupport.digestIntervalChoices.firstIndex(of: shown),
           digestPopup.indexOfSelectedItem != idx {
            digestPopup.selectItem(at: idx)
        }
        syncEnabled()
    }

    /// 이벤트 체크박스만 master 종속 (헤더 주석 참고).
    private func syncEnabled() {
        let on = masterCheckbox.state == .on
        safetyCheckbox.isEnabled = on
        endCheckbox.isEnabled = on
        startCheckbox.isEnabled = on
        digestCheckbox.isEnabled = on
        digestPopup.isEnabled = on && digestCheckbox.state == .on
    }

    /// 마지막 비-off 다이제스트 간격. 기본 30분.
    private func lastDigestChoice() -> Int {
        let v = UserDefaults.standard.integer(forKey: Self.lastDigestChoiceKey)
        return SlackSupport.digestIntervalChoices.contains(v) ? v : 30
    }

    /// 컨트롤 → 설정 저장. 모든 변경 경로가 이 한 곳을 거친다.
    private func commit() {
        let digestOn = digestCheckbox.state == .on
        let idx = digestPopup.indexOfSelectedItem
        let chosen = SlackSupport.digestIntervalChoices.indices.contains(idx)
            ? SlackSupport.digestIntervalChoices[idx] : lastDigestChoice()
        if digestOn {
            UserDefaults.standard.set(chosen, forKey: Self.lastDigestChoiceKey)
        }
        let next = SlackSettings(
            enabled: masterCheckbox.state == .on,
            botToken: tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            channel: SlackSupport.normalizeChannel(channelField.stringValue),
            notifyAwakeStart: startCheckbox.state == .on,
            notifyAwakeEnd: endCheckbox.state == .on,
            notifySafety: safetyCheckbox.state == .on,
            digestIntervalMin: digestOn ? chosen : 0)
        notifier.update(settings: next)
        syncEnabled()
    }

    @objc private func controlChanged() { commit() }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    // MARK: - Lookup / Test

    @objc private func lookupTapped() {
        commit()
        setResult(NSL("slack.result.looking", "Looking for that channel…"), isError: false)
        lookupButton.isEnabled = false
        notifier.lookupChannelId { [weak self] channelId, error in
            guard let self = self else { return }
            self.lookupButton.isEnabled = true
            if let channelId = channelId {
                self.channelField.stringValue = channelId
                self.commit()
                self.setResult(NSL("slack.result.found", "✓ Channel ID found"), isError: false)
            } else {
                self.setResult(error ?? "?", isError: true)
            }
        }
    }

    @objc private func testTapped() {
        commit()
        setResult(NSL("slack.result.sending", "Sending…"), isError: false)
        testButton.isEnabled = false
        notifier.sendTest { [weak self] error in
            guard let self = self else { return }
            self.testButton.isEnabled = true
            if let error = error {
                self.setResult(error, isError: true)
            } else {
                self.setResult(NSL("slack.result.sent", "✓ Sent — check your Slack channel"), isError: false)
            }
        }
    }

    private func setResult(_ text: String, isError: Bool) {
        resultLabel.stringValue = text
        resultLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        if isError { log.notice("slack pane: \(text, privacy: .public)") }
    }
}
