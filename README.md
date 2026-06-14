<div align="center">

<img src="docs/assets/eclam-icon.png" width="120" alt="Electronic Clam" />

# Electronic Clam

**Agents must keep working — your Mac shouldn't cook trying.**
It detects *work*, not just a running process.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Language](https://img.shields.io/badge/Swift-AppKit%20%2B%20IOKit-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.5.0-yellow)](CHANGELOG.md)

<!-- i18n-langbar -->
**English** · [한국어](README.ko.md) · [中文](README.zh-CN.md) · [日本語](README.ja.md) · [Español](README.es.md)

![Electronic Clam menu demo](docs/assets/eclam-menu-demo.gif)

</div>

---

## Highlights

- **Lid-closed keep-awake.** One toggle stops your Mac from sleeping even with the lid shut — no terminal commands, no password per toggle.
- **Detects work, not processes.** Stays awake only while a coding agent is *actively producing output*; once the agent stops, your Mac can sleep again.
- **5 agents out of the box** — Claude Code, Codex, Cursor, opencode, Antigravity — plus any others you add yourself.
- **Safety guards that adapt.** Auto-sleeps when battery or temperature crosses a danger line.
- **Remote-activity aware.** Won't sleep while you're on it over SSH, screen sharing, or Tailscale — and keeps remote builds alive.
- **Never reads your conversations or code.** Agent detection only looks at transcript timestamps, never their contents.

---

## Features

The goal is to keep your agent working — **safely** — without interruption. Everything below serves that.

### Agent-aware keep-awake

![Agent-aware detection demo](docs/assets/eclam-demo-agents.gif)

The point is simple: let your agent keep working, uninterrupted.

So the toggle tracks whether the agent is *working right now*, not whether a process exists. While it works, the Mac stays awake; when it stops, the hold releases (**Strict** mode). A **Lax** mode that simply stays awake while the process is alive is also available.

**Detected by default (5):** Claude Code · Codex · Cursor · opencode · Antigravity.

**Opt-in via Customize (off by default):** Aider · Cline · Roo Code · OpenHands · Hermes · Openclaw.

Agents not listed here can be added too — give a glob pattern, or drop a single declaration file into `~/.config/eclam/traces.d/*.json`.

By default agents are detected by polling their session logs (~5 s, ~30 s while the screen is locked), so a just-started agent can take a few seconds to appear. Claude, Codex, and Hermes can be detected instantly by installing their (optional) hooks.

### Safety guards

![Safety guard demo](docs/assets/eclam-demo-safety.gif)

Running a heavy workload in clamshell mode inside a bag is a thermal risk. Electronic Clam watches temperature and battery, and lets the Mac sleep when things get risky:

- **Battery** — the threshold depends on your setup: 30% with the lid closed and no external display, 10% otherwise (adjustable). A weak or unstable AC connection counts as battery.
- **Thermal** — combines the macOS signal with a more sensitive internal one to react faster.
- **Max duration** — Desktop mode (AC + lid open + external display) skips the cap entirely.
- **Low Power Mode** — tightens both by one step (+10pp battery, one thermal notch).

With AC unplugged and the lid closed in a bag it judges more conservatively, then clears automatically once things are safe again. You can opt into a notification when it puts the Mac to sleep.

### Remote-activity awareness

![Remote awareness demo](docs/assets/eclam-demo-remote.gif)

Electronic Clam won't sleep while you're using the Mac remotely. It detects SSH, screen sharing, Tailscale, and known remote-control apps. The default is simple: stay awake as long as you're connected.

### Telegram notifications (off by default)

Connect your own Telegram bot and you'll get a ping when an agent stops or your Mac goes to sleep — with battery %, temperature, and host name attached.

### Other

- **CLI + named sessions** — drive it straight from the terminal (see [Usage](#usage)).
- **Optional agent hooks** — installing injects an activity-signal hook into Claude / Codex / Hermes configs; uninstalling restores them.
- **Guaranteed sleep restore on exit** — three layers: synchronous restore on quit, a SIGTERM handler, and a 20-second watchdog if the app crashes.

## Install

```bash
brew install --cask jadhvank/tap/eclam
open /Applications/ElectronicClam.app
```

Turn on **Electronic Clam Helper** in **System Settings → General → Login Items & Extensions**.

## Usage

**Left-click** the menu bar icon to toggle keep-awake. **Right-click** opens the full menu.

The icon is a clam shell with three states: an outline shell (asleep), a filled shell + bolt (you're holding it awake), and a filled shell + remote mark (an agent, remote session, or safety hold is keeping it awake automatically).

### Menu

| Item | Action |
|---|---|
| Status header | Current state at a glance (e.g., "Asleep when idle", "Awake — until I quit", "Awake — remote session") |
| **Keep Mac Awake** (⌘K) | Toggle keep-awake |
| **Watch Agents** ▸ | Enable/disable the agents to detect (shows " • active" when one is); **Customize…** at the bottom |
| **Blank screen — keep working** | Sleep the displays but keep the Mac and agents running |
| **Settings…** (⌘,) | Open settings |
| **Quit** (⌘Q) | Quit (restores sleep first) |

### CLI

The Homebrew cask creates a `$HOMEBREW_PREFIX/bin/eclam` symlink.

```
eclam on [--for <dur>] [--forever]   # keep awake; default 2h, then the helper auto-releases (no GUI needed, survives reboot)
eclam off
eclam status [--json]
eclam keep --while <pid>
eclam watch <agent> [--grace s] [--check-interval s] [--max min] [--json]
eclam session start <name> [--message <text>] / stop <name> / list [--json]
eclam debug [agents] [--json]
eclam help
```

**Exit codes:** `0` success · `1` bad arguments · `2` helper unreachable · `3` approval required · `4` user cancelled.

## Security & privacy

- Reads file clocks, not file contents.
- No telemetry, no tracking, no analytics.
- XPC caller verification is enforced.
- Developer ID signed + Apple notarized.
- Tokens stay local.
- Sleep is always restored on exit or crash.
- One permission path (`SMAppService`).

See [Security & privacy](docs/security.md) for details.

## Cautions / Known limitations

- **Detection can lag a few seconds without a hook.** Agents without an installed hook are detected by polling their session logs (~5 s, ~30 s while locked). Claude / Codex / Hermes are instant once you install their hooks.
- **No safety guards in CLI-only use.**
- **VS Code–embedded agents** (Cline / Roo Code) have no standalone process, so Lax-mode detection is limited.
- **Apple Silicon only**, macOS 13+ (Ventura).

## Tech stack

- **Language / UI:** Swift + AppKit (`NSStatusItem`, `LSUIElement` menu bar app — no Dock).
- **Power control:** IOKit SPI — `IOPMSetSystemPowerSetting("SleepDisabled")` via an `@_silgen_name` binding.
- **Privilege separation:** an `SMAppService` daemon talking to the app over `NSXPCConnection` (mach service).
- **Build:** direct `swiftc` (no SwiftPM), **no external dependencies**.
- **Targets:** arm64, macOS 13+ (Ventura).

## Build from source

```bash
./scripts/build.sh            # app + helper + hook binaries (Developer ID signed)
open build/ElectronicClam.app
```

- Direct `swiftc` invocation, `arm64-apple-macos13.0` target. Set `ECLAM_SIGN_ID=-` for fast ad-hoc local builds.
- Bundle layout: `Contents/MacOS/{ElectronicClam, ElectronicClamHelper, eclam-hook}` + `Contents/Library/LaunchDaemons/com.jadhvank.eclam.helper.plist`.
- Release builds are Developer ID–signed and notarized (stapled by `release.sh`).

## Support

Electronic Clam is free and open source. It keeps your agent awake; your coffee keeps the developer awake. ☕

[![Ko-fi](https://img.shields.io/badge/Ko--fi-%E2%98%95-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/jadhvank)

## License

[MIT](LICENSE).

---

<sub>`README.zh-CN.md`, `README.ja.md`, and `README.es.md` are generated from this file via the `/translate` command — don't edit them by hand. `README.ko.md` is maintained by hand.</sub>
