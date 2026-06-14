import Foundation

/// Pure config-text / JSON-object transforms extracted from `HookInstaller`
/// (ADR-0006 §E; ADR-0023 pure-policy precedent). Foundation-only — no OSLog,
/// no Bundle, no FileManager — so `scripts/test.sh` can compile it standalone
/// with its test program. `HookInstaller` keeps every filesystem side effect
/// (read / backup / JSON (de)serialize / atomic write) and delegates each
/// *content* decision here. Behaviour-preserving move: the logic below is a
/// verbatim lift of the former `HookInstaller` helpers. Covered by
/// `Tests/HookConfigEditingTests.swift`.
enum HookConfigEditing {

    // MARK: - Constants (single source of truth; HookInstaller reads these)

    static let version = 3
    static let markerBegin = "# >>> eclam-hook"
    static let markerEnd   = "# <<< eclam-hook"
    static let featuresInlineMarker = "# eclam-hook"
    static let jsonVersionKey = "_eclam_hook_version"
    static let jsonTagKey     = "_eclam"

    // MARK: - Command wrapping

    /// Shell wrapper used by every platform's installed hook command. If the
    /// app was deleted but the hook entry is still in the agent's config, the
    /// `test -x` branch fails and we exit 0 silently — agents see a clean
    /// no-op instead of ENOENT noise. This is "C" of the v0.3.3 cleanup story;
    /// real config removal is handled by the Settings "Uninstall all hooks"
    /// button (B) and the brew cask uninstall_preflight stanza (A).
    static func wrappedCommand(hookBinary: String, source: String) -> String {
        let q = shellQuote(hookBinary)
        return "test -x \(q) && exec \(q) \(source) || true"
    }

    /// POSIX shell-safe single-quoting for paths.
    static func shellQuote(_ s: String) -> String {
        // Wrap in single quotes; escape any single quotes as '\''
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Claude (JSON object transforms)

    static func claudeEntry(hookBinary: String, phase: String) -> [String: Any] {
        // Generic catch-all matcher; phase encoded in argv so daemon can distinguish.
        return [
            jsonTagKey: true,
            "matcher": ".*",
            "hooks": [[
                "type": "command",
                "command": wrappedCommand(hookBinary: hookBinary, source: "claude.\(phase)"),
            ]],
        ]
    }

    static func replaceElectronicClamEntries(in raw: Any?, with new: [String: Any]) -> [Any] {
        var arr = raw as? [Any] ?? []
        arr.removeAll { ($0 as? [String: Any])?[jsonTagKey] as? Bool == true }
        arr.append(new)
        return arr
    }

    static func stripElectronicClamEntries(in raw: Any?) -> [Any] {
        var arr = raw as? [Any] ?? []
        arr.removeAll { ($0 as? [String: Any])?[jsonTagKey] as? Bool == true }
        return arr
    }

    /// Whole-object install transform: given the parsed `settings.json` root,
    /// return it with our Pre/PostToolUse entries (re)inserted and the version
    /// key stamped. Idempotent — a prior eclam entry is replaced, not
    /// duplicated. JSON (de)serialization stays in `HookInstaller`.
    static func claudeRoot(installingInto root: [String: Any], hookBinary: String) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks["PreToolUse"]  = replaceElectronicClamEntries(in: hooks["PreToolUse"],
                                                            with: claudeEntry(hookBinary: hookBinary,
                                                                              phase: "pre"))
        hooks["PostToolUse"] = replaceElectronicClamEntries(in: hooks["PostToolUse"],
                                                            with: claudeEntry(hookBinary: hookBinary,
                                                                              phase: "post"))
        root["hooks"] = hooks
        root[jsonVersionKey] = version
        return root
    }

    /// Whole-object uninstall transform: strip our entries + version key, and
    /// drop now-empty containers (arrays, then the `hooks` map).
    static func claudeRoot(uninstallingFrom root: [String: Any]) -> [String: Any] {
        var root = root
        root.removeValue(forKey: jsonVersionKey)
        if var hooks = root["hooks"] as? [String: Any] {
            hooks["PreToolUse"]  = stripElectronicClamEntries(in: hooks["PreToolUse"])
            hooks["PostToolUse"] = stripElectronicClamEntries(in: hooks["PostToolUse"])
            // Drop now-empty arrays.
            if (hooks["PreToolUse"]  as? [Any])?.isEmpty == true { hooks.removeValue(forKey: "PreToolUse") }
            if (hooks["PostToolUse"] as? [Any])?.isEmpty == true { hooks.removeValue(forKey: "PostToolUse") }
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
        }
        return root
    }

