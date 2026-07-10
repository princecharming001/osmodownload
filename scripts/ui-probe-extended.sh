#!/bin/bash
# ui-probe-extended.sh — the round-specific AX scenarios that the base
# ui-probe.sh (modals) doesn't cover: Ask Osmo chat, the Connections connect
# phase flip, and the human-vs-automated queue filter. Unlike ui-probe.sh (one
# relaunch per call), this drives a SINGLE running instance through all three
# scenarios in order, injecting the two classifier-probe emails via
# /api/dev/emit at the right moment.
#
# Requires a MOCK web backend on :3000 (dev/emit 404s when Unipile is live) and
# a Debug Osmo.app build (Debug talks to localhost:3000). ralph-gate.sh sets
# both up; run it rather than this directly unless you know the server is mock.
#
# Usage: scripts/ui-probe-extended.sh
# Exit 0 = all scenarios passed.

set -uo pipefail
cd "$(dirname "$0")/.."

APP_PATH=".build/xcode/Build/Products/Debug/Osmo.app"
APP_NAME="Osmo"
BASE="http://localhost:3000"
DEVICE_FILE="$HOME/Library/Application Support/Osmo/.device"
DIAG_DIR="/tmp/osmo-ui-probe-ext-$(date +%s 2>/dev/null || echo run)"

fail() {
  echo "✗ $1"
  mkdir -p "$DIAG_DIR"
  cp /tmp/osmo-ui-probe-ext-last.log "$DIAG_DIR/probe.log" 2>/dev/null
  osascript -e 'tell application "System Events" to tell process "Osmo" to return entire contents of window 1' \
    > "$DIAG_DIR/ax-tree.txt" 2>&1
  sample "$APP_NAME" 3 -file "$DIAG_DIR/sample.txt" >/dev/null 2>&1
  echo "  diagnostics: $DIAG_DIR"
  exit 1
}

[ -d "$APP_PATH" ] || { echo "✗ $APP_PATH not found — run scripts/run.sh --build first."; exit 1; }

# Backend must be mock (dev/emit reachable). Probe it before touching the app.
if ! curl -sf "$BASE/api/version" >/dev/null 2>&1; then
  echo "✗ no web backend on :3000 — start a mock server first."; exit 1
fi

# ── Relaunch the app once ───────────────────────────────────────────────────
echo "→ relaunching $APP_NAME…"
pkill -x "$APP_NAME" >/dev/null 2>&1
sleep 1
# Suppress browser-opens for connect links during the probe (self-expiring).
defaults write com.osmo.app uiProbeSuppressBrowserUntil -float "$(python3 -c 'import time;print(time.time()+900)')" 2>/dev/null
# Reset the backend sync cursor. The gate boots a FRESH in-memory mock server
# each run (oplog restarts at seq 1), but the app persists its cursor across
# sessions — a stale high cursor (e.g. 702 from a prior real/gate server) makes
# `pull since=702` return nothing, so the emitted probe messages never ingest.
# Production backends are durable so this never bites users; it's purely a
# fresh-mock-server artifact. Zero it so the app pulls the mock oplog cleanly.
CURSORS="$HOME/Library/Application Support/Osmo/cursors.json"
if [ -f "$CURSORS" ]; then
  python3 - "$CURSORS" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["backendCursor"] = "0"
json.dump(d, open(p, "w"))
PY
fi
open "$APP_PATH"
ready=0
for _ in $(seq 1 40); do
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    wc=$(osascript -e 'tell application "System Events" to tell process "Osmo" to count of windows' 2>/dev/null || echo 0)
    [ "${wc:-0}" -gt 0 ] && { ready=1; break; }
  fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || { echo "✗ Osmo never produced a window within 20s."; exit 1; }
# Let the app register its device + reconcile connections with the backend.
sleep 4

run_scenario() {
  local name="$1"
  echo "→ scenario: $name"
  if osascript "scripts/ui-probe.applescript" "$name" 2>&1 | tee /tmp/osmo-ui-probe-ext-last.log; then
    echo "  ✓ $name PASSED"
  else
    fail "$name FAILED"
  fi
}

# ── 0) Settle: dismiss any launch sheet + wait for the sidebar ───────────────
run_scenario "settle"

# ── 1) Ask Osmo (mock-mode deterministic answer) ────────────────────────────
run_scenario "ask"

# ── 2) Connections connect-phase flip ───────────────────────────────────────
run_scenario "connections"

# ── 3) Human-vs-automated queue filter ──────────────────────────────────────
# Read the app's own device token so the emits target its device.
if [ ! -f "$DEVICE_FILE" ]; then fail "device token file not found at $DEVICE_FILE (app never registered?)"; fi
TOKEN=$(python3 - "$DEVICE_FILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# tolerate a couple of key spellings
print(d.get("deviceToken") or d.get("token") or d.get("device_token") or "")
PY
)
[ -n "$TOKEN" ] || fail "could not read deviceToken from $DEVICE_FILE"

emit() {
  curl -sf -X POST "$BASE/api/dev/emit" \
    -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
    -d "$1" >/dev/null || fail "dev/emit rejected (backend live, not mock?) payload=$1"
}

echo "→ emitting classifier-probe messages (automated + human)…"
# Automated: noreply@ event-platform sender with event boilerplate.
emit '{"platform":"gmail","threadKey":"poker","senderName":"Poker Night","senderHandle":"noreply@updates.pokernight.com","text":"You have got a spot at Poker Night Tuesday, July 14 7:00 PM - 11:00 PM PDT Location: The Loft. Unsubscribe here."}'
# Human: a real person at a personal domain asking a question.
emit '{"platform":"gmail","threadKey":"sam","senderName":"Sam Rivera","senderHandle":"sam.rivera@gmail.com","text":"Are you free Thursday to review the deck together?"}'
sleep 1

run_scenario "queue-human-filter"

echo "✓ ALL EXTENDED SCENARIOS PASSED"
exit 0
