import Foundation

/// Pure helper-health verdict — maps the daemon's registration state plus an
/// XPC reachability probe into what `eclam status` prints and exits with.
///
/// ADR-0033 §Decision left the "registered but dead" case to the registration/
/// onboarding UI, but `SMAppService.status == .enabled` reflects *registration
/// intent*, not launchd load/reachability. A dead-but-`.enabled` daemon was
/// therefore reported as a flat `enabled` with exit 0 — the silent false
/// positive this fixes (handoff 2026-06-24). Splitting the decision out of
/// `StatusCommand` keeps it unit-testable without XPC / ServiceManagement.
///
/// Lives in `Shared` (stdlib-only, like `DurationParse` / `HoldState`) so the
/// test harness can compile it standalone — `scripts/test.sh`.
public enum HelperReg: String, Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

public struct HelperHealthVerdict: Equatable {
    /// Stable machine value for `status --json`'s `helperStatus` field — the raw
    /// registration string, unchanged from the pre-liveness behaviour so
    /// existing consumers keep working.
    public let raw: String
    /// Human-readable value for `eclam status` text mode. Identical to `raw`
    /// except for the enabled-but-unreachable case, which appends the repair
    /// hint.
    public let human: String
    /// `nil` ⇒ liveness was not probed (only the `.enabled` path probes XPC).
    /// `true`/`false` ⇒ the probe ran and the helper did / did not answer.
    public let reachable: Bool?
    /// Process exit code. `0` ok / `2` enabled-but-unreachable. Mirrors the
    /// `on`/`off`/`watch` convention (HelpCommand EXIT CODES).
    ///
    /// NOTE: the non-enabled states keep exit `0` deliberately. `eclam status`
    /// is a *read* command that has historically always exited 0, and CI's
    /// `smoke.sh` runs `eclam status` on a runner where the daemon is never
    /// registered (→ `.notRegistered`) and fails on any non-zero exit. Only the
    /// new dead-but-`.enabled` case — which cannot arise without a registered
    /// daemon — earns a non-zero code.
    public let exit: Int32

    public init(raw: String, human: String, reachable: Bool?, exit: Int32) {
        self.raw = raw
        self.human = human
        self.reachable = reachable
        self.exit = exit
    }
}

public enum HelperHealth {
    /// The honest-status hint appended to `enabled` when the daemon is
    /// registered but does not answer XPC. Public so a test can assert on it.
    public static let unreachableHint = "unreachable — run 'eclam repair'"

    /// Pure mapping. `reachable` is the result of an XPC liveness probe (only
    /// meaningful, and only supplied, when `reg == .enabled`).
    public static func evaluate(reg: HelperReg, reachable: Bool?) -> HelperHealthVerdict {
        switch reg {
        case .enabled:
            if reachable == false {
                return HelperHealthVerdict(
                    raw: "enabled",
                    human: "enabled (\(unreachableHint))",
                    reachable: false,
                    exit: 2)
            }
            // reachable == true, or nil when the caller chose not to probe:
            // behave exactly as before (genuine `enabled`, exit 0).
            return HelperHealthVerdict(raw: "enabled", human: "enabled",
                                       reachable: reachable, exit: 0)
        case .requiresApproval:
            return HelperHealthVerdict(raw: "requiresApproval", human: "requiresApproval",
                                       reachable: nil, exit: 0)
        case .notRegistered:
            return HelperHealthVerdict(raw: "notRegistered", human: "notRegistered",
                                       reachable: nil, exit: 0)
        case .notFound:
            return HelperHealthVerdict(raw: "notFound", human: "notFound",
                                       reachable: nil, exit: 0)
        case .unknown:
            return HelperHealthVerdict(raw: "unknown", human: "unknown",
                                       reachable: nil, exit: 0)
        }
    }
}
