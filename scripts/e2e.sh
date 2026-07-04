#!/bin/bash
# Osmo keyless end-to-end check. Boots the web backend in mock mode, then runs
# the Swift KeylessE2ETests suite (register → mock-connect → backfill → SSE
# inbound → send → outbox) plus the web + Swift unit suites. Zero credentials.
#
#   ./scripts/e2e.sh          full run (web tests + swift tests + live E2E loop)
#   ./scripts/e2e.sh --quick  skip the web build; assume a dev server is up
set -uo pipefail
cd "$(dirname "$0")/.."

PORT=3000
BASE="http://localhost:$PORT"
STARTED_SERVER=0
FAIL=0

log() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }
ok()  { printf "  \033[32m✓ %s\033[0m\n" "$1"; }
bad() { printf "  \033[31m✗ %s\033[0m\n" "$1"; FAIL=1; }

cleanup() {
  if [[ "$STARTED_SERVER" == "1" && -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

# 1. Ensure the mock backend is up.
if curl -sf "$BASE/api/version" >/dev/null 2>&1; then
  ok "backend already running on $PORT"
else
  log "Booting web backend (mock mode)…"
  ( cd web && OSMO_MOCK_DRIP_MS=0 npm run dev >/tmp/osmo-e2e-web.log 2>&1 ) &
  SERVER_PID=$!
  STARTED_SERVER=1
  for i in $(seq 1 30); do
    curl -sf "$BASE/api/version" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -sf "$BASE/api/version" >/dev/null 2>&1 && ok "backend up" || { bad "backend failed to start"; exit 1; }
fi

# 2. Web unit tests.
log "Web tests (vitest)…"
if ( cd web && npx vitest run >/tmp/osmo-e2e-vitest.log 2>&1 ); then
  ok "vitest passed ($(grep -oE 'Tests +[0-9]+ passed' /tmp/osmo-e2e-vitest.log | tail -1))"
else
  bad "vitest failed — see /tmp/osmo-e2e-vitest.log"
fi

# 3. Curl smoke of the full loop (language-agnostic proof).
log "Curl smoke: register → connect → pull → emit → send…"
TOKEN=$(curl -sf -X POST "$BASE/api/device/register" | python3 -c "import json,sys;print(json.load(sys.stdin)['deviceToken'])")
LINK=$(curl -sf -X POST "$BASE/api/connect/link" -H "authorization: Bearer $TOKEN" -H "content-type: application/json" -d '{"platform":"linkedin"}')
LINKID=$(echo "$LINK" | python3 -c "import json,sys;print(json.load(sys.stdin)['linkId'])")
curl -sf -X POST "$BASE/api/connect/mock/complete" -H "content-type: application/json" -d "{\"linkId\":\"$LINKID\"}" >/dev/null
COUNT=$(curl -sf "$BASE/api/sync/pull?since=0" -H "authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['messages']))")
[[ "$COUNT" -ge 5 ]] && ok "backfill delivered $COUNT messages" || bad "backfill returned $COUNT messages (<5)"
curl -sf -X POST "$BASE/api/sync/send" -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"platform":"linkedin","platformThreadID":"demo-li-chat-1","text":"e2e smoke send"}' >/dev/null
OUT=$(curl -sf "$BASE/api/dev/outbox" -H "authorization: Bearer $TOKEN" | python3 -c "import json,sys;print(json.load(sys.stdin)['outbox'][0]['text'])")
[[ "$OUT" == "e2e smoke send" ]] && ok "send recorded in outbox" || bad "outbox mismatch: '$OUT'"

# 4. Swift unit suite.
log "Swift tests (swift test)…"
if swift test >/tmp/osmo-e2e-swift.log 2>&1; then
  ok "swift tests passed ($(grep -oE 'Test run with [0-9]+ tests' /tmp/osmo-e2e-swift.log | tail -1))"
else
  bad "swift tests failed — see /tmp/osmo-e2e-swift.log"
fi

# 5. The gated keyless E2E loop (real BackendClient + RealtimeSyncEngine).
log "Keyless E2E loop (OSMO_E2E=1)…"
if OSMO_E2E=1 swift test --filter KeylessE2ETests >/tmp/osmo-e2e-loop.log 2>&1; then
  ok "E2E loop passed (register → connect → backfill → SSE inbound → send → outbox)"
else
  bad "E2E loop failed — see /tmp/osmo-e2e-loop.log"
fi

echo ""
if [[ "$FAIL" == "0" ]]; then
  printf "\033[32m━━━ ALL GREEN ━━━\033[0m\n"
else
  printf "\033[31m━━━ FAILURES ABOVE ━━━\033[0m\n"
fi
exit $FAIL
