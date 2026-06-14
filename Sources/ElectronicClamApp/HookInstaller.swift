import Foundation
import OSLog

/// Idempotent + reversible installer for Claude / Codex hooks (ADR-0006 §E).
///
/// Strategy: wrap our installation with sentinel markers and replace the block
/// in place. Existing user hooks are preserved; only our own block is touched.
///
///   Claude `~/.claude/settings.json`:
///     A top-level key `"_eclam_hook_version": N` plus entries in
///     `hooks.PreToolUse` / `hooks.PostToolUse` that we tag with
///     `"_eclam": true` so uninstall can filter them precisely. JSON
///     in/out via `JSONSerialization` — never via string templates.
///
///   Codex `~/.codex/config.toml`:
///     A literal text block delimited by
///       `# >>> eclam-hook v<N>`
///       `# <<< eclam-hook`
///     appended idempotently. No TOML parser — we slice on the markers.
///
///   Hermes `~/.hermes/config.yaml` (v0.3.2):
///     Same marker-block strategy as Codex — YAML accepts `#` comments natively.
///     We emit a `hooks:` map with `pre_tool_call` and `post_tool_call` arrays,
///     each holding a single entry with `matcher: ".*"` and our hook command.
///     If the user already had a top-level `hooks:` key outside our markers we
///     leave it untouched; this is documented as a known limitation rather than
///     attempted to merge (no YAML parser dep — ADR-0006 §E).
enum HookInstaller {

    enum Target: String, CaseIterable {
        case claude
        case codex
        case hermes

        var label: String {
            switch self {
            case .claude: return "Claude"
            case .codex:  return "Codex"
            case .hermes: return "Hermes"
            }
        }
    }

