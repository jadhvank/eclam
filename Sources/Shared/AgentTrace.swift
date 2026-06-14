import Foundation

/// Single source of truth for "is this agent active?" detection (ADR-0006 §G).
/// One `AgentTrace` per detection rule. Glob expansion + mtime probe happens
/// in `AgentDetector` on the app side. The daemon side never sees this struct.
public struct AgentTrace: Codable, Equatable, Hashable {
    /// Stable lowercase key, e.g. `"claude"`. Used for UserDefaults keys,
    /// Darwin notify name (`com.jadhvank.eclam.activity.<id>`) and as
    /// the wire `source` string passed to `pingActivity`.
    public let id: String

    /// English UI label, e.g. `"Claude"`. ADR-0005 §5: UI is English-only in M1.
    public let label: String

    /// Glob pattern. May contain `~` for home expansion; `**` is NOT supported
    /// (we use POSIX `glob(3)`). Wildcards are limited to `*` and `?`.
    public let globPattern: String

    /// Minimum mtime freshness for a match to count as "active". ADR-0006 §C
    /// recommends 60s.
    public let freshness: TimeInterval

    /// Hook source identifier (`"claude"` / `"codex"`). nil ⇒ no hook integration,
    /// only file-mtime polling. ADR-0006 §B.
    public let hookKey: String?

    /// Expected `comm` basename of the agent's standalone foreground process,
    /// consulted by Lax mode's process-alive probe (`LaxProcessAlive`). nil ⇒
    /// no standalone process exists (e.g. VS Code extensions), so the entry
    /// can never contribute to Lax mode. Single source of truth — the old
    /// hand-maintained `LaxProcessAlive.mapping` drifted (cursor-cli /
    /// opencode-sessions were missing). Optional + defaulted so persisted
    /// `CustomAgentTraces` JSON from older versions still decodes.
    public let comm: String?

    public init(id: String,
                label: String,
                globPattern: String,
                freshness: TimeInterval = 60,
                hookKey: String? = nil,
                comm: String? = nil) {
        self.id = id
        self.label = label
        self.globPattern = globPattern
        self.freshness = freshness
        self.hookKey = hookKey
        self.comm = comm
    }
}

public extension AgentTrace {
    /// Agents auto-detected by default (watched-by-default via
    /// `StateStore.defaultWatchedAgents`, which derives from this list). v0.5 —
    /// high-confidence set: claude/codex (hook) + cursor + opencode. v0.5.x —
    /// cursor & antigravity glob paths corrected and antigravity promoted here
    /// after live measurement (2026-06-11; see memory:agent-trace-path-audit and
    /// ADR-0006 §B v0.5.x). ADR-0006 §B.
    static let M1Defaults: [AgentTrace] = [
        AgentTrace(
            id: "claude",
            label: "Claude",
            globPattern: "~/.claude/projects/*/*.jsonl",
            freshness: 60,
            hookKey: "claude",
            comm: "claude"
        ),
        AgentTrace(
            id: "codex",
            label: "Codex",
            globPattern: "~/.codex/sessions/*/*/*/rollout-*.jsonl",
            freshness: 60,
            hookKey: "codex",
            comm: "codex"
        ),
        // v0.5.x — live-measured (Cursor 3.7.27, Agent mode, 2026-06-11). GUI shares
        // `~/.cursor` with the cursor-agent CLI, so this single glob covers both.
        // Per-turn append-in-place, idle-stale (0 noise in 75s). Path corrected from
        // the dead `~/.cursor/cli-logs/*.json` (never matched on any machine).
        // freshness 90: a single >60s tool call can leave a no-signal gap.
        AgentTrace(
            id: "cursor",
            label: "Cursor",
            globPattern: "~/.cursor/projects/*/agent-transcripts/*/*.jsonl",
            freshness: 90,
            hookKey: nil,
            comm: "cursor-agent"  // ~/.local/bin/cursor-agent (실측 2026-06-11)
        ),
        AgentTrace(
            id: "opencode",
            label: "opencode (log)",
            globPattern: "~/.local/share/opencode/log/*.log",
            freshness: 60,
            hookKey: nil,
            comm: "opencode"
        ),
        // sister entry: opencode writes a per-session metadata json each turn;
        // the log file misses some sandboxed setups, this path is stable. Union.
        AgentTrace(
            id: "opencode-sessions",
            label: "opencode (sessions)",
            globPattern: "~/.local/share/opencode/storage/session-metadata/*/*.json",
            freshness: 60,
            hookKey: nil,
            comm: "opencode"  // same standalone binary as the log-file trace
        ),
        // v0.5.x — live-measured (Antigravity 2.0.11, 2026-06-11). Per-turn append
        // to the active conversation's transcript; verified across Agent Manager
        // parallel / dynamic-subagent / `/schedule` modes (worst integrated gap 55s,
        // < freshness 90). `.system_generated` is a literal hidden dir — glob(3)
        // traverses it only as a literal (a bare `*` would NOT), confirmed. Promoted
        // from CustomizeOnly; corrected from the dead `~/.gemini/antigravity-cli/…`.
        AgentTrace(
            id: "antigravity",
            label: "Antigravity",
            globPattern: "~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl",
            freshness: 90,
            hookKey: nil,
            comm: "agy"
        ),
    ]

