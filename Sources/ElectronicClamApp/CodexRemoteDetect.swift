import Foundation

/// Pure argv classifier for the Codex **remote-control daemon** (ADR-0031;
/// design + the blind-spot correction in
/// `docs/proposals/2026-06-14-session-class-detection.md`). Mirrors
/// `ClaudeRemoteDetect`: `RemoteWatcher` runs `ps -axww -o command` and feeds each
/// line here; this file does no I/O, so `scripts/test.sh` compiles it standalone.
///
/// Detection is **argv-only**. Observed live (Codex 149 standalone CLI,
/// 2026-06-14, after `codex remote-control start`):
///
///   daemon `…/.codex/packages/standalone/current/codex app-server --remote-control --listen unix://`
///   (sibling `…/codex app-server daemon pid-update-loop`)
///
/// vs the always-on desktop backend, which is **not** remote-control:
///
///   `/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled`
///   `…/codex app-server --listen stdio://`
///
/// The `--remote-control` flag is the discriminator. This **corrects** the
/// earlier "Codex is a blind spot" finding (ADR-0031 first draft): that draft
/// only inspected the always-on `app-server` — identical local vs mobile — and
/// missed the separate remote-control daemon `codex remote-control start` spawns.
/// The Electron desktop helpers (`Codex`, `Codex (Service)`,
/// `browser_crashpad_handler`) are not the lowercase `codex` CLI and lack the
/// flag, so they never match. A companion signal — the unix socket
/// `~/.codex/app-server-control/app-server-control.sock` — exists too, but argv
/// is tied to a live process (no stale-file risk), matching `ClaudeRemoteDetect`.
enum CodexRemoteDetect {

    enum SessionClass: String, Equatable {
        case daemon  // `codex app-server --remote-control` remote-control daemon
    }

    // MARK: - Classification

    /// Classify one process's full command line (argv joined by spaces, as
    /// `ps -o command` emits). Returns `nil` for the always-on desktop backend
    /// or any non-`codex`-CLI process.
    static func classify(command: String) -> SessionClass? {
        guard isCodexCLICommand(command) else { return nil }
        if hasArgToken(command, "--remote-control") { return .daemon }
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

    /// True iff the Codex remote-control daemon is present. `RemoteWatcher`
    /// consults this to raise the `codex-remote` channel.
    static func isRemoteControlActive(psCommandOutput: String) -> Bool {
        !scan(psCommandOutput: psCommandOutput).isEmpty
    }

    // MARK: - Internals

    /// The `codex` CLI/daemon binary (basename `codex`, case-sensitive). Covers
    /// both the standalone daemon (`…/.codex/packages/standalone/current/codex`)
    /// and the desktop-bundled CLI (`…/Codex.app/Contents/Resources/codex`); the
    /// `--remote-control` gate in `classify` is what separates the daemon from
    /// the always-on backend. The Electron helpers (`Codex`, capital `C`) fail
    /// this basename check.
    static func isCodexCLICommand(_ command: String) -> Bool {
        let argv0 = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        let base = (argv0 as NSString).lastPathComponent
        return base == "codex"
    }

    /// Whether `token` appears as a whitespace-delimited argv token (not a
    /// substring of a larger token/value).
    static func hasArgToken(_ command: String, _ token: String) -> Bool {
        command.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .contains { $0 == Substring(token) }
    }
}