    /// `isInstalled(.claude)` predicate over an already-parsed root: true iff our
    /// version key is present.
    static func claudeInstalled(in root: [String: Any]) -> Bool {
        root[jsonVersionKey] as? Int != nil
    }

    // MARK: - Codex (TOML text transforms)

    /// ADR-0006 §I — exact 4-element Codex hook block:
    ///   [features]                  (optional — only when caller's TOML had none)
    ///   hooks = true
    ///   [[hooks.PreToolUse]]
    ///   matcher = ".*"
    ///   [[hooks.PreToolUse.hooks]]  ← inner table, required
    ///   type = "command"            ← required field
    ///   command = "..."
    /// Same shape for PostToolUse.
    static func codexBlock(hookBinary: String, includeFeaturesSection: Bool) -> String {
        var lines: [String] = []
        lines.append("\(markerBegin) v\(version)")
        if includeFeaturesSection {
            lines.append("[features]")
            lines.append("hooks = true")
            lines.append("")
        }
        lines.append("[[hooks.PreToolUse]]")
        lines.append("matcher = \".*\"")
        lines.append("")
        let preCmd  = wrappedCommand(hookBinary: hookBinary, source: "codex.pre")
        let postCmd = wrappedCommand(hookBinary: hookBinary, source: "codex.post")
        lines.append("[[hooks.PreToolUse.hooks]]")
        lines.append("type = \"command\"")
        lines.append("command = \"\(preCmd)\"")
        lines.append("")
        lines.append("[[hooks.PostToolUse]]")
        lines.append("matcher = \".*\"")
        lines.append("")
        lines.append("[[hooks.PostToolUse.hooks]]")
        lines.append("type = \"command\"")
        lines.append("command = \"\(postCmd)\"")
        lines.append(markerEnd)
        return lines.joined(separator: "\n")
    }

    /// Removes the first marker..end block found. Idempotent if none present.
    /// Shared by Codex (TOML) and Hermes (YAML) — both use `#` line comments.
    static func stripCodexBlock(_ text: String) -> String {
        guard let beginRange = text.range(of: markerBegin) else { return text }
        // End marker must appear AFTER begin.
        guard let endRange = text.range(of: markerEnd, range: beginRange.upperBound..<text.endIndex) else {
            // Malformed: drop from begin to EOF to recover.
            return String(text[..<beginRange.lowerBound])
        }
        // Trim surrounding blank lines for cleanliness.
        var before = String(text[..<beginRange.lowerBound])
        var after  = String(text[endRange.upperBound...])
        while before.hasSuffix("\n\n") { before.removeLast() }
        while after.hasPrefix("\n")    { after.removeFirst() }
        return before + after
    }

