#!/bin/bash
# Starts everything and clears the log, so one run is one file.
#   ./start.sh            native app + recorder + web probe
#   ./start.sh --no-web   skip the Chromium surface
set -uo pipefail
cd "$(dirname "$0")"
LOG="$HOME/cua-probe/probe.jsonl"

./stop.sh >/dev/null 2>&1 || true
[ -x build/ProbeTarget.app/Contents/MacOS/ProbeTarget ] || ./build.sh

mkdir -p "$HOME/cua-probe"
if [ -s "$LOG" ]; then
  mv "$LOG" "$HOME/cua-probe/probe-$(date +%Y%m%d-%H%M%S).jsonl"
fi
: > "$LOG"

open build/ProbeTarget.app
sleep 1
nohup ./build/recorder > "$HOME/cua-probe/recorder.out" 2>&1 &
disown || true

if [ "${1:-}" != "--no-web" ]; then
  ELECTRON=""
  for c in /Users/naveen/Projects/Work/unbiased-app/node_modules/.bin/electron "$(command -v electron || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && ELECTRON="$c" && break
  done
  if [ -n "$ELECTRON" ]; then
    # Absolute: Electron reads a bare name as a module to require, not a path,
    # and silently falls back to its own welcome app when it cannot find it.
    ELECTRON_RUN_AS_NODE= nohup "$ELECTRON" "$PWD/web-probe.cjs" > "$HOME/cua-probe/web.out" 2>&1 &
    disown || true
  else
    echo "no electron found; running without the Chromium surface"
  fi
fi

sleep 2
echo
echo "  ProbeTarget  native window, buttons TARGET-A/B/C, a CANVAS, a TYPE-HERE field"
echo "  ProbeWeb     Chromium window, buttons WEB-A/B/C, a canvas, a WEB-TYPE-HERE field"
echo "  log          $LOG"
echo
echo "Now ask the other agent to act on them, WITHOUT touching your own mouse."
echo "Note where your pointer is before you start. Then run ./analyse.py"
