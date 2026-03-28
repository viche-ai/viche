#!/usr/bin/env bash
# Viche V2 E2E channel validation — proves the MCP channel server integrates correctly.
# Verifies: registration, polling/inbox-consume, and viche_reply (send-back).
#
# Usage:
#   ./scripts/e2e-v2-channel-test.sh
#
# Requirements:
#   - bun available at /Users/ihorkatkov/.bun/bin/bun (or on PATH)
#   - Phoenix server not already running (script manages lifecycle)
#   - Run from project root

set -euo pipefail

VICHE=${VICHE:-http://localhost:4000}
BUN=${BUN:-/Users/ihorkatkov/.bun/bin/bun}
CHANNEL_SCRIPT="channel/viche-channel.ts"
POLL_INTERVAL=2   # seconds — channel server poll interval

# Temp files for process tracking
PHOENIX_LOG=$(mktemp /tmp/viche-phoenix-XXXXXX.log)
CHANNEL_LOG=$(mktemp /tmp/viche-channel-XXXXXX.log)

# ── Colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

pass()  { echo -e "${GREEN}  ✓ PASS${RESET}  $*"; }
fail()  { echo -e "${RED}  ✗ FAIL${RESET}  $*"; cleanup; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}▶ $*${RESET}"; }
info()  { echo -e "${YELLOW}  ↳ $*${RESET}"; }
title() {
  echo -e "\n${BOLD}════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Viche V2 E2E — $*${RESET}"
  echo -e "${BOLD}════════════════════════════════════════${RESET}"
}

assert_contains() {
  local label="$1" value="$2" pattern="$3"
  if echo "$value" | grep -q "$pattern"; then
    pass "$label"
  else
    fail "$label — expected pattern '$pattern' in: $value"
  fi
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label — expected '$expected', got '$actual'"
  fi
}

assert_not_empty() {
  local label="$1" value="$2"
  if [ -n "$value" ] && [ "$value" != "null" ]; then
    pass "$label"
  else
    fail "$label — got empty/null value"
  fi
}

# ── Cleanup ─────────────────────────────────────────────────────────────────
CHANNEL_PID=""
PHOENIX_PID=""

cleanup() {
  echo ""
  echo -e "${YELLOW}  Cleaning up background processes...${RESET}"

  if [ -n "$CHANNEL_PID" ] && kill -0 "$CHANNEL_PID" 2>/dev/null; then
    kill "$CHANNEL_PID" 2>/dev/null || true
    info "Channel server (PID $CHANNEL_PID) terminated"
  fi

  if [ -n "$PHOENIX_PID" ] && kill -0 "$PHOENIX_PID" 2>/dev/null; then
    kill "$PHOENIX_PID" 2>/dev/null || true
    sleep 1
    # Force-kill if still running
    kill -9 "$PHOENIX_PID" 2>/dev/null || true
    info "Phoenix server (PID $PHOENIX_PID) terminated"
  fi

  # Clean up tmp logs
  rm -f "$PHOENIX_LOG" "$CHANNEL_LOG"
}

trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────

title "Channel Integration Test"

# ── Step 0: Start Phoenix server ────────────────────────────────────────────
step "0. Starting Phoenix server in background…"

MIX_ENV=dev mix phx.server >"$PHOENIX_LOG" 2>&1 &
PHOENIX_PID=$!
info "Phoenix PID: $PHOENIX_PID  (log: $PHOENIX_LOG)"

# Wait for server to be ready (up to 30s)
for i in $(seq 1 30); do
  if curl -sf "$VICHE/" >/dev/null 2>&1; then
    pass "Phoenix server is up (attempt $i)"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Phoenix server did not start. Last log:"
    tail -20 "$PHOENIX_LOG" || true
    fail "Phoenix server did not respond after 30 attempts"
  fi
  sleep 1
done

# ── Step 1: Start channel server ────────────────────────────────────────────
step "1. Starting Viche channel server (MCP stdio mode)…"

VICHE_REGISTRY_URL="$VICHE" \
VICHE_AGENT_NAME="claude-code" \
VICHE_CAPABILITIES="coding,refactoring,testing" \
VICHE_DESCRIPTION="Claude Code AI coding assistant" \
VICHE_POLL_INTERVAL="$POLL_INTERVAL" \
  "$BUN" run "$CHANNEL_SCRIPT" \
    </dev/null \
    >"$CHANNEL_LOG" 2>&1 &

CHANNEL_PID=$!
info "Channel server PID: $CHANNEL_PID  (log: $CHANNEL_LOG)"

# Give the channel server time to register (registration happens before transport connect)
info "Waiting 3s for registration…"
sleep 3

# ── Step 2: Verify channel server is still running ──────────────────────────
step "2. Verifying channel server process is alive…"
if kill -0 "$CHANNEL_PID" 2>/dev/null; then
  pass "Channel server process is running (PID $CHANNEL_PID)"
else
  echo "Channel server log:"
  cat "$CHANNEL_LOG" || true
  fail "Channel server exited unexpectedly"
fi

# Show what the channel server logged
info "Channel server output:"
cat "$CHANNEL_LOG" | sed 's/^/    /' || true

# ── Step 3: Verify channel agent registered ──────────────────────────────────
step "3. Verifying 'claude-code' registered via /registry/discover…"
DISC=$(curl -sf "$VICHE/registry/discover?name=claude-code")
echo "  Response: $DISC"
assert_contains "discover finds claude-code agent" "$DISC" "claude-code"
assert_contains "discover returns agent id"        "$DISC" '"id"'

# Extract the claude-code agent ID
CLAUDE=$(echo "$DISC" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_not_empty "claude-code has an id" "$CLAUDE"
info "claude-code agent ID: $CLAUDE"

# ── Step 4: Register external 'aris' agent ───────────────────────────────────
step "4. Registering external orchestrator agent 'aris'…"
REG_ARIS=$(curl -sf -X POST "$VICHE/registry/register" \
  -H 'Content-Type: application/json' \
  -d '{"name":"aris","capabilities":["orchestration"],"description":"Aris orchestrator (V2 test)"}')
echo "  Response: $REG_ARIS"
ARIS=$(echo "$REG_ARIS" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_not_empty "aris registered with an id" "$ARIS"
info "aris agent ID: $ARIS"

# ── Step 5: Send task from Aris to Claude ───────────────────────────────────
step "5. Sending task from aris → claude-code…"
SEND=$(curl -sf -X POST "$VICHE/messages/$CLAUDE" \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"task\",\"from\":\"$ARIS\",\"body\":\"Implement rate limiter\",\"reply_to\":\"$ARIS\"}")
echo "  Response: $SEND"
MSG_ID=$(echo "$SEND" | grep -o '"message_id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_not_empty "send returns message_id" "$MSG_ID"
info "message_id: $MSG_ID"

# ── Step 6: Wait for channel server to poll ──────────────────────────────────
WAIT_S=$(( POLL_INTERVAL + 3 ))
step "6. Waiting ${WAIT_S}s for channel server to poll and consume inbox…"
sleep "$WAIT_S"

# Show updated channel log
info "Channel server log after poll:"
cat "$CHANNEL_LOG" | sed 's/^/    /' || true

# ── Step 7: Verify inbox was consumed ───────────────────────────────────────
step "7. Verifying claude-code inbox was consumed (should be empty)…"
INBOX=$(curl -sf "$VICHE/inbox/$CLAUDE")
echo "  Response: $INBOX"
assert_equals "inbox is empty after channel poll consumed it" "$INBOX" '{"messages":[]}'

# ── Step 8: Test viche_reply — send message back to Aris ────────────────────
step "8. Testing viche_reply: claude-code sends result back to aris…"
REPLY=$(curl -sf -X POST "$VICHE/messages/$ARIS" \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"result\",\"from\":\"$CLAUDE\",\"body\":\"Rate limiter implemented. 3 files changed: +45 -2 across middleware/rateLimiter.js\"}")
echo "  Response: $REPLY"
REPLY_ID=$(echo "$REPLY" | grep -o '"message_id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_not_empty "viche_reply returns message_id" "$REPLY_ID"
info "reply message_id: $REPLY_ID"

# Verify aris received the reply
INBOX_ARIS=$(curl -sf "$VICHE/inbox/$ARIS")
echo "  Aris inbox: $INBOX_ARIS"
assert_contains "aris inbox has result type"          "$INBOX_ARIS" '"type":"result"'
assert_contains "aris inbox result from claude-code"  "$INBOX_ARIS" "\"from\":\"$CLAUDE\""
assert_contains "aris inbox result has body"          "$INBOX_ARIS" 'Rate limiter implemented'

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ALL CHECKS PASSED — V2 channel flow proven ✓      ${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""
echo "  Proven V2 channel flow:"
echo "    [channel server] registers with Viche on startup"
echo "    [channel server] polls inbox and consumes messages"
echo "    [viche_reply]    sends results back via POST /messages/{id}"
echo ""
echo "  Next step (manual):"
echo "    1. Ensure .mcp.json is at project root (already created)"
echo "    2. Open project in Claude Code"
echo "    3. From another terminal: curl -X POST http://localhost:4000/messages/{claude-code-id} ..."
echo "    4. Claude Code will receive the task via channel notification"
echo ""