    /// If the caller already declared `[features]`, inject `hooks = true` into
    /// that section (idempotent). Returns the rewritten text and whether an
    /// existing `[features]` section was found.
    ///
    /// ADR-0006 §I — duplicate `[features]` header is a TOML parse error, so
    /// we MUST NOT emit our own when one already exists.
    static func mergeFeaturesHooksFlag(_ text: String) -> (String, Bool) {
        // Multiline regex: ^\s*\[features\]\s*$
        // Detect via line-by-line scan to avoid regex literal portability concerns.
        var lines = text.components(separatedBy: "\n")
        var headerIdx: Int?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[features]" {
                headerIdx = i
                break
            }
        }
        guard let start = headerIdx else { return (text, false) }

        // Section ends at next `[…]` header or EOF.
        var end = lines.count
        for j in (start + 1)..<lines.count {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && t.hasSuffix("]") {
                end = j
                break
            }
        }

        // Already present?
        for j in (start + 1)..<end {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            // Accept either `hooks = true` or pre-injected variant.
            if t.hasPrefix("hooks") {
                // Naive but safe: anything starting with `hooks` inside [features]
                // (e.g. `hooks = true`, `hooks=true`, `hooks =  true # comment`) → skip.
                return (text, true)
            }
        }

        // Insert immediately after header.
        let injected = "hooks = true  \(featuresInlineMarker)"
        lines.insert(injected, at: start + 1)
        return (lines.joined(separator: "\n"), true)
    }

    /// Inverse of `mergeFeaturesHooksFlag`: removes our injected
    /// `hooks = true  # eclam-hook` line. Lines we didn't inject (the
    /// user's own `hooks = true`) are left alone — there's no safe way to tell
    /// them apart without the marker comment.
    static func removeInjectedFeaturesFlag(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("hooks") && t.contains(featuresInlineMarker)
        }
        return lines.joined(separator: "\n")
    }

    /// Whole-text install transform for Codex `config.toml`: strip any prior
    /// marker block, merge `hooks = true` into a pre-existing `[features]`
    /// section (else emit our own), append a fresh marker block.
    static func codexConfig(installingInto existing: String, hookBinary: String) -> String {
        // 1. Drop any prior marker block (idempotent reinstall).
        let stripped = stripCodexBlock(existing)
        // 2. Merge `hooks = true` into pre-existing `[features]` section if any.
        let (afterFeaturesMerge, hasFeaturesSection) = mergeFeaturesHooksFlag(stripped)
        // 3. Emit a fresh marker block — include our own `[features]` only when the
        //    user did not already declare one (TOML forbids duplicate headers).
        let block = codexBlock(hookBinary: hookBinary, includeFeaturesSection: !hasFeaturesSection)

        if afterFeaturesMerge.isEmpty {
            return block + "\n"
        } else if afterFeaturesMerge.hasSuffix("\n") {
            return afterFeaturesMerge + "\n" + block + "\n"
        } else {
            return afterFeaturesMerge + "\n\n" + block + "\n"
        }
    }

    /// Whole-text uninstall transform for Codex `config.toml`: drop the marker
    /// block and our inline-injected `[features]` flag.
    static func codexConfig(uninstallingFrom text: String) -> String {
        let stripped = stripCodexBlock(text)
        // Also remove our inline-injected `hooks = true # eclam-hook` line, if
        // the install path injected it into a pre-existing `[features]` section.
        return removeInjectedFeaturesFlag(stripped)
    }

    // MARK: - Hermes (YAML text transforms)

    /// Hermes YAML block. The `hooks:` key is the top-level Hermes config key
    /// that holds event→entry-array mappings. Each entry needs a `matcher` and
    /// `command`; we pick `.*` so every tool call routes through us, matching
    /// the Claude/Codex installer convention. Sources `hermes.pre`/`hermes.post`
    /// keep ActivityRelay's existing source-routing table happy without changes.
    static func hermesBlock(hookBinary: String) -> String {
        let preCmd  = wrappedCommand(hookBinary: hookBinary, source: "hermes.pre")
        let postCmd = wrappedCommand(hookBinary: hookBinary, source: "hermes.post")
        var lines: [String] = []
        lines.append("\(markerBegin) v\(version)")
        lines.append("hooks:")
        lines.append("  pre_tool_call:")
        lines.append("    - matcher: \".*\"")
        lines.append("      command: \"\(preCmd)\"")
        lines.append("  post_tool_call:")
        lines.append("    - matcher: \".*\"")
        lines.append("      command: \"\(postCmd)\"")
        lines.append(markerEnd)
        return lines.joined(separator: "\n")
    }

    /// Whole-text install transform for Hermes `config.yaml`: strip any prior
    /// marker block (same slicer as Codex — both use `#` comments), append ours.
    static func hermesConfig(installingInto existing: String, hookBinary: String) -> String {
        let stripped = stripCodexBlock(existing)
        let block = hermesBlock(hookBinary: hookBinary)
        if stripped.isEmpty {
            return block + "\n"
        } else if stripped.hasSuffix("\n") {
            return stripped + "\n" + block + "\n"
        } else {
            return stripped + "\n\n" + block + "\n"
        }
    }

    /// Whole-text uninstall transform for Hermes `config.yaml`: drop the marker
    /// block.
    static func hermesConfig(uninstallingFrom text: String) -> String {
        stripCodexBlock(text)
    }

    // MARK: - Marker presence (isInstalled over already-read text)

    /// `isInstalled(.codex/.hermes)` predicate over already-read config text.
    static func markerBlockPresent(in text: String) -> Bool {
        text.contains(markerBegin) && text.contains(markerEnd)
    }
}
