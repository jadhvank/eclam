import Foundation

/// Pure argv classifier for Claude Code **remote-control** sessions (ADR-0031;
/// design in `docs/proposals/2026-06-14-session-class-detection.md`).
/// `RemoteWatcher` runs `ps -axww -o command` and feeds each line here; this file
/// does no I/O, so `scripts/test.sh` compiles it standalone.
///
/// Detection is **argv-only** — an eclam invariant: no transcript contents, no
/// network snooping (the same posture `AgentDetector` already takes with `ps`).
/// Signatures observed live (Claude `2.1.x`, 2026-06-14):
///
///   host   `claude remote-control --name … --spawn … --capacity …`
///   worker `…/claude/versions/<v> --print --sdk-url …/v1/code/sessions/cse_… \
///           --session-id cse_… --replay-user-messages`
///   local  `claude`, `claude --resume <uuid>`              ← NOT remote
///
/// Case- and path-sensitive **on purpose**: the Electron desktop app must NOT
/// match. Its processes are `/Applications/Claude.app/…/Claude` (capital `C`, no
/// `/claude/versions/`), its crashpad/helper argv carry `…productName=Claude`,
/// and a renderer's argv contains `coworkRemoteSessionSpaces` — none of which are
/// the lowercase `claude` CLI or the `remote-control` argv token. Codex mobile has
/// no comparable cmdline/socket signature (proposal §"Codex mobile"), so it stays
/// a blind spot by design rather than a flaky heuristic.
enum ClaudeRemoteDetect {

    enum SessionClass: String, Equatable {
        case host    // `claude remote-control` coordinator/host
        case worker  // remote-driven spawned worker (code session over the SDK)
    }

    // MARK: - Classification

    /// Classify one process's full command line (argv joined by spaces, as
    /// `ps -o command` emits). Returns `nil` for local-interactive Claude or any
    /// non-Claude-CLI process.
    static func classify(command: String) -> SessionClass? {
        guard isClaudeCLICommand(command) else { return nil }
        // Host: the coordinator the user starts to accept remote connections.
        if hasArgToken(command, "remote-control") { return .host }
        // Worker: a remote session driven over the code-sessions SDK. The
        // sdk-url path segment is the strongest marker; the `cse_` session id is
        // a fallback should the url shape drift.
        if command.contains("/v1/code/sessions/") { return .worker }
        if command.contains("cse_") && hasArgToken(command, "--session-id") { return .worker }
        return nil
    }

    /// Every remote-control class present in a multi-line `ps` dump.
    static func scan(psCommandOutput: String) -> Set<SessionClass> {
        var out: Set<SessionClass> = []
        psCommandOutput.enumerateLines { line, _ in
            if let cls = classify(command: line) { out.insert(cls) }
        }
        return out
    }

    /// True iff at least one remote-control session (host or worker) is present.
    /// This is what `RemoteWatcher` consults to raise the `claude-remote` channel.
    static func isRemoteControlActive(psCommandOutput: String) -> Bool {
        !scan(psCommandOutput: psCommandOutput).isEmpty
    }

    // MARK: - Internals

    /// The Claude **CLI** (`claude`), not the Electron desktop app (`Claude`).
    /// True iff argv[0]'s basename is `claude`/`claude-code` (case-sensitive
    /// lowercase) or the command contains the native-installer relaunch path
    /// `…/claude/versions/<semver>`.
    static func isClaudeCLICommand(_ command: String) -> Bool {
        if command.contains("/claude/versions/") { return true }
        // argv[0] is the substring up to the first whitespace. CLI argv[0]
        // (`claude` / a `…/versions/<semver>` path) never contains a space; the
        // desktop app's space-bearing bundle path falls out as a capital-`C`
        // basename and is rejected below.
        let argv0 = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        let base = (argv0 as NSString).lastPathComponent
        return base == "claude" || base == "claude-code"
    }

    /// Whether `token` appears as a whitespace-delimited argv token (not as a
    /// substring of some larger token/value). Keeps `remote-control` from
    /// matching inside an unrelated `--foo=remote-control-x` value.
    static func hasArgToken(_ command: String, _ token: String) -> Bool {
        command.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .contains { $0 == Substring(token) }
    }
}