    /// Customize-only entries (no default check). ADR-0006 §B.
    /// User explicitly enables in Settings → Agents. v0.5 — demoted from defaults
    /// (path detection unverified); detection rules preserved, just off by default.
    static let CustomizeOnly: [AgentTrace] = [
        AgentTrace(
            id: "aider",
            label: "Aider",
            // CWD-scoped; user can override per-project via Customize…
            globPattern: "~/.aider.chat.history.md",
            freshness: 60,
            hookKey: nil,
            comm: "aider"
        ),
        AgentTrace(
            id: "cline",
            label: "Cline",
            globPattern: "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/*/api_conversation_history.json",
            freshness: 60,
            hookKey: nil,
            comm: nil  // VS Code extension; no standalone process
        ),
        AgentTrace(
            id: "roo",
            label: "Roo Code",
            globPattern: "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks/*",
            freshness: 60,
            hookKey: nil,
            comm: nil  // VS Code extension; no standalone process
        ),
        AgentTrace(
            id: "openhands",
            label: "OpenHands",
            globPattern: "~/.openhands/sessions/*/events/event-*.json",
            freshness: 60,
            hookKey: nil,
            comm: "openhands"
        ),
        AgentTrace(
            id: "hermes",
            label: "Hermes",
            globPattern: "~/.hermes/logs/agent.log",
            freshness: 60,
            hookKey: "hermes",  // pre_tool_call / post_tool_call shell hook (M3 auto-install)
            comm: "hermes"
        ),
        // v0.5.x — path corrected from source (openclaw/openclaw
        // `backup-volatile-filter.ts`, `jsonl-repo.ts`): files live at
        // `<stateDir>/agents/<agentId>/sessions/<encodeCwd>/<ts>_<id>.jsonl`, i.e.
        // one directory deeper than the old `agents/*/sessions/*.jsonl` (never
        // matched — off by one). `openclaw-legacy` covers the pre-multi-agent root.
        AgentTrace(
            id: "openclaw",
            label: "Openclaw",
            globPattern: "~/.openclaw/agents/*/sessions/*/*.jsonl",
            freshness: 60,
            hookKey: nil,
            comm: "openclaw"
        ),
        AgentTrace(
            id: "openclaw-legacy",
            label: "Openclaw (legacy)",
            globPattern: "~/.openclaw/sessions/*/*.jsonl",
            freshness: 60,
            hookKey: nil,
            comm: "openclaw"
        ),
        // Cursor legacy transcript layout (older cursor-agent: flat `<uuid>.txt`
        // directly under agent-transcripts, vs current `<uuid>/<uuid>.jsonl`).
        // CustomizeOnly — only old Cursor versions; current builds use `cursor`.
        AgentTrace(
            id: "cursor-legacy",
            label: "Cursor (legacy)",
            globPattern: "~/.cursor/projects/*/agent-transcripts/*.txt",
            freshness: 90,
            hookKey: nil,
            comm: "cursor-agent"
        ),
    ]

    /// Seed allowlist for Customize autocompletion. ADR-0006 §H.
    /// 40+ entries from caffeinagent.com landing.
    static let SeedAllowlist: [String] = [
        "Claude Code", "Codex", "Opencode", "Cursor agent", "Gemini CLI",
        "Aider", "Amp", "Crush", "Goose", "Cline", "Windsurf", "OpenHands",
        "Forge", "Junie", "Roo Code", "Tabnine CLI", "Zencode", "Trae",
        "Qwen Code", "Qoder", "Continue", "Codebuddy", "Codestudio",
        "Codemaker", "Antigravity", "Mistral Vibe", "Devin", "Droid",
        "Augment", "Firebender", "Hermes", "Iflow", "Kilo", "Kiro CLI",
        "Mcpjam", "Pochi", "Rovodev", "Deepagents", "Neovate", "Command Code+",
    ]
}
