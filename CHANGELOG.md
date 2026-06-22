# Changelog

All notable changes to Electronic Clam are documented here.

## [0.6.0] — 2026-06-23

- **Open at login** — optional setting to launch Electronic Clam automatically when you log in (Settings → General). Off by default.
- **Update notifications** — checks GitHub for new releases and tells you when one is available (Settings → General; auto-check is on, opt out anytime). It only notifies and opens the download page — it never installs anything on its own.
- Stability: detection polling now runs off the main thread (fixes a rare crash under load), and the app detects and warns when an outdated helper is still running after an upgrade.

## [0.5.0] — 2026-06-15

First public release.

- Menu-bar toggle that keeps macOS awake — including with the lid closed — while work is live, and lets it sleep when conditions get risky
- Agent-aware activity detection for Claude Code, Codex, and other AI dev tools (extensible via `~/.config/eclam/traces.d/`)
- State-conditioned battery and thermal safety guards
- `eclam` command-line interface (`on` / `off` / `watch`) and remote-control activity awareness
- Multi-language UI: English, 한국어, 日本語, 简体中文, Español
- Opt-in Telegram status notifications (off by default)
- Developer ID signed + Apple notarized; install via Homebrew
