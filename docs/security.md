# Security & privacy

Electronic Clam runs right next to an AI developer's most sensitive files. It is built so there is **no telemetry and no involuntary exfiltration**: the only outbound traffic is the opt-in Telegram bot you set up yourself (off by default). This document expands on the summary in the README.

## Reads file clocks, not file contents

Agent detection only calls `stat()` on other tools' transcript files to read their modification time. It **never reads the conversations or code** inside them.

## No telemetry, no tracking, no analytics

The *only* outbound network traffic is the Telegram bot **you** set up yourself (opt-in, off by default). When you enable it, messages go to Telegram's servers (`api.telegram.org`) so your own bot can deliver them — that is the sole third party, and it carries only what you chose to be notified about. No traffic ever goes to the developer or to any *other* third-party server.

## XPC caller verification is enforced

The root helper accepts connections only from our own signed app / CLI / hook, pinned by Team ID and identifier. Even another process under the same account cannot reach the helper.

## Developer ID signed + Apple notarized

Team `GBQ3DN529X`, hardened runtime. Passes Gatekeeper cleanly — no quarantine-strip tricks.

## Tokens stay local

Telegram tokens are stored only in `0600` files on your machine.

## Sleep is always restored on exit or crash

Three layers: synchronous restore on quit, a SIGTERM handler, and a 20-second helper watchdog.

## One permission path

Privilege comes only from `SMAppService`, approved once on first launch. No `sudoers` edits, no system-file changes.
