import Foundation

@main
enum UpdatePreferencesTests {
    static func main() {
        let name = "eclam-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        UpdatePreferences.migrate(defaults)
        precondition(defaults.bool(forKey: "SUEnableAutomaticChecks"))
        defaults.removePersistentDomain(forName: name)
        defaults.set(false, forKey: "UpdateAutoCheckEnabled")
        UpdatePreferences.migrate(defaults)
        precondition(!defaults.bool(forKey: "SUEnableAutomaticChecks"), "old opt-out must survive")
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        UpdatePreferences.migrate(defaults)
        precondition(defaults.bool(forKey: "SUEnableAutomaticChecks"), "don't repeat migration")
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        UpdatePreferences.migrate(defaults)
        precondition(!defaults.bool(forKey: "SUAutomaticallyUpdate"), "automatic install is prohibited")
        print("OK: updater defaults, opt-out migration, user preference retention, manual installation")
    }
}
