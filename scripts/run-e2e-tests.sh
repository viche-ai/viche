#!/usr/bin/env bash

set -euo pipefail

FAILED=0

echo "========================================"
echo "Starting Phoenix server (MIX_ENV=test)"
echo "========================================"
MIX_ENV=test mix phx.server &
SERVER_PID=$!

trap "kill $SERVER_PID 2>/dev/null || true" EXIT

echo "========================================"
echo "Waiting for health check (30s timeout)"
echo "========================================"
HEALTH_URL="http://localhost:4000/health"
for _ in {1..30}; do
  if curl -fsS "$HEALTH_URL" >/dev/null; then
    echo "Phoenix server is healthy"
    break
  fi
  sleep 1
done

if ! curl -fsS "$HEALTH_URL" >/dev/null; then
  echo "ERROR: Phoenix health check failed after 30 seconds"
  exit 1
fi

echo "========================================"
echo "Running OpenCode plugin E2E tests"
echo "========================================"
(cd channel/opencode-plugin-viche && bun run test:e2e) || FAILED=1

echo "========================================"
echo "Running OpenClaw plugin E2E tests"
echo "========================================"
(cd channel/openclaw-plugin-viche && bun run test:e2e) || FAILED=1

echo "========================================"
echo "Running Claude Code plugin E2E tests"
echo "========================================"
(cd channel/claude-code-plugin-viche && bun run test:e2e) || FAILED=1

echo "========================================"
echo "E2E test summary"
echo "========================================"
if [ "$FAILED" -eq 0 ]; then
  echo "All plugin E2E suites passed"
  exit 0
else
  echo "One or more plugin E2E suites failed"
  exit 1
fi
