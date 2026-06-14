import AppKit
import OSLog

/// Settings → Notifications pane. ADR-0028 surface.
///
/// 구성 (위에서 아래로):
///   프라이버시 고지 — 이 기능이 어디로 무엇을 보내는지 명시 (egress 원칙)
///   ☑ master — "내 텔레그램 봇으로 상태 보내기"
///   설정 필드 — 토큰(secure)·chat ID·[Detect]
///   이벤트 체크박스 3개 — 안전 해제 / 작업 종료(idle) / 작업 시작
///   [테스트 전송] + 결과 라벨
///
/// 설정 필드·Detect·테스트는 master OFF 여도 활성 — "켜기 전에 배선부터
/// 확인"하는 온보딩 흐름이 자연스럽다 (sendTest 가 게이트를 우회하는 이유).
/// 이벤트 체크박스만 master 에 종속.
final class TelegramPaneViewController: NSViewController, NSTextFieldDelegate {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "settings")
    private let notifier = TelegramNotifier.shared

    private let privacyLabel = NSTextField(wrappingLabelWithString:
        NSL("telegram.privacy",
        "Off by default. When enabled, status messages go only to Telegram's API "
        + "using a bot token you create and own — nothing is ever sent to the "
        + "developer or any other server. The token is stored locally with "
        + "user-only file permissions."))

    private let masterCheckbox = NSButton(checkboxWithTitle:
        NSL("telegram.master", "Send status to my Telegram bot"),
        target: nil, action: nil)

    private let setupHelp = NSTextField(wrappingLabelWithString:
        NSL("telegram.setup.help",
        "Setup: ① In Telegram, message @BotFather → /newbot and copy the token. "
        + "② Send any message to your new bot. ③ Paste the token below and click Detect."))

    private let tokenLabel = NSTextField(labelWithString: NSL("telegram.tokenLabel", "Bot token"))
    private let tokenField = NSSecureTextField(string: "")
    private let chatIdLabel = NSTextField(labelWithString: NSL("telegram.chatIdLabel", "Chat ID"))
    private let chatIdField = NSTextField(string: "")
    private let detectButton = NSButton(title: NSL("telegram.detect", "Detect"),
                                        target: nil, action: nil)

    private let eventsHeader = NSTextField(labelWithString:
        NSL("telegram.eventsHeader", "Send a message when:"))
    private let safetyCheckbox = NSButton(checkboxWithTitle:
        NSL("telegram.evtSafety", "A safety guard releases sleep (battery · heat · timer)"),
        target: nil, action: nil)
    private let endCheckbox = NSButton(checkboxWithTitle:
        NSL("telegram.evtEnd", "Work ends — agents go idle or the remote session ends"),
        target: nil, action: nil)
    private let startCheckbox = NSButton(checkboxWithTitle:
        NSL("telegram.evtStart", "Work starts — an agent or remote session begins"),
        target: nil, action: nil)
    private let digestCheckbox = NSButton(checkboxWithTitle:
        NSL("telegram.evtDigest", "Periodic status while working (silent), every"),
        target: nil, action: nil)
    private let digestPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// 마지막 비-off 다이제스트 간격 — 체크박스 off→on 복원용
    /// (RemotePane lastChoice 패턴). 데이터 모델 밖, 패널 로컬.
    private static let lastDigestChoiceKey = "telegramPane.lastDigestChoice"

    private let testButton = NSButton(title: NSL("telegram.sendTest", "Send Test Message"),
                                      target: nil, action: nil)
    private let resultLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        root.autoresizingMask = [.width, .height]   // fill the tab (see AgentsPane note)

        privacyLabel.font = NSFont.systemFont(ofSize: 11)
        privacyLabel.textColor = .secondaryLabelColor
        privacyLabel.preferredMaxLayoutWidth = 460

        masterCheckbox.font = NSFont.boldSystemFont(ofSize: 13)
        masterCheckbox.target = self
        masterCheckbox.action = #selector(controlChanged)
        let masterTip = NSL("telegram.tip.master",
            "The master switch. Off means Electronic Clam sends nothing over the network at all. Setup fields and the test button below stay usable so you can wire things up first.")
        masterCheckbox.toolTip = masterTip

        setupHelp.font = NSFont.systemFont(ofSize: 11)
        setupHelp.textColor = .secondaryLabelColor
        setupHelp.preferredMaxLayoutWidth = 460

        tokenField.placeholderString = "123456789:ABC…"
        tokenField.delegate = self
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let tokenTip = NSL("telegram.tip.token",
            "The token @BotFather gave you. It authenticates *your* bot — keep it private. Stored on this Mac only (user-readable file), never logged.")
        tokenField.toolTip = tokenTip
        tokenLabel.toolTip = tokenTip

        chatIdField.placeholderString = "e.g. 123456789"
        chatIdField.delegate = self
        chatIdField.translatesAutoresizingMaskIntoConstraints = false
        chatIdField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        detectButton.target = self
        detectButton.action = #selector(detectTapped)
        let detectTip = NSL("telegram.tip.detect",
            "Looks up the chat ID automatically: send any message to your bot in Telegram first, then click Detect.")
        detectButton.toolTip = detectTip
        chatIdField.toolTip = detectTip
        chatIdLabel.toolTip = detectTip

        eventsHeader.font = NSFont.boldSystemFont(ofSize: 13)

        safetyCheckbox.target = self
        safetyCheckbox.action = #selector(controlChanged)
        safetyCheckbox.toolTip = NSL("telegram.tip.evtSafety",
            "The message you most want when away: a guard just released sleep, so the Mac may go to sleep soon — battery low, overheating, or the max-awake timer.")
        endCheckbox.target = self
        endCheckbox.action = #selector(controlChanged)
        endCheckbox.toolTip = NSL("telegram.tip.evtEnd",
            "Fires when the last working agent goes idle or a remote session ends. Episodes shorter than a minute are skipped to avoid noise.")
        startCheckbox.target = self
        startCheckbox.action = #selector(controlChanged)
        startCheckbox.toolTip = NSL("telegram.tip.evtStart",
            "Fires when an agent or remote session starts holding the Mac awake. Off by default — it can get chatty. Throttled to one message per 5 minutes.")

        let digestTip = NSL("telegram.tip.evtDigest",
            "A heartbeat while something is keeping the Mac awake: a silent status message (no sound, no banner) at this interval, so a missing heartbeat tells you the Mac or network died. Stops the moment work ends.")
        digestCheckbox.target = self
        digestCheckbox.action = #selector(controlChanged)
        digestCheckbox.toolTip = digestTip
        digestPopup.target = self
        digestPopup.action = #selector(controlChanged)
        digestPopup.removeAllItems()
        digestPopup.addItems(withTitles: TelegramSupport.digestIntervalChoices.map {
            NSLf("duration.minutes", "%d min", $0)
        })
        digestPopup.toolTip = digestTip

        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.toolTip = NSL("telegram.tip.sendTest",
            "Sends one test message with the current status line. Works even while the master switch is off, so you can verify the wiring first.")

        resultLabel.font = NSFont.systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.maximumNumberOfLines = 2
        resultLabel.preferredMaxLayoutWidth = 460

        // 필드 그리드 — 라벨 우측 정렬을 위해 NSGridView.
        let grid = NSGridView(views: [
            [tokenLabel, tokenField],
            [chatIdLabel, NSStackView(views: [chatIdField, detectButton])],
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
        if chatIdField.currentEditor() == nil, chatIdField.stringValue != s.chatId {
            chatIdField.stringValue = s.chatId
        }
        safetyCheckbox.state = s.notifySafety ? .on : .off
        endCheckbox.state = s.notifyAwakeEnd ? .on : .off
        startCheckbox.state = s.notifyAwakeStart ? .on : .off
        digestCheckbox.state = s.digestIntervalMin > 0 ? .on : .off
        // off 여도 팝업은 복원될 값을 보여준다 (RemotePane 패턴).
        let shown = s.digestIntervalMin > 0 ? s.digestIntervalMin : lastDigestChoice()
        if let idx = TelegramSupport.digestIntervalChoices.firstIndex(of: shown),
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
        return TelegramSupport.digestIntervalChoices.contains(v) ? v : 30
    }

    /// 컨트롤 → 설정 저장. 모든 변경 경로(체크박스·필드 편집 종료·버튼)가
    /// 이 한 곳을 거친다.
    private func commit() {
        let digestOn = digestCheckbox.state == .on
        let idx = digestPopup.indexOfSelectedItem
        let chosen = TelegramSupport.digestIntervalChoices.indices.contains(idx)
            ? TelegramSupport.digestIntervalChoices[idx] : lastDigestChoice()
        if digestOn {
            UserDefaults.standard.set(chosen, forKey: Self.lastDigestChoiceKey)
        }
        let next = TelegramSettings(
            enabled: masterCheckbox.state == .on,
            botToken: tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            chatId: chatIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            notifyAwakeStart: startCheckbox.state == .on,
            notifyAwakeEnd: endCheckbox.state == .on,
            notifySafety: safetyCheckbox.state == .on,
            digestIntervalMin: digestOn ? chosen : 0)
        notifier.update(settings: next)
        syncEnabled()
    }

    @objc private func controlChanged() { commit() }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    // MARK: - Detect / Test

    @objc private func detectTapped() {
        commit()
        setResult(NSL("telegram.result.detecting", "Looking for your chat…"), isError: false)
        detectButton.isEnabled = false
        notifier.detectChatId { [weak self] chatId, error in
            guard let self = self else { return }
            self.detectButton.isEnabled = true
            if let chatId = chatId {
                self.chatIdField.stringValue = chatId
                self.commit()
                self.setResult(NSL("telegram.result.detected", "✓ Chat ID detected"), isError: false)
            } else {
                self.setResult(error ?? "?", isError: true)
            }
        }
    }

    @objc private func testTapped() {
        commit()
        setResult(NSL("telegram.result.sending", "Sending…"), isError: false)
        testButton.isEnabled = false
        notifier.sendTest { [weak self] error in
            guard let self = self else { return }
            self.testButton.isEnabled = true
            if let error = error {
                self.setResult(error, isError: true)
            } else {
                self.setResult(NSL("telegram.result.sent", "✓ Sent — check your Telegram"), isError: false)
            }
        }
    }

    private func setResult(_ text: String, isError: Bool) {
        resultLabel.stringValue = text
        resultLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        if isError { log.notice("telegram pane: \(text, privacy: .public)") }
    }
}
