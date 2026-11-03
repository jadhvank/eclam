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
DEST="${ECLAM_INSTALL_DEST:-/Applications/ElectronicClam.app}"
BACKUP_DIR="${ECLAM_BACKUP_DIR:-$HOME/.eclam-backups}"
QUIT_TIMEOUT="${ECLAM_QUIT_TIMEOUT:-15}"
export ECLAM_SIGN_ID="${ECLAM_SIGN_ID:--}"

# Custom destinations also make the failure paths testable without touching an
# installed app. Never replace a symlink or an arbitrary non-app directory.
if [[ "$DEST" != /*.app || -L "$DEST" ]]; then
    echo "ERROR: destination must be an absolute, non-symlink .app path" >&2
    exit 1
fi
if [[ ! "$QUIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || (( QUIT_TIMEOUT > 300 )); then
    echo "ERROR: ECLAM_QUIT_TIMEOUT must be 1..300 seconds" >&2
    exit 1
fi
BIN="$DEST/Contents/MacOS/ElectronicClam"
if [[ "$ECLAM_SIGN_ID" == - ]]; then
    echo "WARNING: ad-hoc development build; helper XPC caller signature verification is disabled."
    echo "         Use the signed release for normal distribution."
fi

echo "==> [install-local] Building ($ECLAM_SIGN_ID)"
"$SCRIPT_DIR/build.sh"
[[ -x "$SRC/Contents/MacOS/ElectronicClam" ]] || { echo "ERROR: built app is missing its executable" >&2; exit 1; }

echo "==> [install-local] Quitting the running app"
# Graceful quit restores sleep/brightness. A timeout must abort replacement,
# never force-kill an app that may still own power state.
quit_pid=""
if pgrep -x ElectronicClam >/dev/null; then
    # Apple Events can themselves wait indefinitely. Bound the request along
    # with the app-exit wait, and terminate only our own request process.
    osascript -e 'quit app "ElectronicClam"' >/dev/null 2>&1 &
    quit_pid=$!
fi
for ((attempt=0; attempt<QUIT_TIMEOUT*5; attempt++)); do
    if ! pgrep -x ElectronicClam >/dev/null; then break; fi
    sleep 0.2
done
if [[ -n "$quit_pid" ]]; then
    kill "$quit_pid" 2>/dev/null || true
    wait "$quit_pid" 2>/dev/null || true
fi
if pgrep -x ElectronicClam >/dev/null; then
    echo "ERROR: app did not quit within $QUIT_TIMEOUT seconds; install unchanged" >&2
    exit 1
fi

backup=""
copy_in_progress=0
rollback_copy() {
    status=$?
    if (( copy_in_progress )); then
        echo "==> [install-local] Copy interrupted; restoring previous install" >&2
        if rm -rf -- "$DEST"; then
            if [[ -n "$backup" ]]; then
                mv "$backup" "$DEST" || echo "ERROR: restore failed; previous app remains at $backup" >&2
            fi
        else
            echo "ERROR: partial install removal failed; previous app remains at $backup" >&2
        fi
    fi
    exit "$status"
}
trap rollback_copy EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$(dirname "$DEST")" "$BACKUP_DIR"
if [[ -e "$DEST" ]]; then
    # .app.bak avoids Spotlight discovering a second runnable app. Include a
    # unique suffix so two installs in the same second cannot overwrite backup.
    backup_epoch="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
    backup="$(mktemp -d "$BACKUP_DIR/ElectronicClam-$(date +%Y%m%d-%H%M%S)-$backup_epoch-XXXXXX").app.bak"
    rmdir "${backup%.app.bak}"
    mv "$DEST" "$backup"
fi
copy_in_progress=1
echo "==> [install-local] Installing to $DEST"
ditto "$SRC" "$DEST"
[[ -x "$BIN" ]] || { echo "ERROR: installed executable missing" >&2; exit 1; }
copy_in_progress=0

echo "==> [install-local] Launching"
open "$DEST"
sleep 5

echo "==> [install-local] Repairing the helper"
"$BIN" repair

echo "==> [install-local] Status"
"$BIN" status

# Prune only after a successful install. Never remove the last recovery copy
# after a failed launch/repair/status. Paths are passed as arguments, not code.
/usr/bin/python3 - "$BACKUP_DIR" <<'PYTHON'
from pathlib import Path
import shutil
import sys
backups = sorted((p for p in Path(sys.argv[1]).glob("ElectronicClam-*.app.bak")
                  if p.is_dir() and not p.is_symlink()), key=lambda p: p.name, reverse=True)
for path in backups[3:]:
    shutil.rmtree(path)
PYTHON

cat <<EOF

==> Done. Installed $DEST
    Backups: $BACKUP_DIR (most recent 3 successful replacements retained)
EOF
