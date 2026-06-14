# Community agent traces

Electronic Clam detects "an agent is working" by watching files the agent
writes during a session (ADR-0006). Built-in traces live in
`Sources/Shared/AgentTrace.swift`; **you can add new agents without touching
code** by dropping a JSON file into:

```
~/.config/eclam/traces.d/<name>.json
```

Format — one object or an array of objects, same fields as `AgentTrace`:

```json
{
  "id": "gemini-cli",
  "label": "Gemini CLI",
  "globPattern": "~/.gemini/tmp/*/logs.json",
  "freshness": 60,
  "comm": "gemini"
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | ✅ | lowercase `[a-z0-9_-.]` — used in menus, `status --json`, hooks |
| `label` | ✅ | display name |
| `globPattern` | ✅ | POSIX glob (`*`/`?` only, no `**`); `~` expands |
| `freshness` | – | seconds an mtime counts as "active" (default 60) |
| `hookKey` | – | only if the agent pushes `eclam-hook` signals |
| `comm` | – | process basename for Lax mode (`ps -axo comm`) |

Verify with **Settings → Agents → Detect Now…** (or `eclam debug agents`),
then enable the agent in the Watch list.

To contribute a trace upstream, open a PR adding it under `traces/community/`
with a note on how you verified it (see CONTRIBUTING.md).
