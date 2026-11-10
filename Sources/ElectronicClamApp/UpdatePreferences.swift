import Foundation

enum UpdatePreferences {
    static func migrate(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil {
            let old = defaults.object(forKey: "UpdateAutoCheckEnabled") as? Bool ?? true
            defaults.set(old, forKey: "SUEnableAutomaticChecks")
        }
        // The app protects active work. Restart always requires user action,
        // even when preferences survive a different build of the application.
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
    }
}
