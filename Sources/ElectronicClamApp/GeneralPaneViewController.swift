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
    /// ADR-0037 — opt-in "클램쉘 잠금 방지" toggle. State is mirrored from
    /// `store.clamshellLockGuardEnabled`; `clamshellGuardToggled()` persists it via
    /// the StateStore setter (→ converge → VirtualDisplayController).
    private let clamshellGuardCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// ADR-0037 S3 §폴백 — VPN 끊김 알림 opt-in 체크박스(잠금 가드와 독립). State 는
    /// `store.vpnDisconnectNotifyEnabled` 미러; `vpnNotifyToggled()` 가 StateStore
    /// 세터로 영속(→ converge → VpnWatcher).
    private let vpnNotifyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// ADR-0037 S3 §폴백 — VPN 서비스 선택 팝업(자유 입력 → 드롭다운). `scutil --nc
    /// list` 의 표시 이름들로 채우고 선택 시 `store.setVpnServiceName` 으로 영속한다.
    /// 사용자가 이름을 오타내 "No service" 가 나던 문제를 아예 제거(못 고르게).
    /// `themePopup`/`blankModePopup` 과 동일한 popup idiom. `reloadVpnServices()` 가
    /// loadView·refresh·Refresh 버튼에서 채운다.
    private let vpnServicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 팝업을 `scutil --nc list` 로 다시 스캔하는 새로고침 버튼(VPN 앱이 꺼져 있다
    /// 켜졌을 때 등 — 패널이 떠 있는 동안 서비스 목록이 바뀔 수 있다).
    private let vpnRefreshButton = NSButton(title: "", target: nil, action: nil)
    /// VPN 안전망 동작 설명(잠금 가드 + Telegram opt-in 에 올라타며, 끊김 시 알림만 함).
    private let vpnServiceNote = NSTextField(wrappingLabelWithString: "")
    /// ADR-0037 §#8 — "Blank screen" 동작 모드 선택 (dim/sleep). State 는
    /// `store.blankDisplaysMode` 미러; `blankModeChanged()` 가 StateStore 세터로 영속.
    /// themePopup 과 동일한 popup form-row 패턴.
    private let blankModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Blank-mode popup row order — index maps to this array, not `allCases`.
    private let blankModeOrder: [StateStore.BlankDisplaysMode] = [.dim, .sleep]
    /// ADR-0037 §#8 — Sleep 선택 시에만 보이는 경고(화면 잠금→VPN 끊김). `.dim` 일 땐 숨김.
    private let blankModeNote = NSTextField(wrappingLabelWithString: "")
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
    /// ADR-0039 — split-brain(중복본)·설치 위치·버전 스큐 진단을 설정 화면에 노출
    /// (CLI `eclam status` 신호를 터미널 안 쓰는 유저에게도). mdfind/launchctl 을
    /// 도는 스캔이라 off-main 으로 수집(`refreshInstallHealth`) 후 메인에서 렌더한다.
    /// 문제가 없으면 숨김 — 정상 머신엔 노이즈 없음.
    private let installHealthNote = NSTextField(wrappingLabelWithString: "")
    /// ADR-0039 — "Reinstall Helper" 가 재등록 후에도 helper 를 못 살리면(죽은 BTM
    /// 레코드가 제거된/중복 복사본에 묶인 2026-07-01 사건), CLI `eclam repair` 가 주는
    /// 것과 같은 최후수단(`sudo sfltool resetbtm`)을 안내한다. 앱은 sudo 명령을 직접
    /// 실행할 수 없으므로(admin+터미널) 명령을 보여줄 뿐. `reinstallTapped` 가 실패
    /// 판정 시에만 표시; 기본 숨김(패널 재표시 시에도 숨김 — reinstall 액션 종속).
    private let resetBtmNote = NSTextField(wrappingLabelWithString: "")
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

        // ADR-0037 — opt-in "클램쉘 잠금 방지". 헤드리스 클램쉘(덮개 닫힘·외장
        // 없음)에서 보이지 않는 가상 디스플레이로 세션을 앵커해 화면 잠금을 막아
        // VPN(예: FortiClient) 연속성을 지킨다. 카피는 디스플레이 축이 아니라 VPN/
        // 세션 연속성 맥락(ADR-0037 §노출). loginItemCheckbox 와 같은 form-row 문법.
        clamshellGuardCheckbox.translatesAutoresizingMaskIntoConstraints = false
        clamshellGuardCheckbox.title = NSL("general.clamshellGuard",
            "Prevent lock in clamshell (keep VPN alive)")
        clamshellGuardCheckbox.target = self
        clamshellGuardCheckbox.action = #selector(clamshellGuardToggled)
        clamshellGuardCheckbox.state = store.clamshellLockGuardEnabled ? .on : .off
        clamshellGuardCheckbox.toolTip = NSL("general.tip.clamshellGuard",
            "When your Mac stays awake with the lid closed and no external display, "
            + "Electronic Clam keeps an invisible virtual display alive so macOS "
            + "doesn't lock the screen — a lock would drop VPN sessions like "
            + "FortiClient. No window appears and it draws essentially no power. "
            + "Off by default.")

        // ADR-0037 S3 — VPN 끊김 알림 opt-in. 잠금 가드와 **독립**된 토글이라(가드를
        // 안 켜도 끊김만 알리고 싶을 수 있다) 같은 "Sessions" 그룹에 세로로 묶되 별도
        // 체크박스로 둔다. updatesRow 가 한 라벨 아래 컨트롤 둘을 묶는 패턴과 동일.
        vpnNotifyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        vpnNotifyCheckbox.title = NSL("general.vpnNotify",
            "Notify when VPN disconnects (Telegram + local)")
        vpnNotifyCheckbox.target = self
        vpnNotifyCheckbox.action = #selector(vpnNotifyToggled)
        vpnNotifyCheckbox.state = store.vpnDisconnectNotifyEnabled ? .on : .off
        vpnNotifyCheckbox.toolTip = NSL("general.tip.vpnNotify",
            "While the Mac is kept awake, Electronic Clam watches your VPN with scutil "
            + "and notifies you if it disconnects — a local alert plus Telegram if you've "
            + "configured it. It never reconnects automatically (FortiClient needs SAML "
            + "sign-in). Independent of the clamshell guard. Off by default.")
        let sessionsControls = NSStackView(views: [clamshellGuardCheckbox, vpnNotifyCheckbox])
        sessionsControls.orientation = .vertical
        sessionsControls.alignment = .leading
        sessionsControls.spacing = 6
        let clamshellGuardRow = Self.formRow(NSL("general.sessions", "Sessions"),
                                             control: sessionsControls)

        // ADR-0037 S3 §폴백 — VPN 서비스 선택 팝업 + 새로고침. 자유 입력은 오타로
        // "No service" 를 유발했다(실측) → `scutil --nc list` 의 표시 이름에서 고르게
        // 한다. `themePopup`/`blankModePopup` 과 동일한 popup form-row idiom. 항목은
        // `reloadVpnServices()` 가 채운다(loadView·refresh·Refresh 버튼).
        vpnServicePopup.translatesAutoresizingMaskIntoConstraints = false
        vpnServicePopup.target = self
        vpnServicePopup.action = #selector(vpnServiceSelected)
        // 비활성 "(서비스 없음)" 힌트를 신뢰성 있게 비활성으로 유지하려면 자동
        // 활성화를 끈다(켜져 있으면 메뉴가 표시 때 재검증해 덮어쓸 수 있다).
        vpnServicePopup.autoenablesItems = false
        let vpnServiceTip = NSL("general.tip.vpnService",
            "Pick your VPN service (as macOS sees it in Settings → Network). FortiClient's "
            + "is usually \"VPN\". Electronic Clam watches it with scutil and, if it drops, "
            + "notifies you to re-auth — it never reconnects automatically (SAML sign-in "
            + "required). Use Refresh if your VPN isn't listed yet.")
        vpnServicePopup.toolTip = vpnServiceTip

        vpnRefreshButton.title = NSL("general.vpnRefresh", "Refresh")
        vpnRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        vpnRefreshButton.bezelStyle = .inline
        vpnRefreshButton.isBordered = false
        vpnRefreshButton.contentTintColor = .linkColor
        vpnRefreshButton.font = NSFont.systemFont(ofSize: 12)
        vpnRefreshButton.target = self
        vpnRefreshButton.action = #selector(vpnRefreshTapped)
        vpnRefreshButton.toolTip = NSL("general.tip.vpnRefresh",
            "Re-scan for VPN services — handy if your VPN app was closed when this opened.")

        let vpnControls = NSStackView(views: [vpnServicePopup, vpnRefreshButton])
        vpnControls.orientation = .horizontal
        vpnControls.alignment = .firstBaseline
        vpnControls.spacing = 8
        let vpnServiceRow = Self.formRow(NSL("general.vpnService", "VPN service"),
                                         control: vpnControls)

        vpnServiceNote.translatesAutoresizingMaskIntoConstraints = false
        vpnServiceNote.font = NSFont.systemFont(ofSize: 11)
        vpnServiceNote.textColor = .secondaryLabelColor
        vpnServiceNote.isSelectable = false
        vpnServiceNote.stringValue = NSL("general.vpnServiceNote",
            "Pick the VPN to watch, then turn on notifications above. You'll be alerted if "
            + "it drops (Telegram too, if configured). No auto-reconnect.")

        // ADR-0037 §#8 — "Blank screen" 동작 모드: Dim(기본·VPN-안전) vs Sleep.
        // themePopup 과 동일한 popup form-row 문법. Sleep 선택 시 아래 경고 노트가
        // 화면 잠금→VPN 끊김 위험을 알린다(ADR-0037 §#8 — 잠금은 Sleep 경로에서만).
        blankModePopup.translatesAutoresizingMaskIntoConstraints = false
        blankModePopup.addItems(withTitles: blankModeOrder.map(Self.blankModeTitle))
        blankModePopup.selectItem(at: blankModeOrder.firstIndex(of: store.blankDisplaysMode) ?? 0)
        blankModePopup.target = self
        blankModePopup.action = #selector(blankModeChanged)
        blankModePopup.toolTip = NSL("general.tip.blankMode",
            "Dim lowers the built-in brightness and holds the display awake so the "
            + "screen goes dark without locking — VPN sessions like FortiClient stay "
            + "connected, and brightness restores when you return. Sleep fully turns "
            + "displays off but may lock the screen and disconnect VPN.")
        let blankModeRow = Self.formRow(NSL("general.blankScreen", "Blank screen"),
                                        control: blankModePopup)

        blankModeNote.translatesAutoresizingMaskIntoConstraints = false
        blankModeNote.font = NSFont.systemFont(ofSize: 11)
        blankModeNote.textColor = .systemOrange
        blankModeNote.isSelectable = false
        blankModeNote.stringValue = NSL("general.blankSleepWarning",
            "Sleep fully turns displays off but may lock the screen and disconnect VPN.")
        blankModeNote.isHidden = (store.blankDisplaysMode != .sleep)  // refresh() 가 동기화

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

        // ADR-0039 — 설치 상태 노트. 경로를 담을 수 있어 isSelectable=true (복사용).
        // refreshInstallHealth() 가 off-main 스캔 후 갱신; 기본 숨김.
        installHealthNote.translatesAutoresizingMaskIntoConstraints = false
        installHealthNote.font = NSFont.systemFont(ofSize: 11)
        installHealthNote.textColor = .systemOrange
        installHealthNote.isSelectable = true
        installHealthNote.isHidden = true

        // ADR-0039 — resetbtm 최후수단 노트. 명령(`sudo sfltool resetbtm`)을 담아
        // 복사할 수 있게 isSelectable=true. reinstallTapped() 실패 시에만 표시.
        resetBtmNote.translatesAutoresizingMaskIntoConstraints = false
        resetBtmNote.font = NSFont.systemFont(ofSize: 11)
        resetBtmNote.textColor = .systemOrange
        resetBtmNote.isSelectable = true
        resetBtmNote.isHidden = true

        let formSeparator = Self.separator()
        // 권한 줄들에 보이는 ⓘ(클릭 팝오버) 부착 — hover toolTip과 같은 문자열
        // (2026-06-11 사용자 피드백: hover 전용 도움말은 발견 불가).
        let statusRow = InfoButton.wrap(permissionStatusLabel, statusTip)
        let permissionRow = InfoButton.wrap(permissionButton, permissionTip)
        let reinstallRow = InfoButton.wrap(reinstallButton, reinstallTip)
        let diagnosticsRow = InfoButton.wrap(exportDiagnosticsButton, diagnosticsTip)
        let settingsStack = NSStackView(views: [
            languageRow, themeRow, startupRow, loginItemNote, clamshellGuardRow,
            vpnServiceRow, vpnServiceNote,
            blankModeRow, blankModeNote, updatesRow,
            formSeparator,
            permissionHeader,
            statusRow, permissionRow, reinstallRow, diagnosticsRow,
            helperUnavailableNote, versionMismatchNote, helperUnreachableNote,
            installHealthNote, resetBtmNote,
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
            installHealthNote.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
            resetBtmNote.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
            loginItemNote.widthAnchor.constraint(equalTo: settingsStack.widthAnchor),
        ])
        self.view = container
        renderStatusCard()
        renderPermissionRow()
        renderLoginItemRow()
        renderUpdatesRow()
        reloadVpnServices()
        refreshInstallHealth()
    }

    /// Re-sync the popups + permission row (called by SettingsWindowController on
    /// show and on app reactivation via `refreshGeneralPane`).
    func refresh() {
        languagePopup.selectItem(at: AppLanguage.currentIndex)
        themePopup.selectItem(at: themeOrder.firstIndex(of: store.menuBarTheme) ?? 0)
        clamshellGuardCheckbox.state = store.clamshellLockGuardEnabled ? .on : .off
        vpnNotifyCheckbox.state = store.vpnDisconnectNotifyEnabled ? .on : .off
        // ADR-0037 S3 — pane 표시·앱 재활성마다 VPN 서비스 목록을 다시 스캔한다(VPN
        // 앱이 그새 켜졌을 수 있다). 저장값은 reloadVpnServices 가 항상 보존한다.
        reloadVpnServices()
        blankModePopup.selectItem(at: blankModeOrder.firstIndex(of: store.blankDisplaysMode) ?? 0)
        renderBlankModeNote()
        renderStatusCard()
        renderPermissionRow()
        renderLoginItemRow()
        renderUpdatesRow()
        refreshInstallHealth()
    }

    /// ADR-0039 — scan for split-brain / install-location / version-skew problems
    /// off the main thread (mdfind + launchctl shell-outs), then render the result
    /// on main. The note stays hidden until (and unless) a problem is found, so a
    /// healthy install shows nothing. Mirrors the CLI `eclam status` warnings for
    /// users who never open a terminal.
    private func refreshInstallHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bundlePath = Bundle.main.bundlePath
            let block = InstallLocation.registrationBlock(bundlePath: bundlePath)
            let inApps = InstallLocation.isInApplications(bundlePath)
            let job = LaunchctlInspect.helperJob()
            let copies = BundleScan.copies()
            let appVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            DispatchQueue.main.async {
                self?.renderInstallHealth(block: block, inApps: inApps,
                                          copies: copies, job: job, appVer: appVer)
            }
        }
    }

    /// Build the install-health message on main (all NSL on main) from the data
    /// scanned in `refreshInstallHealth`. Empty ⇒ hide the note.
    private func renderInstallHealth(block: InstallLocation.Block?, inApps: Bool,
                                     copies: [BundleScan.Copy],
                                     job: LaunchctlInspect.JobInfo?, appVer: String?) {
        var lines: [String] = []
        if let block = block {
            lines.append(block.kind == .quarantined
                ? NSL("installhealth.quarantined", "Electronic Clam is running from a download location, so macOS won’t let its helper start. Move it to the Applications folder and reopen it.")
                : NSL("installhealth.translocated", "macOS is running Electronic Clam from a temporary read-only location. Move it to the Applications folder and reopen it."))
        } else if !inApps {
            lines.append(NSL("installhealth.outside", "Electronic Clam is running outside the Applications folder, which can stop its helper from starting reliably. Move it to Applications and reopen it."))
        }
        if copies.count > 1 {
            let paths = copies.map { "  • \($0.shortVersion ?? "?")  \($0.path)" }.joined(separator: "\n")
            lines.append(NSL("installhealth.copies",
                "Multiple copies of Electronic Clam were found. Keep only the one in Applications and delete the rest:") + "\n" + paths)
        }
        if let reg = job?.parentBundleVersion, let appVer = appVer, reg != appVer {
            lines.append(NSLf("installhealth.skew",
                "The running app (%1$@) doesn’t match the registered helper (%2$@) — likely leftover copies. Use Reinstall Helper, or remove the extra copies above.", appVer, reg))
        } else if job?.spawnFailed == true, block == nil, inApps {
            // spawn-failed without a location/skew cause we already explained above.
            lines.append(NSL("installhealth.spawnFailed",
                "The background helper failed to start (a configuration error). Try Reinstall Helper; if it persists, restart your Mac."))
        }

        let message = lines.isEmpty ? nil
            : lines.map { "⚠\u{FE0E} \($0)" }.joined(separator: "\n\n")
        installHealthNote.isHidden = (message == nil)
        installHealthNote.stringValue = message ?? ""
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

    /// ADR-0037 §#8 — popup titles for the blank-displays mode.
    private static func blankModeTitle(_ mode: StateStore.BlankDisplaysMode) -> String {
        switch mode {
        case .dim:   return NSL("blankMode.dim", "Dim (keep VPN)")
        case .sleep: return NSL("blankMode.sleep", "Sleep displays")
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
        resetBtmNote.isHidden = true   // clear any prior escalation while retrying
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, err) = HelperRegistration.forceReregister(timeout: 15)
            // ADR-0039 — verify it actually came back (registration intent ≠ launchd
            // liveness): probe XPC like CLI `eclam repair` does, so a re-registration
            // that "succeeds" but leaves a dead daemon still escalates to resetbtm.
            let recovered = (status == .enabled) && HelperLiveness.isReachable(timeout: 3.0)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reinstallButton.isEnabled = true
                self.store.update(registrationStatus: status, registrationError: err)
                self.renderPermissionRow()
                self.renderResetBtmNote(recovered: recovered)
                self.refreshInstallHealth()   // re-scan duplicates/skew after the attempt
            }
        }
    }

    /// ADR-0039 — escalate to the `sudo sfltool resetbtm` last resort when a
    /// reinstall didn't bring the helper back (the 2026-07-01 incident: a stale BTM
    /// record bound to a removed/duplicate copy, which only resetbtm cleared). The
    /// app can't run the sudo command itself, so it shows it for the user to run in
    /// Terminal. Only shown right after a failed reinstall; hidden on success.
    private func renderResetBtmNote(recovered: Bool) {
        resetBtmNote.isHidden = recovered
        guard !recovered else { return }
        resetBtmNote.stringValue = "⚠\u{FE0E} " + NSL("resetbtm.note",
            "The helper still isn’t responding. A stale background record may be bound to a removed or duplicate copy. As a last resort, open Terminal and run “sudo sfltool resetbtm”, then restart your Mac and reopen Electronic Clam. This resets every app’s login items.")
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

    /// ADR-0037 — persist the opt-in clamshell lock guard. The StateStore setter
    /// fires onChange → AppDelegate.convergeNow → VirtualDisplayController.apply,
    /// which brings the virtual-display anchor up or down to match.
    @objc private func clamshellGuardToggled() {
        store.setClamshellLockGuard(clamshellGuardCheckbox.state == .on)
    }

    /// ADR-0037 S3 — persist the opt-in VPN-disconnect notification (independent of
    /// the clamshell guard). The StateStore setter fires onChange → convergeNow →
    /// VpnWatcher.apply, which arms or stops the scutil poll to match.
    @objc private func vpnNotifyToggled() {
        store.setVpnDisconnectNotify(vpnNotifyCheckbox.state == .on)
    }

    /// ADR-0037 S3 §폴백 — "서비스 없음" 힌트(비활성 항목). 라이브 언어를 따르도록
    /// 계산 프로퍼티로 둔다.
    private static var vpnNoServicesHint: String {
        NSL("general.vpnService.none", "(no VPN services found — open your VPN app)")
    }

    /// ADR-0037 S3 §폴백 — VPN 서비스 팝업을 `scutil --nc list` 로 (재)채운다. 저장값을
    /// 항상 선두에 포함해(라이브 목록에 없어도) 잃지 않고 그걸 선택한다. 라이브가
    /// 비면(VPN 앱 꺼짐) 저장값 뒤에 비활성 힌트를 덧붙여 이유를 알리고, 저장값도
    /// 라이브도 없으면 비활성 힌트 1개만 보인다. 런타임 `VpnWatcher.autodetectVpnService`
    /// 폴백과는 별개의 UI 편의로, 둘 다 유지한다(belt-and-suspenders).
    private func reloadVpnServices() {
        let stored = store.vpnServiceName        // init/setter 가 항상 비어있지 않게 정규화.
        let live = VpnWatcher.listVpnServices()
        vpnServicePopup.removeAllItems()

        var titles: [String] = []
        if !stored.isEmpty { titles.append(stored) }
        for name in live where name != stored { titles.append(name) }

        if titles.isEmpty {
            vpnServicePopup.addItem(withTitle: Self.vpnNoServicesHint)
            vpnServicePopup.item(at: 0)?.isEnabled = false
            vpnServicePopup.selectItem(at: 0)
            return
        }

        vpnServicePopup.addItems(withTitles: titles)
        if live.isEmpty {
            // 저장값만 있고 라이브 스캔이 빔 — 비활성 힌트로 이유를 보여준다.
            vpnServicePopup.menu?.addItem(.separator())
            let hint = NSMenuItem(title: Self.vpnNoServicesHint, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            vpnServicePopup.menu?.addItem(hint)
        }
        vpnServicePopup.selectItem(withTitle: stored)
        if vpnServicePopup.indexOfSelectedItem < 0 { vpnServicePopup.selectItem(at: 0) }
    }

    /// ADR-0037 S3 §폴백 — 팝업에서 고른 VPN 서비스명을 영속한다(→ converge →
    /// VpnWatcher). 비활성 힌트 항목은 사용자가 못 고르지만 방어적으로 가드한다.
    @objc private func vpnServiceSelected() {
        guard let title = vpnServicePopup.titleOfSelectedItem,
              title != Self.vpnNoServicesHint else { return }
        store.setVpnServiceName(title)
    }

    /// ADR-0037 S3 §폴백 — VPN 서비스 목록을 즉시 다시 스캔한다(Refresh 버튼).
    @objc private func vpnRefreshTapped() {
        reloadVpnServices()
    }

    /// ADR-0037 §#8 — persist the chosen blank-displays mode (dim/sleep) and
    /// re-render the Sleep warning note's visibility.
    @objc private func blankModeChanged() {
        let idx = blankModePopup.indexOfSelectedItem
        guard idx >= 0, idx < blankModeOrder.count else { return }
        store.setBlankDisplaysMode(blankModeOrder[idx])
        renderBlankModeNote()
    }

    /// Sleep 모드일 때만 경고 노트(화면 잠금→VPN 끊김)를 보인다.
    private func renderBlankModeNote() {
        let idx = blankModePopup.indexOfSelectedItem
        let mode = (idx >= 0 && idx < blankModeOrder.count) ? blankModeOrder[idx] : store.blankDisplaysMode
        blankModeNote.isHidden = (mode != .sleep)
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
