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
    /// ADR-0032 — "Open at Login" toggle. State is the live `SMAppService.mainApp`
    /// status (not a StateStore mirror); `renderLoginItemRow()` reflects it on show
    /// and on app reactivation so a System Settings change tracks without relaunch.
    private let loginItemCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Inline guidance shown only when the OS reports `.requiresApproval` — the
    /// user disabled the entry in System Settings, so `register()` won't force it.
    private let loginItemNote = NSTextField(wrappingLabelWithString: "")
    /// ADR-0035 — notify-only update controls. The link button runs a manual
    /// check; the checkbox is an opt-out for the daily background check
    /// (`renderUpdatesRow()` syncs it from `UpdateChecker.autoCheckEnabled`).
    private let checkUpdatesButton = NSButton(title: "", target: nil, action: nil)
    private let autoCheckUpdatesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
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
    /// P1-a (handoff 2026-06-24) — registration 은 `.enabled` 인데 helper 가
    /// XPC 에 응답 안 함("죽었는데 enabled"). `store.helperUnreachable && .enabled`
    /// 일 때만 표시; 위 Reinstall Helper 액션으로 안내한다.
    private let helperUnreachableNote = NSTextField(wrappingLabelWithString: "")
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

        // ADR-0032 — "Open at Login". Form-row grammar (label↔control) so the
        // checkbox's left edge aligns with the two popups above.
        loginItemCheckbox.translatesAutoresizingMaskIntoConstraints = false
        loginItemCheckbox.title = NSL("general.openAtLogin", "Open at login")
        loginItemCheckbox.target = self
        loginItemCheckbox.action = #selector(loginItemToggled)
        let loginItemTip = NSL("general.tip.openAtLogin",
            "Launch Electronic Clam automatically when you log in, so it's always watching in the menu bar. You can also manage this in System Settings → General → Login Items.")
        loginItemCheckbox.toolTip = loginItemTip
        let startupRow = Self.formRow(NSL("general.startup", "Startup"), control: loginItemCheckbox)

        loginItemNote.translatesAutoresizingMaskIntoConstraints = false
        loginItemNote.font = NSFont.systemFont(ofSize: 11)
        loginItemNote.textColor = .systemOrange
        loginItemNote.isSelectable = false
        loginItemNote.isHidden = true   // renderLoginItemRow() 가 상태에 맞게 갱신

        // ADR-0035 — notify-only "Check for Updates" (no Sparkle/auto-install).
        // A link-style action + an opt-out auto-check toggle, stacked under the
        // "Updates" form label.
        let updatesTip = NSL("general.tip.updates",
            "Checks GitHub for a newer release and tells you if one is available — it never downloads or installs automatically. Turn off the checkbox to stop the daily background check.")
        checkUpdatesButton.title = NSL("general.checkForUpdates", "Check for Updates…")
        checkUpdatesButton.translatesAutoresizingMaskIntoConstraints = false
        checkUpdatesButton.bezelStyle = .inline
        checkUpdatesButton.isBordered = false
        checkUpdatesButton.contentTintColor = .linkColor
        checkUpdatesButton.font = NSFont.systemFont(ofSize: 13)
        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkForUpdatesTapped)
        checkUpdatesButton.toolTip = updatesTip
        autoCheckUpdatesCheckbox.title = NSL("general.autoCheckUpdates", "Automatically check")
        autoCheckUpdatesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoCheckUpdatesCheckbox.target = self
        autoCheckUpdatesCheckbox.action = #selector(autoCheckUpdatesToggled)
        autoCheckUpdatesCheckbox.toolTip = updatesTip
        let updatesControls = NSStackView(views: [checkUpdatesButton, autoCheckUpdatesCheckbox])
        updatesControls.orientation = .vertical
        updatesControls.alignment = .leading
        updatesControls.spacing = 4
        let updatesRow = Self.formRow(NSL("general.updates", "Updates"), control: updatesControls)

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

        // P1-a — helper 도달 불가 경고 (registered 인데 XPC 무응답).
        helperUnreachableNote.translatesAutoresizingMaskIntoConstraints = false
        helperUnreachableNote.font = NSFont.systemFont(ofSize: 11)
        helperUnreachableNote.textColor = .systemOrange
        helperUnreachableNote.isSelectable = false
        helperUnreachableNote.isHidden = true   // renderPermissionRow() 가 상태에 맞게 갱신

        let formSeparator = Self.separator()
        // 권한 줄들에 보이는 ⓘ(클릭 팝오버) 부착 — hover toolTip과 같은 문자열
        // (2026-06-11 사용자 피드백: hover 전용 도움말은 발견 불가).
        let statusRow = InfoButton.wrap(permissionStatusLabel, statusTip)
        let permissionRow = InfoButton.wrap(permissionButton, permissionTip)
        let reinstallRow = InfoButton.wrap(reinstallButton, reinstallTip)
        let diagnosticsRow = InfoButton.wrap(exportDiagnosticsButton, diagnosticsTip)
        let settingsStack = NSStackView(views: [
            languageRow, themeRow, startupRow, loginItemNote, updatesRow,
            formSeparator,
            permissionHeader,
            statusRow, permissionRow, reinstallRow, diagnosticsRow,
            helperUnavailableNote, versionMismatchNote, helperUnreachableNote,
        ])
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 8
        // ADR-0035 — updatesRow is now the last item in the form zone, so it owns
        // the 20pt group gap to the divider. startupRow/loginItemNote keep the
        // default 8pt form spacing (loginItemNote collapses when hidden, harmless
        // now that it's no longer the element before the divider).
        settingsStack.setCustomSpacing(20, after: updatesRow)
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
            helperUnreachableNote.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
            loginItemNote.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
        ])
        self.view = container
        renderStatusCard()
        renderPermissionRow()
        renderLoginItemRow()
        renderUpdatesRow()
    }

    /// Re-sync the popups + permission row (called by SettingsWindowController on
    /// show and on app reactivation via `refreshGeneralPane`).
    func refresh() {
        languagePopup.selectItem(at: AppLanguage.currentIndex)
        themePopup.selectItem(at: themeOrder.firstIndex(of: store.menuBarTheme) ?? 0)
        renderStatusCard()
        renderPermissionRow()
        renderLoginItemRow()
        renderUpdatesRow()
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

        // P1-a — registered (.enabled) 인데 helper 가 XPC 무응답. version
        // mismatch 와 달리 *등록이 enabled 인 경우에만* 의미가 있다 (미등록/미승인은
        // 위 상태줄이 이미 설명). 둘 다 같은 Reinstall Helper 로 복구.
        var helperUnreachable = false
        if case .enabled = store.registration { helperUnreachable = store.helperUnreachable }
        helperUnreachableNote.isHidden = !helperUnreachable
        if helperUnreachable {
            helperUnreachableNote.stringValue = "⚠\u{FE0E} "
                + NSL("permission.helperUnreachable.warning",
                    "The helper is registered but not responding, so keep-awake is silently not working.")
                + " "
                + NSL("permission.helperUnreachable.reinstall",
                    "Click \"Reinstall Helper\" to recover.")
        }
    }

    /// ADR-0032 — reflect the live `SMAppService.mainApp` status into the
    /// checkbox. `.requiresApproval` (user disabled the entry in System Settings)
    /// surfaces an inline note pointing back at the Login Items pane, since
    /// `register()` won't override that explicit choice.
    private func renderLoginItemRow() {
        let status = LoginItem.status
        loginItemCheckbox.state = (status == .enabled) ? .on : .off
        let needsApproval = (status == .requiresApproval)
        loginItemNote.isHidden = !needsApproval
        if needsApproval {
            loginItemNote.stringValue = "⚠\u{FE0E} " + NSL("general.openAtLogin.needsApproval",
                "Electronic Clam is turned off in System Settings → General → Login Items. Switch it on there to launch at login.")
        }
    }

    /// ADR-0035 — sync the auto-check toggle to the persisted opt-out flag.
    private func renderUpdatesRow() {
        autoCheckUpdatesCheckbox.state = UpdateChecker.autoCheckEnabled ? .on : .off
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

    /// ADR-0020/0036 — explicit repair. Uses `forceReregister` (unregister →
    /// retry register) rather than the one-shot `reinstall()`: a `register()`
    /// immediately after `unregister()` EPERMs until BTM/launchd settles, which
    /// stranded the helper in `.notRegistered` (live-confirmed 2026-06-24). The
    /// retry rides out the settle window, so it can block several seconds — run
    /// off-main to avoid a beachball; the disabled button signals "in progress".
    @objc private func reinstallTapped() {
        reinstallButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, err) = HelperRegistration.forceReregister(timeout: 15)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reinstallButton.isEnabled = true
                self.store.update(registrationStatus: status, registrationError: err)
                self.renderPermissionRow()
            }
        }
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

    /// ADR-0032 — register/unregister the app as a login item. If macOS reports
    /// `.requiresApproval` (the user previously disabled it), `register()` can't
    /// force it on, so we open the Login Items pane and surface the inline note.
    @objc private func loginItemToggled() {
        let wantEnabled = (loginItemCheckbox.state == .on)
        let (status, _) = LoginItem.setEnabled(wantEnabled)
        if wantEnabled && status == .requiresApproval {
            HelperRegistration.openLoginItemsSettings()
        }
        renderLoginItemRow()   // reconcile the checkbox to the OS's actual answer
    }

    /// ADR-0035 — manual update check. Notify-only: shows the result in an alert;
    /// "Download" opens the releases page in the browser (never auto-installs).
    @objc private func checkForUpdatesTapped() {
        let original = NSL("general.checkForUpdates", "Check for Updates…")
        checkUpdatesButton.isEnabled = false
        checkUpdatesButton.title = NSL("update.checking", "Checking…")
        UpdateChecker.checkManually { [weak self] result in
            guard let self = self else { return }
            self.checkUpdatesButton.isEnabled = true
            self.checkUpdatesButton.title = original
            let alert = NSAlert()
            switch result {
            case .upToDate(let current):
                alert.alertStyle = .informational
                alert.messageText = NSL("update.upToDate", "You're up to date")
                alert.informativeText = NSLf("update.upToDate.body",
                                             "You have the latest version (%@).", current)
                alert.addButton(withTitle: NSL("common.ok", "OK"))
            case .updateAvailable(let latest, let current, let page):
                alert.alertStyle = .informational
                alert.messageText = NSL("update.available", "Update available")
                alert.informativeText = NSLf("update.available.body",
                                             "Version %@ is available — you have %@.", latest, current)
                alert.addButton(withTitle: NSL("update.download", "Download"))
                alert.addButton(withTitle: NSL("update.later", "Later"))
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(page)
                }
                return
            case .failed:
                alert.alertStyle = .warning
                alert.messageText = NSL("update.failed", "Couldn't check for updates")
                alert.informativeText = NSL("update.failed.body",
                                            "Check your internet connection and try again.")
                alert.addButton(withTitle: NSL("common.ok", "OK"))
            }
            alert.runModal()
        }
    }

    /// ADR-0035 — opt-out toggle for the daily background update check.
    @objc private func autoCheckUpdatesToggled() {
        UpdateChecker.autoCheckEnabled = (autoCheckUpdatesCheckbox.state == .on)
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
