import AppKit
import Foundation
import OSLog

/// ADR-0035 — lightweight, notify-only update check.
///
/// Deliberately NOT an auto-updater (no Sparkle, no embedded framework, no
/// signing-key custody): we fetch the latest GitHub release, compare it to the
/// running version, and at most *tell* the user and open the download page.
/// Replacing a running, signed bundle in place is precisely the hard problem we
/// chose not to take on, so this stops at notification. Opt-out via
/// `autoCheckEnabled` (Settings → General).
enum UpdateChecker {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "update")

    /// Releases are published on this repo (the Homebrew cask downloads from
    /// github.com/jadhvank/eclam).
    private static let latestAPI = URL(string: "https://api.github.com/repos/jadhvank/eclam/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/jadhvank/eclam/releases/latest")!

    private static let autoCheckKey = "UpdateAutoCheckEnabled"
    private static let lastCheckKey = "UpdateLastCheckEpoch"
    private static let interval: TimeInterval = 24 * 60 * 60

    enum Result {
        case upToDate(current: String)
        case updateAvailable(latest: String, current: String, page: URL)
        case failed(String)
    }

    /// Opt-out daily background check. Defaults to ON when the key was never set.
    static var autoCheckEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: autoCheckKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: autoCheckKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Launch-time check, throttled to once per `interval`. Posts a passive
    /// banner (via the existing ReleaseNotifier) when a newer version exists.
    static func checkInBackgroundIfDue() {
        guard autoCheckEnabled else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last >= interval else { return }
        check { result in
            guard case .updateAvailable(let latest, _, _) = result else { return }
            Task {
                await ReleaseNotifier.shared.notifyInfo(
                    identifier: "eclam.update.available",
                    title: NSL("update.available", "Update available"),
                    body: NSLf("update.notify.body",
                               "Electronic Clam %@ is available — open Settings to update.", latest))
            }
        }
    }

    /// Manual "Check for Updates…" — always runs; completion on the main queue.
    static func checkManually(completion: @escaping (Result) -> Void) {
        check(completion: completion)
    }

    // MARK: - Internal

    private struct Release: Decodable { let tag_name: String; let html_url: String }

    private static func check(completion: @escaping (Result) -> Void) {
        var req = URLRequest(url: latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let current = currentVersion
        let task = URLSession.shared.dataTask(with: req) { data, _, error in
            // Stamp the throttle clock whether or not the call succeeded — a
            // flaky network shouldn't make us hammer GitHub every launch.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let finish: (Result) -> Void = { r in DispatchQueue.main.async { completion(r) } }
            if let error = error {
                log.error("update check failed: \(error.localizedDescription, privacy: .public)")
                finish(.failed(error.localizedDescription)); return
            }
            guard let data = data,
                  let release = try? JSONDecoder().decode(Release.self, from: data) else {
                log.error("update check: could not decode release JSON")
                finish(.failed("decode")); return
            }
            if isNewer(release.tag_name, than: current) {
                let page = URL(string: release.html_url) ?? releasesPage
                finish(.updateAvailable(latest: normalized(release.tag_name), current: current, page: page))
            } else {
                finish(.upToDate(current: current))
            }
        }
        task.resume()
    }

    /// "v0.5.0" → "0.5.0" for display.
    private static func normalized(_ tag: String) -> String {
        (tag.hasPrefix("v") || tag.hasPrefix("V")) ? String(tag.dropFirst()) : tag
    }

    /// Numeric component compare; tolerates a leading `v` and suffixes like
    /// `-test1` (only the leading-numeric prefix of each dotted part counts).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            normalized(v).split(separator: ".").map { comp in
                Int(comp.prefix { $0.isNumber }) ?? 0
            }
        }
        let a = parts(latest), b = parts(current)
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
