# Security & privacy

Electronic Clam has no telemetry or analytics. Agent detection reads transcript file timestamps, not conversation or code contents. Network features and local credentials are described below.

## Network traffic and recipients

- **Telegram and Slack notifications:** off by default and independently configured. Telegram sends to `api.telegram.org`; Slack sends to `slack.com/api` or an incoming webhook on `hooks.slack.com`. Messages are visible to the recipients/members of the chat or channel you select, including the channel fixed by a webhook.
- Notifications can include the Mac host name, active agent names, battery/charging state, temperature, activity duration and start/end or safety reason. VPN alerts include the selected VPN service name. They do not contain conversation text or source files.
- Periodic messages run while the app and system are awake. Sleep and network loss can prevent delivery; a failed network attempt is retried once while its original settings are still current. A settings change, OFF or app shutdown cancels pending requests and retries. Already delivered messages cannot be recalled.
- **Update checks:** automatic checks are enabled by default and can be disabled in Settings. They query `api.github.com/repos/jadhvank/eclam/releases/latest`; manual checks also contact GitHub. Downloads open the public release page. Update checks do not send activity summaries.

No activity messages are sent to the developer. The services above receive normal connection metadata when used.

## Local credentials

Telegram bot tokens and Slack bot tokens/webhook URLs live in user-only (`0600`) settings files under `~/Library/Application Support/eclam/`. A replacement file is written with restrictive permissions before being atomically renamed into place. The app does not intentionally log credentials, webhook URLs, payloads, or raw network errors. Notification requests do not follow redirects. Slack's bot flow accepts bot tokens, not `xoxp` user tokens.

## Helper authentication and development builds

Distributed Developer ID releases use Team ID and bundle-identifier checks for app/CLI/hook connections to the privileged helper. They are signed and notarized through the release workflow.

`scripts/install-local.sh` defaults to **ad-hoc development signing**. That build defines `ECLAM_DEV_ADHOC` and disables the helper's caller-signature check. The script prints this before building. It is intended for a local development machine, not redistribution. It does not automatically choose another developer's identity; the helper's release Team ID is pinned. See [local development](local-development.md).

## Power and brightness cleanup

Normal quit and GUI SIGTERM request brightness restoration and release app-owned power holds. The helper has its own restore-on-exit/watchdog path for system sleep state. Brightness recovery data contains only the built-in panel UUID, original/app-applied brightness and capture time, in a separate `0600` journal. Failed restores remain pending. On the next launch only a recent record for the same panel whose brightness still matches the app's value is eligible for recovery. External brightness changes are respected.

A crash or SIGKILL cannot synchronously restore display brightness. Recovery after relaunch and actual lid/display timing remain separate from automated tests.

## Permission path

Privileged registration uses `SMAppService`; the app does not modify sudoers or install a separate privilege fallback. Local notifications use macOS notification permission. Input return detection reads idle timing, not keystroke contents.
