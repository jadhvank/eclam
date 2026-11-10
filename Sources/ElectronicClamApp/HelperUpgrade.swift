import Foundation

/// Only called for an already-enabled SMAppService. Approval remains owned by
/// HelperRegistration. A receipt is written only after a fresh daemon answers.
enum HelperUpgrade {
    /// A first registration can be approved later, even after the app exits.
    /// Only a receipt for this exact bundle may complete that transition.
    static func finishApproval(fingerprint: String, pending: String?, enabled: Bool,
                               reachable: () -> Bool, save: (String) -> Void) -> Bool {
        guard pending == fingerprint, enabled, reachable() else { return false }
        save(fingerprint)
        return true
    }

    static func ensureCurrent(fingerprint: String, previous: String?,
                              reachable: () -> Bool, reinstall: () -> Bool,
                              save: (String) -> Void) -> Bool {
        if previous == fingerprint, reachable() { return true }
        guard reinstall(), reachable() else { return false }
        save(fingerprint)
        return true
    }
}
