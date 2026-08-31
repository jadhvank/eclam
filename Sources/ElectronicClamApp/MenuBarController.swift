import AppKit
import OSLog
import ServiceManagement

/// Owns the NSStatusItem and rebuilds the menu on every open.
/// Menu layout per ADR-0005 §1.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "app")
    private let store: StateStore
    private let bridge: HelperBridge
    private let onOpenSettings: () -> Void
    private let onOpenAgentsPane: () -> Void

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(store: StateStore,
         bridge: HelperBridge,
         onOpenSettings: @escaping () -> Void,
         onOpenAgentsPane: @escaping () -> Void) {
        self.store = store
        self.bridge = bridge
        self.onOpenSettings = onOpenSettings
        self.onOpenAgentsPane = onOpenAgentsPane
        super.init()
        // `store.onChange` is owned by AppDelegate (it forwards to refresh()
        // and the convergence engine). We just install our menu here.
        installMenu()
        refresh()
        // 배치 검증은 런루프가 한 번 돌아 AppKit 이 아이템을 메뉴바에 앉힌 뒤에야
        // 의미가 있다. 실행 직후·화면 재구성 때마다 확인한다.
        verifyPlacementSoon()
    }

    deinit {
        if let m = rightClickMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// ADR-0014 — left-click toggles the effective awake state (no double-click).
    /// Right-click pops the menu. We do NOT permanently assign `statusItem.menu`
    /// so AppKit doesn't auto-pop on left click; right-click is handled by an
    /// NSEvent local monitor (the button's `.rightMouseUp` action routing is
    /// unreliable across macOS versions — ADR-0010 §A½ mechanism retained).
    private let menu = NSMenu()
    private var rightClickMonitor: Any?

    /// ADR-0037 §#8 — "어둡게(dim)" 모드 컨트롤러. 밝기 floor + display-sleep 방지
    /// assertion 을 잡고 사용자 복귀 시 자동 복원한다. dim 동안에만 타이머가 돈다.
    private let dimmer = BlankDisplayDimmer()

    private func installMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        // Left-click: button action.
        wireStatusButton()

        // 화면 재구성(모니터 연결·해제·정렬 변경·해상도 변경)마다 배치를 재검증한다.
        // 이게 없으면 아이템이 한 번 메뉴바 밖에 앉는 순간 영영 못 돌아온다 —
        // 2026-08-05 조사에서 실제로 3일간 조종 불가가 된 경로.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.verifyPlacementSoon()
            }

        // Right-click: NSEvent local monitor scoped to our status button's
        // window. We must temporarily install `statusItem.menu` and call
        // performClick so AppKit handles positioning, dismissal, and keyboard
        // navigation — manually calling `NSMenu.popUp` worked but produced
        // subtle focus/highlight bugs on Sequoia.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
            guard let self = self,
                  let button = self.statusItem.button,
                  event.window === button.window else { return event }
            self.popMenu()
            return nil
        }
    }

    private func wireStatusButton() {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp])
    }

    // MARK: - 배치 자가진단 (2026-08-05~09)
    //
    // 증상: 앱은 정상 동작하는데 메뉴바에 아이콘이 안 보여 토글도 설정도 못 연다.
    // 실측: 아이템은 존재(isVisible=true, 37x22)하는데 좌표가 어떤 화면의 메뉴바
    // 띠에도 걸리지 않았다 — 단일 화면에서도 `-1, 965`(좌하단 구석 = AppKit 이
    // 미표시 아이템을 버려두는 자리). 정상 프로세스의 아이템은 메뉴바 높이(33)를
    // 받는데 이쪽은 레거시 22 였다.
    //
    // 원인은 앱 밖이었다(폴백 주석 참고: Tahoe 메뉴바 허용 목록 원장 오염). 앱이
    // 고칠 수 있는 것이 아니므로 여기서는 **검출과 조종 경로 확보만** 한다.
    // 아이템 재생성 자가복구는 넣었다가 뺐다 — 효과가 없었고 사용자의 저장된
    // 선호 위치를 지우는 부작용만 있었다.

    private var screenObserver: Any?
    private var placementCheck: DispatchWorkItem?
    private var placementProbes = 0
    private var placementFallbackShown = false
    /// 이번 실행에서 한 번이라도 메뉴바에 제대로 앉은 적이 있는가.
    ///
    /// **오탐 방지의 핵심.** Bartender·Ice·Thaw 류 메뉴바 관리 앱은 아이템을 화면 밖으로
    /// 옮겨서 숨긴다 — 그건 사용자가 의도한 정상 동작이지 결함이 아니다. 정상 배치를
    /// 한 번이라도 관측했다면 이후의 이탈은 그런 앱의 소행으로 보고 개입하지 않는다.
    /// 자가복구는 "처음부터 끝까지 메뉴바에 못 앉은" 경우에만 돈다.
    private var everPlaced = false
    /// 폴백 전까지의 관측 횟수. 느린 로그인/디스플레이 안정화를 미배치로 오판하지
    /// 않도록 넉넉히 본다(약 2·5·8·11초).
    private static let maxPlacementProbes = 4

    /// 다음 런루프 + 여유를 두고 배치를 검증한다. 연속 호출은 합쳐진다
    /// (모니터 hot-plug 는 알림을 여러 번 쏜다).
    private func verifyPlacementSoon(delay: TimeInterval = 2.0) {
        placementCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.verifyPlacement() }
        placementCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 상태아이템이 실제로 어떤 화면의 메뉴바 띠 안에 있는가.
    ///
    /// `isVisible` 만으로는 부족하다 — AppKit 은 표시하지 못한 아이템도
    /// `isVisible == true` 로 두고 창만 메뉴바 밖에 둘 수 있다(실측). 그래서
    /// 버튼 창의 실제 프레임을 화면 상단 띠와 대조한다.
    private func statusItemIsOnAMenuBar() -> Bool {
        guard statusItem.isVisible, let win = statusItem.button?.window else { return false }
        // 기하 판정은 순수 계층(MenuBarPlacement)에 위임 — scripts/test.sh 가 단독
        // 컴파일해 회귀 검증한다. 여기서는 AppKit 상태만 모아 넘긴다.
        return MenuBarPlacement.isOnAMenuBar(itemFrame: win.frame,
                                             screens: NSScreen.screens.map(\.frame))
    }

    /// 실패 시 1회 남기는 화면 기하. 아이템 프레임과 **같은 좌표계(Cocoa)** 라
    /// 바로 대조된다. 손쉬운 사용 권한이 없어도(실측: osascript AX 조회가 회수된
    /// 환경이 있었다) 앱이 스스로 남기므로 원인 추적의 출발점이 된다.
    private func screensDescription() -> String {
        NSScreen.screens.enumerated().map { i, s in
            "[\(i)]\(NSStringFromRect(s.frame))top=\(Int(s.frame.maxY))mb=\(Int(s.frame.maxY - s.visibleFrame.maxY))"
        }.joined(separator: " ")
    }

    private func verifyPlacement() {
        if statusItemIsOnAMenuBar() {
            if !everPlaced {
                log.info("status item placed on a menu bar")
            }
            everPlaced = true
            placementProbes = 0
            return
        }
        // 정상 배치를 본 적 있다면 메뉴바 관리 앱이 숨긴 것 — 정상이므로 개입 금지.
        guard !everPlaced else { return }

        // 로그인 직후·디스플레이 안정화 중일 수 있으니 몇 번 더 지켜본다.
        placementProbes += 1
        if placementProbes < Self.maxPlacementProbes {
            verifyPlacementSoon(delay: 3.0)
            return
        }

        // 미배치 확정 — 사용자가 앱을 되찾을 경로를 연다.
        //
        // 자가복구(아이템 재생성)는 시도했다가 뺐다. 2026-08-05~09 실측에서
        // 재생성은 아이템을 옮기기만 하고 배치에 성공하지 못했으며, 저장된
        // 선호 위치를 지우는 부작용만 있었다. 실제 원인은 앱 밖(아래 폴백 참고)
        // 이라 앱이 고칠 수 있는 것이 아니다.
        let frame = statusItem.button?.window?.frame ?? .zero
        log.error("status item never reached a menu bar (frame=\(NSStringFromRect(frame), privacy: .public), visible=\(self.statusItem.isVisible, privacy: .public), screens=\(self.screensDescription(), privacy: .public))")
        presentPlacementFallback()
    }

    /// 아이콘을 띄울 수 없을 때 사용자가 앱을 되찾는 경로 (1회).
    ///
    /// 실측 원인 (2026-08-09 확정): macOS 26 Tahoe 는 메뉴바 아이템의 소유·허용
    /// 상태를 `group.com.apple.controlcenter` 의 `trackedApplications` 원장에
    /// **번들 식별자로** 기록한다. 메뉴바 정리 앱(Bartender·Ice·Thaw 계열)이
    /// 아이템을 옮기면 이 귀속이 교차 오염돼, 시스템 설정에서 "허용"으로 켜도
    /// 아이콘이 영영 안 나온다 — 다른 앱 항목에 박힌 참조는 토글이 못 고치기
    /// 때문이다. 앱을 재설치·재빌드해도 상태가 식별자에 묶여 있어 소용없다.
    /// 참고: steipete/CodexBar#1440.
    ///
    /// 앱이 고칠 수 없는 문제이므로, 최소한 조종 경로를 남기는 것이 목적이다.
    private func presentPlacementFallback() {
        guard !placementFallbackShown else { return }
        placementFallbackShown = true
        log.error("opening Settings as fallback for the missing menu bar icon")
        onOpenSettings()
        let title = NSL("menubar.missing.title", "Electronic Clam’s menu bar icon can’t be shown")
        // 문자열은 조각으로 나눠 잇는다 — 한 식으로 이으면 타입 체커가 시간 초과한다.
        let cause = "macOS is not placing the icon in the menu bar. On macOS 26 this is usually "
            + "the menu bar allow-list (System Settings → Menu Bar), which can stay broken "
            + "after a menu bar organiser (Bartender, Ice, Thaw…) rearranges icons."
        let remedy = " Turning the app “on” there does not always fix it; restarting your Mac "
            + "often does. Settings is open so you can still control Electronic Clam, and the "
            + "`eclam` command (`eclam off`, `eclam on`, `eclam status`) always works."
        let body = NSL("menubar.missing.body", cause + remedy)
        Task { await ReleaseNotifier.shared.notifyInfo(
            identifier: "eclam.menubar.missing", title: title, body: body) }
    }

    private func popMenu() {
        rebuildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach after the run loop spins so AppKit finishes the popup, but
        // before the next click. async-on-main is the right hop.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc private func buttonClicked() {
        // Right-click / ctrl-click pops the menu (ADR-0010 §A½). macOS sometimes
        // fires this with currentEvent==nil (synthetic clicks); treat as left.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popMenu()
            return
        }
        toggleAwake()
    }

    /// ADR-0014 — a single left-click toggles the *effective* awake state,
    /// regardless of why it is awake. No double-click, so the click is instant.
    ///   asleep         → awake (manual)
    ///   awake (manual) → asleep
    ///   awake (auto)   → asleep (the agent/remote auto-signal is suppressed)
    private func toggleAwake() {
        guard isEnabled else {
            // Helper not approved → open settings rather than silently failing.
            openSettingsTapped()
            return
        }
        if store.shouldKeepAwake {
            // Awake by any cause → the user wants sleep now. setManualOverrideOff
            // clears manualToggle too and suppresses agent/remote auto-signals.
            store.setManualOverrideOff(true)
        } else {
            // Asleep → the user wants awake now.
            store.setManualOverrideOff(false)
            store.setManualToggle(true)
        }
        // ADR-0025 — '지금 재워' 의도면 CLI TTL hold 도 취소 (helper 는 hold
        // 중의 off 쓰기를 무시하므로 cancel 이 선행해야 실제로 잠들 수 있다).
        if !store.shouldKeepAwake && store.cliHoldActive {
            bridge.cancelHold()
        }
        bridge.setSleepDisabled(store.shouldKeepAwake) { _ in }
    }

    // MARK: - Rendering

    func refresh() {
        renderStatusButton()
        rebuildMenu()
    }

    /// Menu bar glyph height in points. Status bar is ~22pt tall; 18pt leaves padding.
    private static let statusIconHeight: CGFloat = 18

    /// The three menu-bar glyphs (ADR-0005 §1 art set):
    ///   off    — outline shell (asleep)
    ///   bolt   — filled shell + lightning (the user is holding sleep open)
    ///   remote — filled shell + remote (an automatic signal is holding it)
    private enum GlyphState: String { case off, bolt, remote }

    private func renderStatusButton() {
        guard let button = statusItem.button else { return }
        // P1-a — registered but the helper isn't answering: never render a
        // filled "holding awake" glyph (it would lie). Flag it on the menu bar
        // itself so the silent keep-awake failure is visible without opening the
        // menu. Template so it tints with the bar (handoff 2026-06-24).
        if isEnabled && store.helperUnreachable {
            let a11y = NSL("a11y.helperUnreachable", "Helper not responding")
            if let warn = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                  accessibilityDescription: a11y) {
                warn.isTemplate = true
                button.image = warn
                button.title = ""
            } else {
                button.image = nil
                button.title = "⚠"
            }
            return
        }
        let on = store.shouldKeepAwake && isEnabled
        // 3-way: off / manual-awake (bolt) / auto-awake (remote = agent, remote,
        // or safety hold). The bolt is reserved for `manualToggle` so the user
        // can tell at a glance whether *they* are holding sleep open or whether
        // some automatic signal is doing it.
        let state: GlyphState
        let fallbackSymbol: String
        let accessibility: String
        if !on {
            state = .off
            fallbackSymbol = "lightbulb"
            accessibility = NSL("a11y.asleep", "Asleep")
        } else if store.manualToggle {
            state = .bolt
            fallbackSymbol = "lightbulb.fill"
            accessibility = NSL("a11y.awakeManual", "Awake (manual)")
        } else {
            state = .remote
            fallbackSymbol = "lightbulb.fill"
            accessibility = NSL("a11y.awakeAuto", "Awake (auto)")
        }
        if let image = MenuBarController.statusImage(state: state,
                                                     theme: store.menuBarTheme,
                                                     fallbackSymbol: fallbackSymbol,
                                                     accessibility: accessibility) {
            button.image = image
            button.title = ""
        } else {
            // Last-resort fallback if both the bundled asset and SF Symbol are unavailable.
            button.image = nil
            button.title = on ? "•" : "○"
        }
    }

    /// Maps (state × theme) to a bundled PNG, falling back to an SF Symbol.
    ///   .system → the black ("light") art rendered as a *template*: the menu
    ///             bar tints it black on a light bar, white on a dark bar, so it
    ///             tracks the system appearance automatically.
    ///   .light  → the black art, fixed (for a persistently light menu bar).
    ///   .dark   → the white art, fixed (for a persistently dark menu bar).
    private static func statusImage(state: GlyphState,
                                    theme: StateStore.MenuBarTheme,
                                    fallbackSymbol: String,
                                    accessibility: String) -> NSImage? {
        // `system` and `light` both draw from the black art; only `dark` uses the
        // white art. `system` additionally flags it as a template for auto-tint.
        let variant = (theme == .dark) ? "dark" : "light"
        let isTemplate = (theme == .system)
        let asset = "clam-\(state.rawValue)-\(variant)"
        if let url = Bundle.main.url(forResource: asset, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            // Scale to the menu bar height while preserving aspect ratio; the high-res rep stays
            // intact so Retina renders crisply.
            let aspect = image.size.width / max(image.size.height, 1)
            image.size = NSSize(width: statusIconHeight * aspect, height: statusIconHeight)
            image.isTemplate = isTemplate
            image.accessibilityDescription = accessibility
            return image
        }
        if let image = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: accessibility) {
            image.isTemplate = true
            return image
        }
        return nil
    }

    private var isEnabled: Bool {
        if case .enabled = store.registration { return true }
        return false
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // 1. Status header + 1½. ADR-0017 guard status — ONE view-backed item.
        // These used to be 4 disabled rows, which macOS dims like inactive
        // controls; the menu's most important readout was its least legible
        // (사용자 피드백 2026-06-11). A custom view renders the same strings at
        // full opacity, with a colored status dot for at-a-glance state.
        menu.addItem(makeStatusHeaderViewItem())
        menu.addItem(.separator())

        // 2. Keep Mac Awake — primary toggle with checkmark.
        let toggle = NSMenuItem(
            title: NSL("menu.keepAwake", "Keep Mac Awake"),
            action: #selector(toggleTapped),
            keyEquivalent: "k")
        toggle.target = self
        toggle.state = (store.manualToggle && isEnabled) ? .on : .off
        toggle.isEnabled = canToggle
        menu.addItem(toggle)

        // 3. Watch Agents — submenu.
        let watch = NSMenuItem(title: NSL("menu.watchAgents", "Watch Agents"), action: nil, keyEquivalent: "")
        watch.submenu = buildAgentsSubmenu()
        menu.addItem(watch)

        // 3½. Blank screen — sleep all displays but keep the Mac (and agents)
        // running. For working overnight with the screens off (backlog #8).
        let blank = NSMenuItem(
            title: NSL("menu.blankDisplays", "Blank screen — keep working"),
            action: #selector(blankDisplaysTapped),
            keyEquivalent: "")
        blank.target = self
        blank.isEnabled = canToggle
        menu.addItem(blank)

        menu.addItem(.separator())

        // 4. Settings…
        let settings = NSMenuItem(
            title: NSL("menu.settings", "Settings…"),
            action: #selector(openSettingsTapped),
            keyEquivalent: ",")
        settings.target = self
        settings.image = nil
        menu.addItem(settings)

        // 5. Quit — own selector + explicit nil image. macOS Sequoia attaches
        // an xmark glyph to items whose action is NSApplication.terminate(_:);
        // routing through our own method avoids the auto-adornment.
        let quit = NSMenuItem(
            title: NSL("menu.quit", "Quit"),
            action: #selector(quitTapped),
            keyEquivalent: "q")
        quit.target = self
        quit.image = nil
        menu.addItem(quit)
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    private var canToggle: Bool {
        // Only allow toggling when the helper is registered and reachable.
        isEnabled
    }

    /// View-backed header item: colored status dot + bold headline + the
    /// ADR-0017 guard lines, exempt from NSMenu's disabled-row dimming.
    /// `title` is still set (menus read it for accessibility/searching).
    private func makeStatusHeaderViewItem() -> NSMenuItem {
        let (text, _) = headerString(for: store.registration, sleepDisabled: store.sleepDisabled)
        // Warning lines (⚠️) get full-contrast labelColor so an active guard
        // doesn't read as a disabled row; calm lines stay secondary.
        let lines: [NSAttributedString] = isEnabled
            ? guardStatusLines().map {
                Self.symbolize($0, color: $0.contains("⚠️") ? .labelColor : .secondaryLabelColor)
            }
            : []
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.view = MenuStatusHeaderView(
            headline: text,
            dotColor: statusDotColor(),
            guardLines: lines)
        return item
    }

    /// At-a-glance state color for the header dot.
    private func statusDotColor() -> NSColor {
        guard case .enabled = store.registration else { return .systemOrange } // needs attention
        if store.helperUnreachable { return .systemOrange }                     // P1-a — dead-but-enabled
        if store.safetyRelease != nil { return .systemOrange }                  // guard released
        if store.sleepDisabled || store.shouldKeepAwake { return .systemGreen } // holding awake
        return .systemGray                                                      // asleep when idle
    }

    /// Six-case mapping per ADR-0005 §2, extended for ADR-0006 §A activity text.
    private func headerString(for status: StateStore.RegistrationView, sleepDisabled: Bool)
        -> (text: String, symbol: String)
    {
        switch status {
        case .enabled:
            return (enabledHeader(), "lightbulb")
        case .requiresApproval:
            return (NSL("header.requiresApproval", "Approve in System Settings…"), "lightbulb")
        case .notFound:
            return (NSL("header.notFound", "Helper missing — reinstall"), "lightbulb")
        case .notRegistered, .registerThrew:
            return (NSL("header.registrationFailed", "Registration failed — try again"), "lightbulb")
        case .unknown:
            return (NSL("header.unknown", "Unknown state"), "lightbulb")
        }
    }

    /// Nine-case priority per ADR-0004 §"헤더 표시" + ADR-0008 + ADR-0005 §2.
    /// First match wins. Safety releases pre-empt every awake reason.
    private func enabledHeader() -> String {
        // 0. P1-a — registered (.enabled) but the helper isn't answering XPC.
        // Pre-empts every "Awake — …" line below, which would otherwise claim
        // we're holding sleep open while the daemon is actually dead (the silent
        // failure this fixes — handoff 2026-06-24).
        if store.helperUnreachable {
            return NSL("header.helperUnreachable", "Helper not responding — run repair")
        }

        // 1–5. Safety auto-release reasons.
        //
        // ADR-0026 — wording is "guard", not "asleep": a release only means the
        // app stopped forcing wakefulness. If the user is at the keyboard the
        // Mac is plainly *not* asleep, so the header must describe what the app
        // is doing (guard blocked the keep-awake), not assert a sleep state.
        if let reason = store.safetyRelease {
            switch reason {
            case .thermalCritical:
                // Prefer 5-step label (e.g. "sleeping") when available; fall back to "critical".
                if let p = store.thermalPressureLevel, p >= 3 {
                    return NSLf("header.guardThermalLabel", "Guard active — 🌡 %@", SafetyMonitor.thermalPressureLabel(p))
                }
                return NSL("header.guardThermalCritical", "Guard active — 🌡 critical")
            case .thermalSerious:
                // 5-step `.trapping` (level 3) wins over the 4-step `.serious` label.
                if let p = store.thermalPressureLevel, p >= 3 {
                    return NSLf("header.guardThermalLabel", "Guard active — 🌡 %@", SafetyMonitor.thermalPressureLabel(p))
                }
                return NSL("header.guardThermalSerious", "Guard active — 🌡 serious + lid")
            case .batteryLow:
                if let pct = store.batteryPercent {
                    return NSLf("header.guardBattery", "Guard active — 🔋 %d%%", pct)
                }
                return NSL("header.guardBatteryLow", "Guard active — 🔋 low")
            case .timer:
                let m = store.safetySettings.maxDurationMin
                return m > 0 ? NSLf("header.guardTimer", "Guard active — ⏱ %dm", m)
                             : NSL("header.guardTimerPlain", "Guard active — ⏱ timer")
            case .watchdog:
                return NSL("header.guardWatchdog", "Guard active — helper timeout")
            }
        }

        // 5½. ADR-0025 — CLI TTL hold: 명시적 사용자 명령이므로 ambient
        // 신호(remote/agent)보다 위. sleepDisabled 실측이 true 일 때만
        // (만료 직후 stale 잔여값으로 헛표시하지 않게).
        if store.cliHoldActive && store.sleepDisabled {
            if store.cliHoldRemainingSeconds < 0 {
                return NSL("header.awakeCliHoldForever", "Awake — CLI hold (no expiry)")
            }
            return NSLf("header.awakeCliHold", "Awake — CLI hold · %@ left",
                        DurationParse.shortFormat(seconds: store.cliHoldRemainingSeconds))
        }

        // 6. Remote session — spec priority: beats agent header.
        if store.shouldKeepAwake
            && store.remoteCountsAsActivity
            && store.remoteActive {
            return NSL("header.awakeRemote", "Awake — remote session")
        }

        // 7. Agent active (existing behavior).
        let active = store.activeAgents
        if store.shouldKeepAwake && !active.isEmpty {
            let knownLabels = Dictionary(
                uniqueKeysWithValues: store.allKnownTraces().map { ($0.id, $0.label) })
            let sortedIds = active.sorted()
            let labels = sortedIds.compactMap { knownLabels[$0] }
            if labels.count >= 3 {
                return NSLf("header.awakeAgentsCount", "Awake — %d agents active", labels.count)
            }
            return NSLf("header.awakeAgents", "Awake — %@ active", labels.joined(separator: ", "))
        }

        // 8. Manual toggle / catch-all awake.
        if store.shouldKeepAwake {
            return NSL("header.awakeManual", "Awake — until I quit")
        }

        // 9. Default.
        return NSL("header.asleepIdle", "Asleep when idle")
    }

    // MARK: - ADR-0017 guard status block
    //
    // (The lines now render inside `MenuStatusHeaderView` — the old per-line
    // disabled NSMenuItems were dimmed by NSMenu and hard to read.)

    /// v0.5 — status-line emoji → monochrome SF Symbols.
    private static let statusSymbols: [Character: String] = [
        "🔋": "battery.100",
        "🌡": "thermometer.medium",
        "🛰": "antenna.radiowaves.left.and.right",
        "⏱": "timer",
        "⚠️": "exclamationmark.triangle.fill",
    ]

    /// Renders a status string, swapping the emoji in `statusSymbols` for
    /// monochrome SF Symbols as *inline text attachments*. Inline (not
    /// `NSMenuItem.image`) so NSMenu's state column stays closed and Settings…/
    /// Quit aren't indented (ADR-0005 §2). ⚠️ keeps a systemOrange tint; the
    /// rest take the row's text color so they track light/dark automatically.
    private static func symbolize(_ line: String, color: NSColor) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let out = NSMutableAttributedString()
        for ch in line {
            guard let name = statusSymbols[ch],
                  let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                out.append(NSAttributedString(string: String(ch),
                    attributes: [.font: font, .foregroundColor: color]))
                continue
            }
            let tint = (ch == "⚠️") ? NSColor.systemOrange : color
            let conf = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                .applying(.init(paletteColors: [tint]))
            let img = base.withSymbolConfiguration(conf) ?? base
            let attachment = NSTextAttachment()
            attachment.image = img
            // Center the glyph vertically on the text's cap height.
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - img.size.height) / 2,
                                       width: img.size.width, height: img.size.height)
            out.append(NSAttributedString(attachment: attachment))
        }
        return out
    }

    private func guardStatusLines() -> [String] {
        let s = store.safetySettings
        var lines: [String] = []

        // 🔋 Battery — current % vs guard threshold. Display uses the raw
        // (un-debounced) reading so the number tracks the OS immediately; the
        // guard's own decision still runs on the debounced `batteryPercent`.
        if let pct = store.batteryPercentDisplay {
            let warn = s.enabled && pct <= s.batteryLow
            lines.append(NSLf("status.battery", "🔋 %d%% · guard %d%%%@",
                              pct, s.batteryLow, warn ? " ⚠️" : ""))
        }

        // 🌡 Thermal — current state vs cutoff.
        let tWarn = s.enabled && store.thermalState.rawValue >= Self.thermalRank(fromName: s.thermalCutoff)
        lines.append(NSLf("status.thermal", "🌡 %@ · limit %@%@",
                          Self.thermalShort(store.thermalState),
                          Self.thermalLocalized(fromName: s.thermalCutoff),
                          tWarn ? " ⚠️" : ""))

        // 🛰 Remote — ADR-0016 idle knob state.
        lines.append(remoteStatusLine())

        // ⏱ Session — elapsed vs timer cap (only when a cap is set and awake).
        if s.maxDurationMin > 0, store.shouldKeepAwake, let since = store.keepAwakeSince {
            let mins = Int(Date().timeIntervalSince(since) / 60)
            lines.append(NSLf("status.timer", "⏱ %dm · cap %dm", mins, s.maxDurationMin))
        }
        return lines
    }

    private func remoteStatusLine() -> String {
        let t = store.remoteIdleTimeoutMin
        if t == 0 { return NSL("status.remoteOff", "🛰 remote off") }
        if store.remoteActive {
            if t == StateStore.remoteIdleNever {
                return NSL("status.remoteActiveNoExpiry", "🛰 remote active · no expiry")
            }
            if let idle = store.remoteIdleMin {
                return NSLf("status.remoteIdleActive", "🛰 idle %dm · sleep at %dm", idle, t)
            }
            return NSLf("status.remoteActiveCap", "🛰 remote active · sleep after %dm idle", t)
        }
        if t == StateStore.remoteIdleNever {
            return NSL("status.remoteIdleNever", "🛰 remote · no expiry")
        }
        return NSLf("status.remoteIdleCap", "🛰 remote · sleep after %dm idle", t)
    }

    private static func thermalShort(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return NSL("thermal.nominal", "nominal")
        case .fair:     return NSL("thermal.fair", "fair")
        case .serious:  return NSL("thermal.serious", "serious")
        case .critical: return NSL("thermal.critical", "critical")
        @unknown default: return "?"
        }
    }

    /// Display-only localization of a canonical thermal-cutoff name
    /// (`SafetySettings.thermalCutoff` stays the stored English string).
    private static func thermalLocalized(fromName name: String) -> String {
        switch name {
        case "nominal":  return NSL("thermal.nominal", "nominal")
        case "fair":     return NSL("thermal.fair", "fair")
        case "serious":  return NSL("thermal.serious", "serious")
        case "critical": return NSL("thermal.critical", "critical")
        default:         return name
        }
    }

    private static func thermalRank(fromName name: String) -> Int {
        switch name {
        case "nominal":  return 0
        case "fair":     return 1
        case "serious":  return 2
        case "critical": return 3
        default:         return 1
        }
    }

    private func buildAgentsSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Watch Agents")
        submenu.autoenablesItems = false
        // Stable display order: M1 defaults in declaration order, then customs sorted by label.
        let defaultIds = Set(AgentTrace.M1Defaults.map(\.id))
        let customs = store.customTraces.sorted { $0.label < $1.label }
        let ordered: [AgentTrace] = AgentTrace.M1Defaults + customs.filter { !defaultIds.contains($0.id) }

        for trace in ordered {
            let activeDot = store.activeAgents.contains(trace.id) ? NSL("menu.agentActiveSuffix", " • active") : ""
            let item = NSMenuItem(
                title: "\(trace.label)\(activeDot)",
                action: #selector(agentTapped(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = trace.id
            item.state = store.isAgentWatched(trace.id) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let customize = NSMenuItem(
            title: NSL("menu.customize", "Customize…"),
            action: #selector(customizeTapped),
            keyEquivalent: "")
        customize.target = self
        submenu.addItem(customize)
        return submenu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // ADR-0018 — reconcile registration first so an approve/revoke done in
        // System Settings is reflected even while we still believe we're
        // unapproved (the old code only refreshed when already `.enabled`).
        store.update(registrationStatus: HelperRegistration.status(), registrationError: nil)
        if isEnabled {
            bridge.refreshCurrentState()
        }
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleTapped() {
        // If helper is not enabled, surface a fix path based on current state.
        switch store.registration {
        case .enabled:
            // Flip the user's intent; the convergence engine in AppDelegate
            // does the XPC write (debounced).
            store.setManualToggle(!store.manualToggle)
            // ADR-0025 — 토글을 꺼서 effective 의도가 '재워'가 됐다면 CLI
            // hold 도 취소 (toggleAwake 와 같은 규칙).
            if !store.shouldKeepAwake && store.cliHoldActive {
                bridge.cancelHold()
            }
            refresh()
        case .requiresApproval:
            HelperRegistration.openLoginItemsSettings()
        case .notRegistered, .registerThrew:
            let (status, err) = HelperRegistration.retry()
            store.update(registrationStatus: status, registrationError: err)
            if case .enabled = store.registration {
                bridge.refreshCurrentState()
            }
            refresh()
        case .notFound:
            if let url = URL(string: "https://github.com/jadhvank/eclam#readme") {
                NSWorkspace.shared.open(url)
            }
        case .unknown:
            log.error("toggle ignored: unknown registration state")
        }
    }

    @objc private func openSettingsTapped() {
        onOpenSettings()
    }

    /// Backlog #8 — blank all displays (built-in + external) while the Mac keeps
    /// running, for "keep working overnight with the screens off". Ensures the
    /// system stays awake first, then triggers a one-shot display sleep.
    @objc private func blankDisplaysTapped() {
        guard isEnabled else { openSettingsTapped(); return }
        if !store.shouldKeepAwake {
            store.setManualOverrideOff(false)
            store.setManualToggle(true)
            bridge.setSleepDisabled(true) { _ in }
        }
        blankDisplays()
    }

    /// ADR-0037 §#8 — 사용자가 고른 모드로 화면을 끈다. `.dim`(기본·VPN-안전)은
    /// 밝기 floor + display-sleep 방지 assertion 으로 *잠그지 않고* 깜깜하게 만들고
    /// 사용자 복귀 시 자동 복원한다; `.sleep`은 기존 `pmset displaysleepnow`로
    /// display 를 재운다(즉시-잠금 Mac 에선 화면 잠금→VPN 끊김 가능). keep 보장은
    /// 호출부(`blankDisplaysTapped`)에서 선행한다.
    private func blankDisplays() {
        switch store.blankDisplaysMode {
        case .dim:
            dimmer.dim()
        case .sleep:
            sleepDisplaysNow()
        }
    }

    /// ADR-0037 §#8 "재우기" — one-shot display sleep for all screens. This is NOT
    /// a SleepDisabled power-setting write, so it's outside rule 5's "no pmset for
    /// power settings" constraint; `pmset displaysleepnow` needs no privileges and
    /// is the most reliable cross-version trigger. The displays go dark but each
    /// monitor stays powered (USB-C PD continues) because we only blank.
    /// ⚠ 즉시-잠금 Mac 에선 display sleep 이 화면 잠금을 유발해 FortiClient 같은 VPN
    /// 을 끊을 수 있다(Settings 의 Sleep 옵션에 경고). 그래서 기본 모드는 `.dim`.
    private func sleepDisplaysNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        // 자식 회수: 핸들러가 Process 를 종료 시점까지 붙들어 좀비를 남기지
        // 않는다 (fire-and-forget 이라 waitUntilExit 로 블록할 이유는 없음).
        p.terminationHandler = { _ in }
        do { try p.run() } catch {
            log.error("blankDisplays: pmset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func agentTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.toggleAgent(id)
        log.info("watched agents toggled: \(id, privacy: .public)")
    }

    @objc private func customizeTapped() {
        onOpenAgentsPane()
    }
}
