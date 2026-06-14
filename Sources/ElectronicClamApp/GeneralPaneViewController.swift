import AppKit
import OSLog

/// Settings → General pane (ADR-0024 layout).
///
/// Reorganized into three left-aligned zones instead of the former centered
/// "About hero over settings" stack:
///   1. Two-column form  — Language / Menu Bar Icon (HIG label↔control rows).
///   2. Permission section (ADR-0018) — bold header + status + actions.
///   3. About footer — compact icon/name/version + repo & funding links, pinned
///      to the bottom so identity reads as a footer, not a splash header.
/// Separators (`NSBox`) and 20pt group spacing delineate the zones (HIG §Settings).
/// Language selector ADR-0011 §C; funding placement ADR-0019.
final class GeneralPaneViewController: NSViewController {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "settings")
    private let store: StateStore
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Theme popup row order — index maps to this array, not `allCases`.
    private let themeOrder: [StateStore.MenuBarTheme] = [.system, .light, .dark]
    /// Called after the language is changed so the app can re-render live.
    private let onLanguageChanged: () -> Void
    /// ADR-0018 — permission status row. The label + link-style button are
    /// re-rendered by `renderPermissionRow()` from `store.registration` on show
    /// and on app reactivation (so returning from System Settings updates them).
    private let permissionStatusLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    /// ADR-0020 — explicit "Reinstall Helper" recovery (unregister→register).
    private let reinstallButton = NSButton(title: "", target: nil, action: nil)
    /// ADR-0020 업그레이드 트랩 안내 노트. helper가 unavailable(.notFound /
    /// .notRegistered / .registerThrew)일 때만 표시; .enabled / .requiresApproval 때는
    /// 숨긴다 (.requiresApproval은 기존 상태줄 + Open Settings 버튼으로 충분).
    private let helperUnavailableNote = NSTextField(wrappingLabelWithString: "")
    /// v0.5 P1 — 버전 핸드셰이크 불일치 경고 (구버전 daemon 잔존).
    /// `store.helperVersionMismatch` 가 true 일 때만 표시; Reinstall Helper
    /// 액션으로 안내한다.
    private let versionMismatchNote = NSTextField(wrappingLabelWithString: "")
    /// proposal §2 — 진단 번들 내보내기 버튼.
    private let exportDiagnosticsButton = NSButton(title: "", target: nil, action: nil)

    // 상태 카드 (user feedback 2026-06-12: 일반 탭이 너무 심심함). 상단에 현재
    // 켜짐/꺼짐 + 헬퍼 권한을 한눈에. `renderStatusCard()`가 `store`에서 갱신.
    private let statusDot = MenuStatusHeaderView.StatusDotView()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusHelper = NSTextField(labelWithString: "")

    /// Rounded "card" panel — drawn (not layer-backed) so the fill/border resolve
    /// against the effective appearance on every redraw.
    private final class CardView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 10, yRadius: 10)
            border.lineWidth = 1
            border.stroke()
        }
    }

    init(store: StateStore, onLanguageChanged: @escaping () -> Void) {
        self.store = store
        self.onLanguageChanged = onLanguageChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        container.autoresizingMask = [.width, .height]   // fill the tab (see AgentsPane note)

        // MARK: 1. Two-column form — Language / Menu Bar Icon.

        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.addItems(withTitles: AppLanguage.options.map(\.nativeName))
        languagePopup.selectItem(at: AppLanguage.currentIndex)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        themePopup.translatesAutoresizingMaskIntoConstraints = false
        themePopup.addItems(withTitles: themeOrder.map(Self.themeTitle))
        themePopup.selectItem(at: themeOrder.firstIndex(of: store.menuBarTheme) ?? 0)
        themePopup.target = self
        themePopup.action = #selector(themeChanged)

        let languageRow = Self.formRow(NSL("general.language", "Language"), control: languagePopup)
        let themeRow = Self.formRow(NSL("general.menuBarTheme", "Menu Bar Icon"), control: themePopup)

        // MARK: 2. Permission section (ADR-0018).

        let permissionHeader = Self.sectionHeader(NSL("permission.section", "Permission"),
                                                  symbol: "lock.shield")
        permissionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        permissionStatusLabel.font = NSFont.systemFont(ofSize: 12)
        permissionStatusLabel.alignment = .left
        let statusTip = NSL("general.tip.permissionStatus",
            "Whether macOS allows Electronic Clam's background helper to run. The helper is the part that actually controls sleep.")
        permissionStatusLabel.toolTip = statusTip
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        permissionButton.bezelStyle = .inline
        permissionButton.isBordered = false
        permissionButton.contentTintColor = .linkColor
        permissionButton.font = NSFont.systemFont(ofSize: 12)
        permissionButton.target = self
        permissionButton.action = #selector(permissionButtonTapped)
        let permissionTip = NSL("general.tip.permissionButton",
            "Manages or repairs the helper permission — opens System Settings or retries registration, depending on the state above.")
        permissionButton.toolTip = permissionTip

        // ADR-0020 — link-style "Reinstall Helper" recovery, always available so a
        // wedged registration (e.g. requiresApproval limbo) can be repaired
        // without a relaunch. unregister→register; deeper LWCR mismatch still
        // needs reinstall/reboot.
        reinstallButton.title = NSL("permission.button.reinstallHelper", "Reinstall Helper")
        reinstallButton.translatesAutoresizingMaskIntoConstraints = false
        reinstallButton.bezelStyle = .inline
        reinstallButton.isBordered = false
        reinstallButton.contentTintColor = .linkColor
        reinstallButton.font = NSFont.systemFont(ofSize: 11)
        reinstallButton.target = self
        reinstallButton.action = #selector(reinstallTapped)
        let reinstallTip = NSL("general.tip.reinstallHelper",
            "Unregisters and re-registers the background helper. Use this when the helper stops responding after an upgrade or the permission state looks stuck. macOS may ask you to approve the helper again.")
        reinstallButton.toolTip = reinstallTip

        // proposal §2 — "Export Diagnostics…" 버튼 (Permission 섹션 하단).
        exportDiagnosticsButton.title = NSL("general.exportDiagnostics", "Export Diagnostics…")
        exportDiagnosticsButton.translatesAutoresizingMaskIntoConstraints = false
        exportDiagnosticsButton.bezelStyle = .inline
        exportDiagnosticsButton.isBordered = false
        exportDiagnosticsButton.contentTintColor = .linkColor
        exportDiagnosticsButton.font = NSFont.systemFont(ofSize: 11)
        exportDiagnosticsButton.target = self
        exportDiagnosticsButton.action = #selector(exportDiagnosticsTapped)
        let diagnosticsTip = NSL("general.tip.exportDiagnostics",
            "Saves a diagnostics bundle (recent logs, settings, helper status) to your Desktop — useful when filing a bug report.")
        exportDiagnosticsButton.toolTip = diagnosticsTip

        // ADR-0020 업그레이드 트랩 안내 노트.
        helperUnavailableNote.translatesAutoresizingMaskIntoConstraints = false
        helperUnavailableNote.font = NSFont.systemFont(ofSize: 11)
        helperUnavailableNote.textColor = .systemOrange
        helperUnavailableNote.isSelectable = false
        helperUnavailableNote.isHidden = true   // renderPermissionRow() 가 상태에 맞게 갱신

        // v0.5 P1 — 버전 핸드셰이크 불일치 경고 (구버전 daemon 잔존).
        versionMismatchNote.translatesAutoresizingMaskIntoConstraints = false
        versionMismatchNote.font = NSFont.systemFont(ofSize: 11)
        versionMismatchNote.textColor = .systemOrange
        versionMismatchNote.isSelectable = false
        versionMismatchNote.isHidden = true     // renderPermissionRow() 가 상태에 맞게 갱신

        let formSeparator = Self.separator()
        // 권한 줄들에 보이는 ⓘ(클릭 팝오버) 부착 — hover toolTip과 같은 문자열
        // (2026-06-11 사용자 피드백: hover 전용 도움말은 발견 불가).
        let statusRow = InfoButton.wrap(permissionStatusLabel, statusTip)
        let permissionRow = InfoButton.wrap(permissionButton, permissionTip)
        let reinstallRow = InfoButton.wrap(reinstallButton, reinstallTip)
        let diagnosticsRow = InfoButton.wrap(exportDiagnosticsButton, diagnosticsTip)
        let settingsStack = NSStackView(views: [
            languageRow, themeRow,
            formSeparator,
            permissionHeader,
            statusRow, permissionRow, reinstallRow, diagnosticsRow,
            helperUnavailableNote, versionMismatchNote,
        ])
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 8
        settingsStack.setCustomSpacing(20, after: themeRow)
        settingsStack.setCustomSpacing(20, after: formSeparator)
        settingsStack.setCustomSpacing(6, after: permissionHeader)
        settingsStack.setCustomSpacing(4, after: statusRow)
        settingsStack.setCustomSpacing(2, after: permissionRow)
        settingsStack.setCustomSpacing(2, after: reinstallRow)
        settingsStack.setCustomSpacing(6, after: diagnosticsRow)

        // MARK: 3. About footer — demoted from the former centered hero.

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        } else if let symbol = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Electronic Clam") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
            iconView.image = symbol.withSymbolConfiguration(cfg)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: "Electronic Clam")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
        let versionText = NSLf("general.version", "Version %@", version)
        let metaText = copyright.isEmpty ? versionText : "\(versionText)  ·  \(copyright)"
        let metaLabel = NSTextField(labelWithString: metaText)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor

        let linkButton = NSButton(title: "github.com/jadhvank/eclam", target: self, action: #selector(openRepo))
        linkButton.translatesAutoresizingMaskIntoConstraints = false
        linkButton.bezelStyle = .inline
        linkButton.isBordered = false
        linkButton.contentTintColor = .linkColor
        linkButton.font = NSFont.systemFont(ofSize: 11)

        // Support link — a single, unobtrusive Ko-fi link in the About footer. The
        // toggle menu stays function-only; funding lives here (ADR-0019).
        let supportButton = NSButton(title: NSL("general.support", "☕ Buy me a coffee"),
                                     target: self, action: #selector(openSupport))
        supportButton.translatesAutoresizingMaskIntoConstraints = false
        supportButton.bezelStyle = .inline
        supportButton.isBordered = false
        supportButton.contentTintColor = .linkColor
        supportButton.font = NSFont.systemFont(ofSize: 11)

        let identityRow = NSStackView(views: [iconView, nameLabel])
        identityRow.orientation = .horizontal
        identityRow.alignment = .centerY
        identityRow.spacing = 8

        let linksRow = NSStackView(views: [linkButton, supportButton])
        linksRow.orientation = .horizontal
        linksRow.alignment = .firstBaseline
        linksRow.spacing = 16

        let footerSeparator = Self.separator()
        let footerStack = NSStackView(views: [footerSeparator, identityRow, metaLabel, linksRow])
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 4
        footerStack.setCustomSpacing(12, after: footerSeparator)
        footerStack.setCustomSpacing(6, after: identityRow)
        footerStack.setCustomSpacing(8, after: metaLabel)

        // MARK: 0. Status card — at-a-glance on/off + helper permission.

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusTitle.translatesAutoresizingMaskIntoConstraints = false
        statusTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        statusTitle.lineBreakMode = .byTruncatingTail
        statusHelper.translatesAutoresizingMaskIntoConstraints = false
        statusHelper.font = NSFont.systemFont(ofSize: 11)
        statusHelper.textColor = .secondaryLabelColor
        let cardTitleRow = NSStackView(views: [statusDot, statusTitle])
        cardTitleRow.orientation = .horizontal
        cardTitleRow.alignment = .centerY
        cardTitleRow.spacing = 8
        let cardStack = NSStackView(views: [cardTitleRow, statusHelper])
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 4
        card.addSubview(cardStack)

        container.addSubview(card)
        container.addSubview(settingsStack)
        container.addSubview(footerStack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            statusDot.widthAnchor.constraint(equalToConstant: 12),
            statusDot.heightAnchor.constraint(equalToConstant: 12),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            cardStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),

            card.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            settingsStack.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 20),
            settingsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            settingsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            footerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            // Keep the footer below the settings zone; the resizable window has
            // ample height (min 480) so this never goes unsatisfiable.
            footerStack.topAnchor.constraint(greaterThanOrEqualTo: settingsStack.bottomAnchor, constant: 20),

            // Separators span their stack's (externally pinned) width — no
            // circularity because the stack width comes from the leading+trailing
            // pins above, not from its arranged subviews.
            formSeparator.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
            footerSeparator.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
            // Note wraps within the permission section width.
            helperUnavailableNote.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
            versionMismatchNote.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
        ])
        self.view = container
        renderStatusCard()
        renderPermissionRow()
    }

    /// Re-sync the popups + permission row (called by SettingsWindowController on
    /// show and on app reactivation via `refreshGeneralPane`).
    func refresh() {
        languagePopup.selectItem(at: AppLanguage.currentIndex)
        themePopup.selectItem(at: themeOrder.firstIndex(of: store.menuBarTheme) ?? 0)
        renderStatusCard()
        renderPermissionRow()
    }

    /// Status word + color for a registration state. Shared by the status card
    /// and the permission row so the two never drift.
    private static func permissionStatus(_ reg: StateStore.RegistrationView)
        -> (text: String, color: NSColor) {
        switch reg {
        case .enabled:
            return (NSL("permission.status.enabled", "Approved"), .systemGreen)
        case .requiresApproval:
            return (NSL("permission.status.requiresApproval", "Approval needed"), .systemOrange)
        case .notRegistered, .registerThrew:
            return (NSL("permission.status.notRegistered", "Not registered"), .systemOrange)
        case .notFound:
            return (NSL("permission.status.notFound", "Helper missing — reinstall"), .systemRed)
        case .unknown:
            return (NSL("permission.status.unknown", "Unknown state"), .secondaryLabelColor)
        }
    }

    /// Status card — on/off (from `store.sleepDisabled`) + helper permission.
    private func renderStatusCard() {
        let on = store.sleepDisabled
        statusDot.color = on ? .systemGreen : .systemGray
        statusTitle.stringValue = on
            ? NSL("general.statusCard.on", "Electronic Clam — On · staying awake")
            : NSL("general.statusCard.off", "Electronic Clam — Off · sleeps normally")
        let perm = Self.permissionStatus(store.registration)
        statusHelper.stringValue = NSLf("general.statusCard.helper", "Helper: %@", perm.text)
    }

    /// ADR-0018 — reflect `store.registration` into the status label + action
    /// button title. The button's behaviour is dispatched in `permissionButtonTapped`.
    /// ADR-0020 — 업그레이드 후 helper unavailable 상태면 인라인 안내 노트도 갱신.
    private func renderPermissionRow() {
        let (status, statusColor) = Self.permissionStatus(store.registration)
        let buttonTitle: String
        let showUpgradeNote: Bool
        switch store.registration {
        case .enabled:
            buttonTitle = NSL("permission.button.manage", "Manage in System Settings")
            showUpgradeNote = false
        case .requiresApproval:
            buttonTitle = NSL("permission.button.openSettings", "Open System Settings")
            // .requiresApproval: 기존 상태줄 + Open Settings 버튼으로 충분. 노트 중복 제외.
            showUpgradeNote = false
        case .notRegistered, .registerThrew:
            buttonTitle = NSL("permission.button.retry", "Register again")
            showUpgradeNote = true
        case .notFound:
            buttonTitle = NSL("permission.button.reinstall", "Reinstall help")
            showUpgradeNote = true
        case .unknown:
            buttonTitle = NSL("permission.button.retry", "Register again")
            showUpgradeNote = true
        }
        permissionStatusLabel.stringValue = "● " + status
        permissionStatusLabel.textColor = statusColor
        permissionButton.title = buttonTitle

        // ADR-0020 업그레이드 트랩 안내 — helper unavailable 상태일 때만 노출.
        helperUnavailableNote.isHidden = !showUpgradeNote
        if showUpgradeNote {
            helperUnavailableNote.stringValue =
                "⚠\u{FE0E} " + NSL("general.helperUnavailable.note",
                    "After an upgrade, macOS may refuse to relaunch the old helper (ad-hoc signing limitation). Click Reinstall Helper; if it still fails, restart your Mac.")
        }

        // v0.5 P1 — 버전 핸드셰이크 불일치 (살아있는 구버전 daemon 잔존).
        // 핸드셰이크가 liveness 까지 확인한 경우에만 true 이므로 등록 상태와
        // 무관하게 플래그만 본다.
        versionMismatchNote.isHidden = !store.helperVersionMismatch
        if store.helperVersionMismatch {
            versionMismatchNote.stringValue = "⚠\u{FE0E} "
                + NSL("permission.versionMismatch.warning",
                    "The helper that is running speaks an older protocol than this app — likely left over from an upgrade.")
                + " "
                + NSL("permission.versionMismatch.reinstall",
                    "Click \"Reinstall Helper\" to update it.")
        }
    }

    private static func themeTitle(_ theme: StateStore.MenuBarTheme) -> String {
        switch theme {
        case .system: return NSL("theme.system", "System")
        case .light:  return NSL("theme.light", "Light")
        case .dark:   return NSL("theme.dark", "Dark")
        }
    }

    // MARK: - Actions

    @objc private func openRepo() {
        if let url = URL(string: "https://github.com/jadhvank/eclam") {
            NSWorkspace.shared.open(url)
        }
    }

    /// ADR-0019 — funding lives in the About footer, not the toggle menu. One link
    /// to Ko-fi (PayPal-backed; the one funding rail that works from Korea).
    @objc private func openSupport() {
        if let url = URL(string: "https://ko-fi.com/jadhvank") {
            NSWorkspace.shared.open(url)
        }
    }

    /// ADR-0018 — permission action, dispatched on the current registration:
    /// approved/needs-approval → open the Login Items pane; not-registered →
    /// re-register in place; helper missing → repo (reinstall) link.
    @objc private func permissionButtonTapped() {
        switch store.registration {
        case .enabled, .requiresApproval:
            HelperRegistration.openLoginItemsSettings()
        case .notRegistered, .registerThrew, .unknown:
            let (status, err) = HelperRegistration.retry()
            store.update(registrationStatus: status, registrationError: err)
            renderPermissionRow()
        case .notFound:
            openRepo()
        }
    }

    /// ADR-0020 — explicit repair: unregister→register, then reflect new status.
    @objc private func reinstallTapped() {
        let (status, err) = HelperRegistration.reinstall()
        store.update(registrationStatus: status, registrationError: err)
        renderPermissionRow()
    }

    /// proposal §2 — 진단 번들 내보내기. 성공 시 Finder에서 파일 선택, 실패 시 NSAlert.
    @objc private func exportDiagnosticsTapped() {
        exportDiagnosticsButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = DiagnosticsExporter.export()
            DispatchQueue.main.async {
                self?.exportDiagnosticsButton.isEnabled = true
                if let url = url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = NSL("general.exportDiagnostics.failed",
                                           "Export failed")
                    alert.informativeText = NSL("general.exportDiagnostics.failed.body",
                                               "Could not create the diagnostics bundle. Check that ~/Desktop is writable and try again.")
                    alert.addButton(withTitle: NSL("common.ok", "OK"))
                    alert.runModal()
                }
            }
        }
    }

    @objc private func languageChanged() {
        let idx = languagePopup.indexOfSelectedItem
        guard idx >= 0, idx < AppLanguage.options.count else { return }
        let code = AppLanguage.options[idx].code
        guard code != AppLanguage.effectiveCode else { return }
        AppLanguage.setOverride(code)   // swaps AppLanguage.bundle live + persists
        // Re-render on the next runloop hop so this popup's action finishes before
        // the Settings window is rebuilt under it.
        DispatchQueue.main.async { [weak self] in self?.onLanguageChanged() }
    }

    @objc private func themeChanged() {
        let idx = themePopup.indexOfSelectedItem
        guard idx >= 0, idx < themeOrder.count else { return }
        // Fires store.onChange → AppDelegate → menuBar.refresh(), re-rendering
        // the glyph in the chosen theme immediately.
        store.setMenuBarTheme(themeOrder[idx])
    }

    // MARK: - Layout helpers

    /// HIG two-column row: a fixed-width, right-aligned heading label next to its
    /// control, baselines aligned. The 120pt column keeps the two popups' left
    /// edges aligned without an NSGridView.
    private static func formRow(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private static func sectionHeader(_ title: String, symbol: String? = nil) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = NSFont.boldSystemFont(ofSize: 13)
        guard let symbol,
              let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return l
        }
        let iv = NSImageView(image: img)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [iv, l])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}
