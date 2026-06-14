import Foundation

/// Pure activity-decision layer extracted from `AgentDetector.evaluateTrace`
/// (ADR-0006 §A/§C/§J/§L; ADR-0023 pure-policy precedent). `AgentDetector` owns
/// every side effect — hook-ping dictionary lookup, PID-file directory scan,
/// glob+`stat` mtime probing, `ps`/`lsof` for live Claude cwds — and feeds the
/// *already-resolved signals* here. This file imports Foundation only for
/// `TimeInterval` and is compiled standalone by `scripts/test.sh`.
///
/// The two channels are kept separate to preserve `evaluateTrace`'s short-circuit:
/// the hook/PID-file channel decides first and, when it fires, the caller never
/// performs the mtime glob/`stat` (so the resulting debug row keeps `latestMatch`
/// / `mtimeAge` nil exactly as before). `decide(...)` composes both for tests
/// and any caller that has resolved all signals up front.
enum AgentActivity {

    /// Outcome of a single channel: active or not, plus the human-readable
    /// `reason` surfaced verbatim in `AgentDetectorDebugSnapshot.TraceRow`
    /// (`debug agents`). Reason strings are part of the observable contract.
    struct Decision: Equatable {
        let active: Bool
        let reason: String
    }

    /// Freshest glob match for a trace: the matched path and its mtime age.
    struct MtimeMatch: Equatable {
        let path: String
        let age: TimeInterval
    }

    // MARK: - Hook / PID-file channel (ADR-0006 §A / §L)

    /// Hook-ping (Darwin notify) ∨ PID-file fallback. Returns a decision (always
    /// active) when either signal is live, or `nil` to fall through to the
    /// mtime channel. Only consulted for traces that declare a `hookKey`.
    ///
    /// - `hookPingAge`: age of the most recent hook ping for this source
    ///   (`nil` ⇒ never pinged). Active iff `≤ hookGrace`.
    /// - `pidFilePresent`: a fresh PID-file exists for this source.
    static func hookDecision(hookPingAge: TimeInterval?,
                             hookGrace: TimeInterval,
                             pidFilePresent: Bool) -> Decision? {
        if let age = hookPingAge, age <= hookGrace {
            return Decision(active: true, reason: "hook-ping (\(Int(age))s)")
        }
        if pidFilePresent {
            return Decision(active: true, reason: "pidfile-ping")
        }
        return nil
    }

    // MARK: - File-mtime channel (ADR-0006 §C / §J)

    /// File-mtime freshness with Claude workspace pairing.
    ///
    /// - `mtimeMatch`: freshest glob match (`nil` ⇒ no file matched).
    /// - `freshness`: per-trace staleness cut; active iff `age ≤ freshness`.
    /// - `isClaude`: the `claude` trace requires §J workspace pairing.
    /// - `liveClaudeEmpty`: `ps`/`lsof` unavailable ⇒ permissive fallback (treat
    ///   a fresh match as active without pairing).
    /// - `claudeCwdMatched` / `claudeSegment`: pairing result — the matched
    ///   path's project segment is the cwd of a live `claude` process.
    static func mtimeDecision(mtimeMatch: MtimeMatch?,
                              freshness: TimeInterval,
                              isClaude: Bool,
                              liveClaudeEmpty: Bool,
                              claudeCwdMatched: Bool,
                              claudeSegment: String?) -> Decision {
        guard let m = mtimeMatch else {
            return Decision(active: false, reason: "no-match")
        }
        if m.age > freshness {
            return Decision(active: false, reason: "stale")
        }
        if isClaude {
            // §J workspace pairing — require the matched path's project segment
            // to correspond to a live `claude` process cwd.
            if liveClaudeEmpty {
                // Fallback: treat as active (ps/lsof unavailable).
                return Decision(active: true,
                                reason: "mtime-fresh (claude pairing skipped — ps/lsof unavailable)")
            }
            if claudeCwdMatched, let seg = claudeSegment {
                return Decision(active: true, reason: "mtime-fresh + cwd \(seg)")
            }
            return Decision(active: false, reason: "mtime-fresh but no live cwd match")
        }
        return Decision(active: true, reason: "mtime-fresh")
    }

    // MARK: - Composed decision (hook channel short-circuits the mtime channel)

    /// Full evaluation with all signals resolved up front. Mirrors
    /// `evaluateTrace`: the hook/PID-file channel decides first (only when
    /// `hasHookKey`), otherwise the mtime channel decides.
    static func decide(hasHookKey: Bool,
                       hookPingAge: TimeInterval?,
                       hookGrace: TimeInterval,
                       pidFilePresent: Bool,
                       mtimeMatch: MtimeMatch?,
                       freshness: TimeInterval,
                       isClaude: Bool,
                       liveClaudeEmpty: Bool,
                       claudeCwdMatched: Bool,
                       claudeSegment: String?) -> Decision {
        if hasHookKey,
           let hook = hookDecision(hookPingAge: hookPingAge,
                                   hookGrace: hookGrace,
                                   pidFilePresent: pidFilePresent) {
            return hook
        }
        return mtimeDecision(mtimeMatch: mtimeMatch,
                             freshness: freshness,
                             isClaude: isClaude,
                             liveClaudeEmpty: liveClaudeEmpty,
                             claudeCwdMatched: claudeCwdMatched,
                             claudeSegment: claudeSegment)
    }
}
