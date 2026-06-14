import Foundation
import OSLog
import UserNotifications

/// ADR-0004 "## 알림" — UNUserNotificationCenter wrapper for safety auto-release.
///
/// Lazy permission request: the first time `notify(...)` is called we read the
/// current authorization status; if `.notDetermined` we request `.alert + .sound`.
/// Bursting a permission dialog at app launch is bad UX, so we wait until we
/// genuinely have something to say.
///
/// Identifier reuse coalesces duplicates: posting twice with identifier
/// `eclam.release.<reason>` replaces (rather than stacks) the earlier
/// banner, which is what we want during the 5-min cooldown window where the
/// same reason may re-trip.
final class ReleaseNotifier {
    static let shared = ReleaseNotifier()
    private let log = Logger(subsystem: "com.jadhvank.eclam", category: "notify")
    private let center = UNUserNotificationCenter.current()

    /// `true` once we've attempted a permission request this process lifetime.
    /// Prevents us from re-prompting the user on every release after denial.
    private var permissionRequested = false
    /// Cached terminal authorization status (denied / authorized).
    /// `nil` ⇒ we haven't asked yet or we got `.notDetermined`.
    private var cachedAuthorized: Bool?

    private init() {}

    /// Post (or coalesce) a release notification.
    /// No-op on permission denial — we log once and give up for the session.
    /// 공통 권한 흐름 — notify/notifyInfo 가 공유.
    private func ensureAuthorized() async -> Bool {
        let status = await currentAuthorizationStatus()
        let authorized: Bool
        switch status {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .denied:
            authorized = false
        case .notDetermined:
            authorized = await requestAuthorizationOnce()
        @unknown default:
            authorized = false
        }
        if !authorized && cachedAuthorized != false {
            log.info("notification permission unavailable; skipping notice")
        }
        cachedAuthorized = authorized
        return authorized
    }

    /// proposal §5 — 일반 정보 알림 (1회성 온보딩 안내 등).
    func notifyInfo(identifier: String, title: String, body: String) async {
        guard await ensureAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            log.info("posted info notification \(identifier, privacy: .public)")
        } catch {
            log.error("UNUserNotificationCenter.add failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func notify(reason: SafetyReason, detail: String?) async {
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = NSL("notify.release.title", "Electronic Clam auto-released sleep")
        content.body = humanBody(reason: reason, detail: detail)
        content.sound = .default

        // Identifier reuse → cooldown coalescing (see header comment).
        let identifier = "eclam.release.\(reason.rawValue)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil)
        do {
            try await center.add(request)
            log.info("posted release notification \(identifier, privacy: .public)")
        } catch {
            log.error("UNUserNotificationCenter.add failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internal

    private func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { cont in
            center.getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestAuthorizationOnce() async -> Bool {
        guard !permissionRequested else { return cachedAuthorized ?? false }
        permissionRequested = true
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            cachedAuthorized = granted
            log.info("notification permission granted=\(granted, privacy: .public)")
            return granted
        } catch {
            cachedAuthorized = false
            log.error("requestAuthorization threw: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func humanBody(reason: SafetyReason, detail: String?) -> String {
        let head: String
        switch reason {
        case .batteryLow:      head = NSL("notify.batteryLow", "Battery low")
        case .thermalSerious:  head = NSL("notify.thermalSerious", "Thermal serious")
        case .thermalCritical: head = NSL("notify.thermalCritical", "Thermal critical")
        case .timer:           head = NSL("notify.maxDuration", "Max continuous awake reached")
        case .watchdog:        head = NSL("notify.watchdog", "Helper watchdog timed out")
        }
        if let d = detail, !d.isEmpty { return "\(head) — \(d)" }
        return head
    }
}
