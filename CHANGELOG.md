# Changelog

All notable changes to Electronic Clam are documented here.

## [Unreleased]

- **Slack notifications (off by default)** — the same status pings that Telegram gets can now go to a Slack channel through a Slack app you create and own. **Settings → Notifications** holds both backends side by side; enable either one or both, and each keeps its own token, channel, and event checkboxes. Setup needs the `chat:write` bot scope (plus `channels:read` if you want to look up a channel by name instead of pasting its ID), and the bot has to be invited to the channel. Slack's API has no silent delivery, so the periodic status message arrives like any other one — mute the channel if you want it quiet. Nothing is sent until you turn it on, and nothing ever goes to the developer or a third-party server.

## [0.6.3] — 2026-07-02

- **Fix: attaching an external display no longer disturbs your saved arrangement** — with the clamshell lock guard turned on, the invisible anchor used to fight the topology change when you plugged in a real monitor, which could re-shuffle your saved built-in + external layout. It now steps aside immediately — no re-mirror — as soon as a real display appears, so macOS restores the arrangement you set, and the anchor returns automatically when you unplug the external. Headless clamshell lock protection is unchanged.

## [0.6.2] — 2026-07-01

- **Clamshell VPN lock guard (opt-in, off by default)** — with no external display on battery, closing the lid normally locks the screen, which drops a FortiClient SSL VPN and forces a fresh sign-in to reconnect. When you turn this on, Electronic Clam anchors the session to an invisible virtual display so the screen never locks and the tunnel survives. There's no backlight, so it draws essentially no power, and it needs no extra hardware or power adapter. It's a deliberately deep setting, off unless you go looking for it.
- **Blank screen — Dim or Sleep** — the "blank the displays" action now splits in two: **Dim** darkens the screen without locking it (VPN-safe, and the new default), while **Sleep** powers the display fully off and may lock the screen (you're warned before choosing it).
- **Optional VPN-disconnect notification** — if the VPN drops anyway, Electronic Clam can send a local notification and a Telegram message that a re-login is needed. Pick your VPN service from a dropdown; it only tells you — it never reconnects on its own.
- **More resilient helper setup** — Electronic Clam no longer tries to register its background helper from a quarantined download or a temporary (translocated) location where macOS would block it; instead it guides you to move the app into Applications first. Settings flags duplicate copies and version mismatches, and `eclam repair` recovers a helper that's wedged or unreachable.

## [0.6.1] — 2026-06-25

- **Honest helper status** — if the background helper that keeps your Mac awake is registered but isn't actually running, Electronic Clam now says so instead of reporting a false "On." `eclam status` reports it as `unreachable` (exit code 2), the menu bar shows a warning, and the app repairs itself the next time it launches.
- **`eclam repair`** — a new command-line command that recovers a wedged or unreachable helper.
- `eclam status` now also reports the "Open at login" state.

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
