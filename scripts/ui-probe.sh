#!/bin/bash
# ui-probe.sh — kill/relaunch the built Osmo.app, then drive its modal system
# via Accessibility (ui-probe.applescript) and assert every sheet actually
# responds to clicks. On failure, captures a screenshot + full AX dump + a
# `sample` of the Osmo process so a hang can be told apart from dead event
# routing.
#
# Usage: scripts/ui-probe.sh [scenario]
#   scenario ∈ { modals (default), ask, connections, queue-human-filter }
# Exit 0 = probe passed. Non-zero = see stdout + diagnostics under /tmp.

set -uo pipefail
cd "$(dirname "$0")/.."

SCENARIO="${1:-modals}"

APP_PATH=".build/xcode/Build/Products/Debug/Osmo.app"
APP_NAME="Osmo"
DIAG_DIR="/tmp/osmo-ui-probe-$(date +%s 2>/dev/null || echo run)"

if [ ! -d "$APP_PATH" ]; then
  echo "✗ $APP_PATH not found — run ./scripts/run.sh --build first." >&2
  exit 1
fi

echo "→ relaunching $APP_NAME…"
pkill -x "$APP_NAME" >/dev/null 2>&1
sleep 1
# Suppress browser-opens for connect links during the probe (self-expiring).
defaults write com.osmo.app uiProbeSuppressBrowserUntil -float "$(python3 -c 'import time;print(time.time()+900)')" 2>/dev/null
open "$APP_PATH"

# Wait for the process + a window to exist before probing.
ready=0
for _ in $(seq 1 30); do
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    win_count=$(osascript -e 'tell application "System Events" to tell process "Osmo" to count of windows' 2>/dev/null || echo 0)
    if [ "${win_count:-0}" -gt 0 ]; then ready=1; break; fi
  fi
  sleep 0.5
done
if [ "$ready" -ne 1 ]; then
  echo "✗ Osmo never produced a window within 15s." >&2
  exit 1
fi
sleep 1

echo "→ running AX probe [$SCENARIO]…"
if osascript "scripts/ui-probe.applescript" "$SCENARIO" 2>&1 | tee /tmp/osmo-ui-probe-last.log; then
  echo "✓ UI probe [$SCENARIO] PASSED"
  exit 0
fi

echo "✗ UI probe FAILED — capturing diagnostics to $DIAG_DIR"
mkdir -p "$DIAG_DIR"
cp /tmp/osmo-ui-probe-last.log "$DIAG_DIR/probe.log" 2>/dev/null

# Screenshot of the whole screen (captures whatever's actually rendered,
# frozen sheet included).
screencapture -x "$DIAG_DIR/screen.png" 2>/dev/null

# Full AX tree dump for the window, for offline inspection of what elements
# actually exist vs. what the probe expected.
osascript -e '
tell application "System Events"
  tell process "Osmo"
    set win to window 1
    return entire contents of win
  end tell
end tell' > "$DIAG_DIR/ax-tree.txt" 2>&1

# A `sample` distinguishes a genuinely blocked main thread (long stack in
# the same frame across samples — e.g. stuck in runModal) from a merely
# unresponsive-to-AX-clicks-but-alive app (dead event routing, the sheet
# Binding-identity bug) — the two need different fixes.
sample "$APP_NAME" 3 -file "$DIAG_DIR/sample.txt" >/dev/null 2>&1

echo "  screenshot:  $DIAG_DIR/screen.png"
echo "  AX tree:     $DIAG_DIR/ax-tree.txt"
echo "  thread sample: $DIAG_DIR/sample.txt"
exit 1
