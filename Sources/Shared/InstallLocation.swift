import Foundation

/// ADR-0038 — pure install-location gate. macOS refuses to spawn a *privileged*
/// daemon when the parent bundle is quarantined or running from an App
/// Translocation path → every spawn fails with EX_CONFIG(78), leaving a dead
/// BTM record that even ADR-0036's self-repair can't clear (the record is owned
/// by a bundle at another path). `HelperRegistration.registerIfNeeded()` calls
/// `registrationBlock(bundlePath:)` *before* `register()` so the dead record is
/// never created in the first place.
///
/// Why the two blocked conditions are dev-safe (no escape hatch needed): local
/// builds are structurally never quarantined or translocated. Gatekeeper only
/// stamps `com.apple.quarantine` on *downloaded* files, and translocation only
/// happens when Finder opens a quarantined app — so `build/ElectronicClam.app`
/// (ad-hoc or Developer-ID, `open build/...`) always passes. See ADR-0038
/// "왜 이 게이트는 dev-safe 한가".
///
/// Lives in `Shared` (Foundation + Darwin `getxattr` only, no AppKit/
/// ServiceManagement) so the test harness can compile it standalone — see
/// `scripts/test.sh` and `Tests/InstallLocationTests.swift`.
public enum InstallLocation {
    public struct Block: Equatable {
        public enum Kind: String { case translocated, quarantined }
        public let kind: Kind

        public init(kind: Kind) { self.kind = kind }
    }

    /// FATAL conditions that cause EX_CONFIG daemon spawn failure. `nil` ⇒ safe
    /// to register. Reports translocation before quarantine (more specific — a
    /// translocated bundle is by definition also quarantine-derived). Pure given
    /// the path string except `isQuarantined`, which stats the path on disk.
    public static func registrationBlock(bundlePath: String) -> Block? {
        if isTranslocated(bundlePath) { return Block(kind: .translocated) }
        if isQuarantined(bundlePath) { return Block(kind: .quarantined) }
        return nil
    }

    /// App Translocation runs the bundle from a read-only randomized mount under
    /// `/private/var/folders/.../AppTranslocation/`. Substring match avoids the
    /// `SecTranslocate*` SPI (invariant #6 — public API first).
    public static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// True when the bundle carries the `com.apple.quarantine` extended
    /// attribute (set by Gatekeeper on downloads). `getxattr` with a nil buffer
    /// returns the attribute size (`>= 0`) when present, `-1` when absent.
    public static func isQuarantined(_ path: String) -> Bool {
        path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }
    }

    /// Hygiene signal only (ADR-0039), NOT a registration block — a non-
    /// quarantined bundle outside `/Applications` (e.g. `~/Desktop`, `build/`)
    /// registers fine, which the dev workflow depends on.
    public static func isInApplications(_ path: String) -> Bool {
        path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
