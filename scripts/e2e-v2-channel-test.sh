#!/usr/bin/env bash
# Viche V2 E2E channel validation — proves the full Claude Code channel flow works end-to-end.
# Verifies: Claude Code starts channel server → registers → receives task via channel
#           notification → executes task → calls viche_reply → result in aris inbox.
#
# Usage:
#   ./scripts/e2e-v2-channel-test.sh
#
# Requirements:
#   - bun available at /Users/ihorkatkov/.bun/bin/bun (or on PATH)
#   - claude CLI available on PATH
#   - Phoenix server not already running (script manages lifecycle)
#   - Run from project root
#   - ANTHROPIC_API_KEY set in environment

set -euo pipefail

VICHE=${VICHE:-http://localhost:4000}
BUN=${BUN:-/Users/ihorkatkov/.bun/bin/bun}
CLAUDE=${CLAUDE_BIN:-claude}

# Temp files for process tracking
PHOENIX_LOG=$(mktemp /tmp/viche-phoenix-XXXXXX.log)
CLAUDE_LOG=$(mktemp /tmp/viche-claude-XXXXXX.log)

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
CLAUDE_PID=""
PHOENIX_PID=""

cleanup() {
  echo ""
  echo -e "${YELLOW}  Cleaning up background processes...${RESET}"

  if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null || true
    info "Claude Code (PID $CLAUDE_PID) terminated"
  fi

  if [ -n "$PHOENIX_PID" ] && kill -0 "$PHOENIX_PID" 2>/dev/null; then
    kill "$PHOENIX_PID" 2>/dev/null || true
    sleep 1
    # Force-kill if still running
    kill -9 "$PHOENIX_PID" 2>/dev/null || true
    info "Phoenix server (PID $PHOENIX_PID) terminated"
  fi

  # Clean up tmp logs
  rm -f "$PHOENIX_LOG" "$CLAUDE_LOG"
}

trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────

title "Channel Integration Test (Claude Code full flow)"

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

# ── Step 1: Start Claude Code with Viche channel ─────────────────────────────
step "1. Starting Claude Code with Viche channel (spawns claude-code-plugin-viche via .mcp.json)…"

# Claude Code spawns viche-server.ts as an MCP subprocess via .mcp.json.
# The channel server registers with Viche and connects via WebSocket.
# We use -p (print mode) with a prompt that tells Claude to:
#   (1) discover the network to confirm registration,
#   (2) process any incoming Viche channel tasks,
#   (3) call viche_reply with the result.
#
# --dangerously-load-development-channels server:viche enables the channel
# notification injection (<channel source="viche"> tags in Claude's context).
# --dangerously-skip-permissions lets Claude call tools without prompting.

"$CLAUDE" \
  --dangerously-load-development-channels server:viche \
  --dangerously-skip-permissions \
  -p "You are registered on the Viche AI agent network as 'claude-code'. \
Do the following in order: \
(1) Call viche_discover with capability='orchestration' to confirm other agents are visible. \
(2) Monitor the Viche channel — an orchestrator agent will send you a task shortly. \
(3) When you receive a task via the <channel source=\"viche\"> notification, execute it and call viche_reply with your result." \
  >"$CLAUDE_LOG" 2>&1 &

CLAUDE_PID=$!
info "Claude Code PID: $CLAUDE_PID  (log: $CLAUDE_LOG)"

# ── Step 2: Wait for channel server (spawned by Claude) to register ──────────
step "2. Waiting for Claude's channel server to register with Viche (up to 30s)…"

REGISTERED=0
for i in $(seq 1 30); do
  DISC=$(curl -sf "$VICHE/registry/discover?name=claude-code" 2>/dev/null || echo "")
  if echo "$DISC" | grep -q "claude-code"; then
    REGISTERED=1
    pass "Channel server registered as 'claude-code' (attempt $i)"
    break
  fi
  # Check if Claude already exited (unexpected early exit)
  if ! kill -0 "$CLAUDE_PID" 2>/dev/null; then
    echo "Claude Code log:"
    cat "$CLAUDE_LOG" || true
    fail "Claude Code exited before channel server registered"
  fi
  sleep 1
done

if [ "$REGISTERED" -eq 0 ]; then
  echo "Claude Code log:"
  cat "$CLAUDE_LOG" || true
  fail "Channel server did not register after 30s"
fi

# ── Step 3: Verify channel agent registered ──────────────────────────────────
step "3. Verifying 'claude-code' registered via /registry/discover…"
DISC=$(curl -sf "$VICHE/registry/discover?name=claude-code")
echo "  Response: $DISC"
assert_contains "discover finds claude-code agent" "$DISC" "claude-code"
assert_contains "discover returns agent id"        "$DISC" '"id"'

# Extract the claude-code agent ID
CLAUDE_AGENT=$(echo "$DISC" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_not_empty "claude-code has an id" "$CLAUDE_AGENT"
info "claude-code agent ID: $CLAUDE_AGENT"

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
SEND=$(curl -sf -X POST "$VICHE/messages/$CLAUDE_AGENT" \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"task\",\"from\":\"$ARIS\",\"body\":\"Implement rate limiter\",\"reply_to\":\"$ARIS\"}")
echo "  Response: $SEND"
MSG_ID=$(echo "$SEND" | grep -o '"message_id":"[^"]*"' | head -1 | cut -d'"' -f4)
assert_not_empty "send returns message_id" "$MSG_ID"
info "message_id: $MSG_ID"

# ── Step 6: Wait for Claude to receive, process, and call viche_reply ─────────
step "6. Waiting for Claude Code to process task and call viche_reply (up to 60s)…"
info "Claude Code processes the channel notification and calls viche_reply automatically."

REPLIED=0
for i in $(seq 1 60); do
  INBOX_ARIS=$(curl -sf "$VICHE/inbox/$ARIS" 2>/dev/null || echo "")
  if echo "$INBOX_ARIS" | grep -q '"type":"result"'; then
    REPLIED=1
    pass "Claude replied to aris via viche_reply (attempt $i)"
    break
  fi
  # Check if Claude exited (might have finished or crashed)
  if ! kill -0 "$CLAUDE_PID" 2>/dev/null && [ "$REPLIED" -eq 0 ]; then
    info "Claude Code process has exited — checking if reply was already sent…"
    INBOX_ARIS=$(curl -sf "$VICHE/inbox/$ARIS" 2>/dev/null || echo "")
    if echo "$INBOX_ARIS" | grep -q '"type":"result"'; then
      REPLIED=1
      pass "Claude replied before exiting (reply found in aris inbox)"
      break
    fi
    echo "Claude Code log:"
    cat "$CLAUDE_LOG" || true
    fail "Claude Code exited without sending viche_reply"
  fi
  sleep 1
done

if [ "$REPLIED" -eq 0 ]; then
  echo "Claude Code log:"
  cat "$CLAUDE_LOG" || true
  fail "Claude Code did not call viche_reply within 60s"
fi

# ── Step 7: Verify inbox was consumed (WebSocket delivery auto-consumes) ──────
step "7. Verifying claude-code inbox was consumed (should be empty)…"
INBOX=$(curl -sf "$VICHE/inbox/$CLAUDE_AGENT")
echo "  Response: $INBOX"
assert_equals "inbox is empty after channel delivery consumed it" "$INBOX" '{"messages":[]}'

# ── Step 8: Verify viche_reply result in aris inbox ─────────────────────────
step "8. Verifying Claude Code's viche_reply arrived in aris inbox…"
INBOX_ARIS=$(curl -sf "$VICHE/inbox/$ARIS")
echo "  Aris inbox: $INBOX_ARIS"
assert_contains "aris inbox has result type"         "$INBOX_ARIS" '"type":"result"'
assert_contains "aris inbox result from claude-code" "$INBOX_ARIS" "\"from\":\"$CLAUDE_AGENT\""

# Show Claude Code log for inspection
info "Claude Code output:"
cat "$CLAUDE_LOG" | sed 's/^/    /' || true

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ALL CHECKS PASSED — V2 full Claude Code flow ✓    ${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""
echo "  Proven V2 full flow:"
echo "    [claude code]     starts claude-code-plugin-viche via .mcp.json"
echo "    [channel server]  registers with Viche on startup"
echo "    [channel server]  receives WebSocket push, sends MCP notification"
echo "    [claude code]     receives <channel source=\"viche\"> tag, executes task"
echo "    [viche_reply]     sends result back to aris"
echo "    [aris inbox]      contains result from claude-code"
echo ""
