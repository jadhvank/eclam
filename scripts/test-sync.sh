#!/usr/bin/env bash
# Pull latest, rebuild, and (re)launch ElectronicClam on the *test* Mac.
# Workflow A: dev machine pushes a branch, this fetches + builds + relaunches.
#
# Usage (on the test Mac):
#   ./scripts/test-sync.sh            # sync current branch
#   ./scripts/test-sync.sh my-branch  # sync a specific branch
#
# Requires: Xcode Command Line Tools (swiftc) installed on this Mac.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"

# Refuse to clobber local edits on the test Mac — it should be a clean checkout.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ Working tree has local changes. Test Mac should be a clean checkout." >&2
    echo "  Stash/discard them first:  git stash  (or)  git checkout -- ." >&2
    exit 1
fi

echo "==> Fetching origin/$BRANCH"
git fetch --prune origin
git checkout "$BRANCH"
git reset --hard "origin/$BRANCH"

echo "==> Quitting running ElectronicClam (if any)"
osascript -e 'quit app "ElectronicClam"' 2>/dev/null || true
# Fallback for the menubar process if AppleScript quit didn't catch it.
pkill -x ElectronicClam 2>/dev/null || true
sleep 1

echo "==> Building"
./scripts/build.sh

echo "==> Clearing quarantine + launching"
xattr -dr com.apple.quarantine "build/ElectronicClam.app" 2>/dev/null || true
open "build/ElectronicClam.app"

echo "==> Synced to $(git rev-parse --short HEAD) — $(git log -1 --pretty=%s)"
