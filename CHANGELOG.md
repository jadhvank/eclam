# Changelog

All notable changes to Electronic Clam are documented here.

## [0.6.5] — 2026-09-01

- **Fix: mirroring a TV works again with the clamshell lock guard on** — connecting a display in *mirror* mode (a mirrored TV, AirPlay) would often fail to connect, while connecting a monitor as an *extended* display worked fine. The guard simply could not see mirrored displays: macOS drops the members of a hardware mirror set from the active-display list and reports the whole mirror set as a single screen, and both of the guard's checks relied on exactly those two signals. So while macOS was negotiating the mirror session, the invisible anchor kept re-mirroring itself and kept getting re-created after each teardown, fighting the very handover it should have stepped aside for. Both checks now share one implementation based on the *online* display list, which sees mirror-set members.
- **Fix: the guard no longer strands a virtual display** — creating the anchor while a mirror set was active produced a virtual display that never appeared while the app was running and then showed up *after* the app quit, with no owner left to release it. Once that happened, no further virtual display could be created for the rest of the login session, silently disabling the lock guard until you logged out. The anchor is now never created while a real external display is attached or a mirror set is active.
- **Fix: menu bar icon troubleshooting** — when macOS refuses to place the icon in the menu bar (on macOS 26 this is usually the menu bar allow-list, which a menu bar organiser can leave broken), Electronic Clam now opens Settings and explains the real cause instead of retrying something it cannot fix. The `eclam` command works regardless.
- **Fix: quarantined-in-place installs** — an app already sitting in `/Applications` but still carrying the download quarantine flag used to repeat a dead-end "move me to Applications" prompt. It now shows the actual cause and the one command that clears it.
- **Change: thermal cutoff now defaults to `serious`** — the old `fair` default was low enough to end a keep-awake session within minutes on a warm machine. Existing settings are migrated once.
- Settings: fixed the tab focus ring geometry and text input in the custom-agent dialog (thanks [@LKRCharon](https://github.com/LKRCharon), [#1](https://github.com/jadhvank/eclam/pull/1)).

## [0.6.4] — 2026-07-04

- **Fix: the VPN-disconnect notification now actually fires** — the watcher was tied to the keep-awake lifecycle, so the very event it was meant to report (the screen locking and the tunnel dropping) also switched the watcher off, and it lost the transition every time. It now polls on its own opt-in, survives App Nap and sleep/wake, and picks the FortiClient service correctly instead of matching an unrelated VPN.
- **Fix: the invisible anchor is released when you quit** — the virtual display could outlive the app because its teardown was queued and then abandoned mid-flight. It is now drained before the process exits. The display is also named more clearly; macOS showing a mirror set as two rows in System Settings is normal and does not mean there are two displays.
- **Fix: brightness is restored after Dim** — reopening the lid after the screen was dimmed could leave it stuck at minimum brightness, because the display identifier captured on the way in is stale after a clamshell close/reopen. It is now re-resolved at restore time, with retries and wake-event handling.

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