    enum HookError: LocalizedError {
        case bundleHookMissing
        case io(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .bundleHookMissing:
                return "Hook binary is missing from the app bundle (Contents/MacOS/eclam-hook)."
            case .io(let m):
                return "Filesystem error: \(m)"
            case .malformed(let m):
                return "Existing config could not be parsed: \(m)"
            }
        }
    }

    // MARK: - Constants
    //
    // The hook version, marker strings and JSON keys live in `HookConfigEditing`
    // (the pure, standalone-testable layer). Only the logger — which needs OSLog —
    // stays here.

    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "hook")

    // MARK: - Public API

    static func hookBinaryPath() -> String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/eclam-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static func isInstalled(_ target: Target) -> Bool {
        switch target {
        case .claude:
            guard let data = try? Data(contentsOf: settingsURL(target)),
                  let obj  = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else { return false }
            return HookConfigEditing.claudeInstalled(in: dict)
        case .codex, .hermes:
            guard let text = try? String(contentsOf: settingsURL(target), encoding: .utf8) else {
                return false
            }
            return HookConfigEditing.markerBlockPresent(in: text)
        }
    }

    static func install(_ target: Target) throws {
        guard let binPath = hookBinaryPath() else { throw HookError.bundleHookMissing }
        switch target {
        case .claude: try installClaude(hookBinary: binPath)
        case .codex:  try installCodex(hookBinary: binPath)
        case .hermes: try installHermes(hookBinary: binPath)
        }
        log.info("installed hook for \(target.rawValue, privacy: .public)")
    }

    static func uninstall(_ target: Target) throws {
        switch target {
        case .claude: try uninstallClaude()
        case .codex:  try uninstallCodex()
        case .hermes: try uninstallHermes()
        }
        log.info("uninstalled hook for \(target.rawValue, privacy: .public)")
    }

    // MARK: - Paths

    static func settingsURL(_ target: Target) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch target {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex:  return home.appendingPathComponent(".codex/config.toml")
        case .hermes: return home.appendingPathComponent(".hermes/config.yaml")
        }
    }

    private static func backupURL(_ url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    // MARK: - Claude

    private static func installClaude(hookBinary: String) throws {
        let url = settingsURL(.claude)
        try ensureParentDirectory(url)

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try readData(url)
            if !data.isEmpty {
                do {
                    let obj = try JSONSerialization.jsonObject(with: data, options: [])
                    guard let dict = obj as? [String: Any] else {
                        throw HookError.malformed("root is not a JSON object")
                    }
                    root = dict
                } catch let e as HookError {
                    throw e
                } catch {
                    throw HookError.malformed(error.localizedDescription)
                }
            }
            // One-time backup; never overwrite an existing .bak.
            if !FileManager.default.fileExists(atPath: backupURL(url).path) {
                try? FileManager.default.copyItem(at: url, to: backupURL(url))
            }
        }

        root = HookConfigEditing.claudeRoot(installingInto: root, hookBinary: hookBinary)

        let pretty = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(pretty, to: url)
    }

    private static func uninstallClaude() throws {
        let url = settingsURL(.claude)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try readData(url)
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any] else { return }

        let cleaned = HookConfigEditing.claudeRoot(uninstallingFrom: root)

        let pretty = try JSONSerialization.data(
            withJSONObject: cleaned,
            options: [.prettyPrinted, .sortedKeys])
        try writeAtomically(pretty, to: url)
    }

    // MARK: - Codex

    private static func installCodex(hookBinary: String) throws {
        let url = settingsURL(.codex)
        try ensureParentDirectory(url)

        var existing = ""
        if FileManager.default.fileExists(atPath: url.path) {
            existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !FileManager.default.fileExists(atPath: backupURL(url).path) {
                try? FileManager.default.copyItem(at: url, to: backupURL(url))
            }
        }

        let combined = HookConfigEditing.codexConfig(installingInto: existing, hookBinary: hookBinary)
        try writeAtomically(Data(combined.utf8), to: url)
    }

    private static func uninstallCodex() throws {
        let url = settingsURL(.codex)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let cleaned = HookConfigEditing.codexConfig(uninstallingFrom: text)
        try writeAtomically(Data(cleaned.utf8), to: url)
    }

    // MARK: - Hermes
    //
    // Hermes ships a real hook system (docs: hermes-agent.nousresearch.com/docs
    // /user-guide/features/hooks). Verified upstream facts (v0.3.2 install path
    // research, 2026-06-03):
    //   • Config: `~/.hermes/config.yaml` (single file, shell + plugin hooks
    //     share it). Top-level `hooks:` map keyed by event name.
    //   • Events used: `pre_tool_call`, `post_tool_call`. Each entry has
    //     `matcher`, `command`, optional `timeout`.
    //   • Feature flag: NONE. Hooks fire as soon as configured.
    //   • Trust gate: YES. First time Hermes sees a non-accepted hook command
    //     it prompts the user. Bypasses: `--accept-hooks`, env
    //     `HERMES_ACCEPT_HOOKS=1`, or top-level `hooks_auto_accept: true`.
    //     We do NOT set `hooks_auto_accept: true` for the user (that would
    //     blanket-accept *every* hook including third-party ones they later
    //     add) — they just approve our hook once at the CLI prompt.
    //
    // Strategy mirrors Codex: marker-block in YAML using native `#` comments.
    // No YAML parser dep. Hermes's own loader is permissive about multiple
    // documents/sections so an appended `hooks:` after a user's own one would
    // cause a duplicate key collision; we therefore *prepend* our block right
    // after the marker scan removes any prior copy of ours. If the user
    // already has a top-level `hooks:` key outside our markers, our install
    // appends ours after it which yields a YAML duplicate-key error on load.
    // That case is rare in practice (Hermes's default config has no hooks)
    // and surfaces as a startup error rather than silent breakage; ADR-0006
    // §E documents this as a known v0.3.2 limitation.

    private static func installHermes(hookBinary: String) throws {
        let url = settingsURL(.hermes)
        try ensureParentDirectory(url)

        var existing = ""
        if FileManager.default.fileExists(atPath: url.path) {
            existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !FileManager.default.fileExists(atPath: backupURL(url).path) {
                try? FileManager.default.copyItem(at: url, to: backupURL(url))
            }
        }

        // Marker stripping + assembly mirror Codex (both formats use `#` line
        // comments so the slicer works as-is); see HookConfigEditing.
        let combined = HookConfigEditing.hermesConfig(installingInto: existing, hookBinary: hookBinary)
        try writeAtomically(Data(combined.utf8), to: url)
    }

    private static func uninstallHermes() throws {
        let url = settingsURL(.hermes)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let cleaned = HookConfigEditing.hermesConfig(uninstallingFrom: text)
        try writeAtomically(Data(cleaned.utf8), to: url)
    }

    // MARK: - Helpers

    private static func ensureParentDirectory(_ url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw HookError.io("mkdir \(dir.path): \(error.localizedDescription)")
            }
        }
    }

    private static func readData(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw HookError.io("read \(url.path): \(error.localizedDescription)")
        }
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw HookError.io("write \(url.path): \(error.localizedDescription)")
        }
    }
}
