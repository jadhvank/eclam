#!/usr/bin/env bash
# Electronic Clam — REAL menu-bar screen capture → animated GIF.
#
# Unlike the mockup (docs/assets/demo/make-mockup-gif.sh), this records the live
# app. It therefore needs the terminal app to hold macOS **Screen Recording**
# permission (System Settings → Privacy & Security → Screen Recording). Without
# it, avfoundation capture hangs — so we gate recording behind a fast probe.
#
#   scripts/demo-capture.sh --probe   # test Screen Recording permission only (fast, never hangs)
#   scripts/demo-capture.sh           # full capture: launch app, record, build GIF
#
# 불변 규약 #1: restores SleepDisabled=false on every exit path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/ElectronicClam.app"
OUT="$ROOT/docs/assets/eclam-menu-demo.real.gif"
SECONDS_REC="${SECONDS_REC:-9}"        # capture window
SCREEN_IDX="${SCREEN_IDX:-1}"          # avfoundation "Capture screen 0"; verify: ffmpeg -f avfoundation -list_devices true -i ""
WORK="$(mktemp -d)"
APP_LAUNCHED=0

# eclam CLI: prefer an installed one, else fall back to nothing (state setup skipped).
ECLAM="$(command -v eclam || true)"

cleanup() {
  set +e
  # 불변 규약 #1 — never leave the Mac unable to sleep.
  if [ -n "$ECLAM" ]; then "$ECLAM" session stop demo >/dev/null 2>&1; "$ECLAM" off >/dev/null 2>&1; fi
  # Belt-and-suspenders: if SleepDisabled is still 1 and we own no helper, warn.
  if pmset -g 2>/dev/null | grep -qiE 'sleepdisabled[[:space:]]+1'; then
    echo "⚠️  SleepDisabled is still 1 — run 'eclam off' or toggle the app off."
  fi
  [ "$APP_LAUNCHED" = 1 ] && osascript -e 'quit app "ElectronicClam"' >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

probe() {
  local p="$WORK/probe.png"
  # screencapture returns immediately (does not hang like avfoundation).
  screencapture -x -R0,0,600,60 "$p" 2>/dev/null || true
  if [ ! -s "$p" ]; then
    echo "❌ screencapture produced no file → Screen Recording permission is missing."
    echo "   Grant it to your terminal app, then re-run."
    return 1
  fi
  local y
  y="$(ffmpeg -hide_banner -loglevel error -i "$p" \
        -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 \
        | sed -n 's/.*YAVG=\([0-9.]*\).*/\1/p' | head -1)"
  echo "probe: captured $(sips -g pixelWidth "$p" 2>/dev/null | awk '/pixelWidth/{print $2}')px, mean-luma=${y:-?}"
  # YAVG ≈ 16 (limited-range black) ⇒ blocked. A real menu bar is much brighter.
  if [ -n "$y" ] && awk "BEGIN{exit !($y < 24)}"; then
    echo "❌ frame is ~black → Screen Recording permission is missing/ineffective."
    return 1
  fi
  echo "✅ Screen Recording works — real capture is possible."
}

record() {
  echo "==> launching app + demo state"
  open -n "$APP"; APP_LAUNCHED=1; sleep 3
  if [ -n "$ECLAM" ]; then
    "$ECLAM" session start demo --message "demo agent" >/dev/null 2>&1 || true   # → header "Awake — demo active"
    "$ECLAM" on >/dev/null 2>&1 || true
  else
    echo "    (no 'eclam' on PATH — recording whatever state the app shows)"
  fi

  echo "==> RECORDING ${SECONDS_REC}s. Click the 🐚 menu bar icon NOW and hold the menu open."
  local raw="$WORK/raw.mov"
  # -t bounds the capture; run detached + watchdog so a stall can't orphan ffmpeg.
  ffmpeg -hide_banner -loglevel error -f avfoundation -framerate 30 -i "$SCREEN_IDX" \
         -t "$SECONDS_REC" -pix_fmt yuv420p -y "$raw" &
  local fp=$!
  ( sleep $((SECONDS_REC + 8)); kill -9 "$fp" 2>/dev/null ) &
  local wp=$!
  wait "$fp" 2>/dev/null || true
  kill "$wp" 2>/dev/null || true
  [ -s "$raw" ] || { echo "❌ no recording produced"; return 1; }

  echo "==> cropping top-right menu region + building GIF"
  # Full-screen capture cropped to the top-right corner where the menu drops.
  # Tune crop=W:H:X:Y to your display; defaults assume a Retina top-right cluster.
  ffmpeg -hide_banner -loglevel error -i "$raw" \
    -vf "crop=in_w*0.42:in_h*0.62:in_w*0.58:0,fps=15,scale=820:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=full[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
    -loop 0 -y "$OUT"
  echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
}

case "${1:-}" in
  --probe) probe ;;
  "")      probe && record ;;
  *)       echo "usage: $0 [--probe]"; exit 2 ;;
esac
