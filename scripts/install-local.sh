#!/usr/bin/env bash
# install-local.sh — build the working tree and make it the installed app.
#
# For running your own build day to day instead of a downloaded release. It
# ad-hoc signs (ECLAM_SIGN_ID=-), replaces /Applications/ElectronicClam.app,
# and repairs the helper, which a plain build.sh does not do.
#
# Usage:
#   scripts/install-local.sh              # ad-hoc sign (default)
#   ECLAM_SIGN_ID="Developer ID Application: …" scripts/install-local.sh
#
# Three things this handles that a manual copy does not:
#
#   1. The bundle must be REPLACED, not written into. macOS App Management
#      (TCC) denies writes inside an installed .app even to its owner, so
#      `cp -R` over the live bundle fails with EPERM per file. Moving the old
#      one aside and dittoing a fresh bundle in is allowed.
#   2. Swapping a Developer-ID bundle for an ad-hoc one at the same path
#      leaves a BTM record whose signature no longer matches, and the daemon
#      then fails to spawn with EX_CONFIG(78). `eclam repair` relaunches the
#      app so registration reruns in its GUI session, which fixes it.
#      (Measured 2026-08-24 on exactly this transition.)
#   3. A locally built bundle carries no com.apple.quarantine, so the
#      install-location gate (ADR-0038) stops nagging at every login — the
#      failure mode a downloaded copy in /Applications keeps hitting, because
#      moving it to /Applications never strips the xattr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="$ROOT/build/ElectronicClam.app"
DEST="/Applications/ElectronicClam.app"
BIN="$DEST/Contents/MacOS/ElectronicClam"
# Keep the replaced bundle until the new one is verified. Two constraints pick
# this path: it is outside $ROOT/build, which build.sh wipes with `rm -rf` on
# every run, and it is a dot-directory, which Spotlight skips — so the backups
# never show up in BundleScan's mdfind and never trip the ADR-0039 split-brain
# warning in `eclam status`. Verified 2026-08-24.
BACKUP_DIR="${ECLAM_BACKUP_DIR:-$HOME/.eclam-backups}"

# Ad-hoc by default — the point of this script is a local build, and most
# machines have no Developer ID. build.sh compiles the helper with
# -DECLAM_DEV_ADHOC under this value so the XPC caller check stays usable.
export ECLAM_SIGN_ID="${ECLAM_SIGN_ID:--}"

echo "==> [install-local] Building ($ECLAM_SIGN_ID)"
"$SCRIPT_DIR/build.sh"

echo "==> [install-local] Quitting the running app"
# Graceful quit runs restore-on-exit (ADR-0002), so a held SleepDisabled is
# released instead of being stranded across the swap. No-op if not running.
osascript -e 'quit app "ElectronicClam"' >/dev/null 2>&1 || true
sleep 2

if [[ -d "$DEST" ]]; then
    mkdir -p "$BACKUP_DIR"
    STAMP="$(date +%y%m%d-%H%M%S)"
    echo "==> [install-local] Backing up the current install to $BACKUP_DIR"
    mv "$DEST" "$BACKUP_DIR/ElectronicClam-$STAMP.app"
fi

echo "==> [install-local] Installing to $DEST"
ditto "$SRC" "$DEST"

echo "==> [install-local] Launching"
open "$DEST"
sleep 5

# The helper needs its GUI-session registration to rerun after a signature
# change. repair is idempotent: it prints "nothing to do" on a healthy helper.
echo "==> [install-local] Repairing the helper"
"$BIN" repair || true

echo "==> [install-local] Status"
"$BIN" status || true

cat <<EOF

==> Done. Installed $DEST
    Backups: $BACKUP_DIR (delete the ones you no longer want)
EOF
