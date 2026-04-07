# Plugin E2E Testing — All Three Plugins + CI

## TL;DR

> **Summary**: Add automated E2E tests for all three Viche plugins (Claude Code, OpenCode, OpenClaw) against a live Phoenix server, with a unified CI workflow and shared test harness.
> **Deliverables**: Refactored Claude Code plugin (modularized), E2E test suites for all 3 plugins, shared `scripts/run-e2e-tests.sh`, unified `ci-plugin-e2e.yml` GitHub Actions workflow
> **Effort**: Large (2–3 weeks)
> **Parallel Execution**: YES — 3 waves (Phase 1–2 parallel, Phase 3–5 parallel, Phase 6–7 sequential)

---

## Context

### Original Request
Create automated E2E testing across all three Viche plugins (Claude Code, OpenCode, OpenClaw) to catch integration bugs before deployment, verify protocol compatibility, and enable confident refactoring.

### Research Findings (Wave 0-1)
| Source | Finding | Implication |
|--------|---------|-------------|
| `channel/opencode-plugin-viche/__tests__/e2e.test.ts` (308 lines) | Proven E2E pattern: import plugin, mock client, real Phoenix WebSocket | Follow this pattern for OpenClaw; adapt for Claude Code |
| `channel/claude-code-plugin-viche/viche-server.ts` (674 lines) | Monolithic file — all logic in `main()` | Must refactor to `createVicheServer()` factory before InMemoryTransport testing |
| `channel/openclaw-plugin-viche/service.ts` + `tools.ts` | Already modular (service + tools separated) | Can create E2E tests directly, no refactoring needed |
| `.github/workflows/ci-openclaw-plugin.yml` | NO tests run — only typecheck + build | Must fix: add `bun test` step for unit tests |
| `.github/workflows/ci-opencode-plugin.yml` | Runs `bun run test` (unit only, no E2E) | E2E tests need separate workflow with Phoenix server |
| No Claude Code CI workflow exists | Zero CI coverage for Claude Code plugin | New workflow covers this gap |
| `@modelcontextprotocol/sdk` exports `InMemoryTransport.createLinkedPair()` | Linked transport pair for in-process Client↔Server testing | Enables fast, comprehensive Claude Code E2E tests |

### Interview Decisions
- **Scope**: Full — all three plugins, CI workflow, shared harness
- **Claude Code approach**: InMemoryTransport (requires modularization first)
- **OpenCode approach**: Extend existing `e2e.test.ts` with missing scenarios
- **OpenClaw approach**: New E2E tests following OpenCode pattern
- **CI**: One unified `ci-plugin-e2e.yml` triggered on `channel/` changes
- **No cross-plugin messaging tests**: Elixir server tests cover that
- **No E2E reconnect tests**: Unit tests sufficient

---

## Objectives

### Core Objective
Every plugin has automated E2E tests that verify the complete lifecycle (registration → tool invocation → inbound message delivery → cleanup) against a real Phoenix server, running in CI on every PR that touches `channel/`.

### Scope
| IN (Must Ship) | OUT (Explicit Exclusions) |
|----------------|---------------------------|
| Claude Code plugin modularization (`server.ts`, `tools.ts`, `service.ts`, `main.ts`) | Cross-plugin messaging tests (server-side covers this) |
| E2E test suites for all 3 plugins (9 core scenarios each) | E2E reconnect/recovery tests (unit tests sufficient) |
| OpenCode E2E extension (deregister, concurrent sessions, config validation) | Multi-registry E2E tests (low priority, future work) |
| OpenClaw E2E creation + message correlation test | Performance/load testing |
| Shared `scripts/run-e2e-tests.sh` harness | OpenClaw SDK testing utilities (Approach B — future) |
| Unified `ci-plugin-e2e.yml` GitHub Actions workflow | Changes to existing unit test CI workflows |
| Fix OpenClaw CI to run `bun test` | |

### Definition of Done
- [ ] `scripts/run-e2e-tests.sh` starts Phoenix, runs all 3 plugin E2E suites, exits 0
- [ ] `ci-plugin-e2e.yml` passes on GitHub Actions
- [ ] All E2E tests pass: `bun test __tests__/e2e.test.ts` in each plugin directory
- [ ] `mix precommit` passes (no Elixir regressions)
- [ ] OpenClaw CI runs `bun test` (unit tests)

### What We're NOT Doing
- **Not testing cross-plugin messaging** — the Elixir server's own test suite covers message routing between agents
- **Not testing WebSocket reconnection E2E** — `channel-error-recovery.test.ts` (OpenClaw) and `service.test.ts` (OpenCode) cover this with mocked sockets
- **Not testing multi-registry join/leave E2E** — low priority, can be added later
- **Not modifying existing unit test CI workflows** — the new `ci-plugin-e2e.yml` is additive
- **Not using OpenClaw SDK testing utilities** — the mock API pattern is simpler and proven

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES (OpenCode has proven E2E pattern)
- **Approach**: TDD where applicable (Claude Code modularization), tests-after for extending existing suites
- **Framework**: `bun:test` (all three plugins)
- **Validation**: `scripts/run-e2e-tests.sh` (local), `ci-plugin-e2e.yml` (CI)

### E2E Test Scenarios (All Plugins)
Each plugin's E2E suite covers these 9 core scenarios:

| # | Scenario | Verification Method |
|---|----------|-------------------|
| 1 | Registration (get agent_id from `agent:register` join) | Agent ID matches UUID v4 regex |
| 2 | Discovery (find agents by capability) | `viche_discover` returns agent list containing our ID |
| 3 | Send message (to another agent) | `GET /inbox/:id` confirms delivery with correct `from`, `body`, `type` |
| 4 | Reply (type: result) | `GET /inbox/:id` confirms `type: "result"` |
| 5 | Deregister (partial — specific registry) | Discovery in target registry returns empty; other registries still show agent |
| 6 | Deregister (full — all registries) | Discovery returns empty for all registries |
| 7 | Inbound message delivery (server pushes `new_message`) | Mock session injection called (notification/promptAsync/subagent.run) |
| 8 | Cleanup on stop/disconnect | Agent disappears from discovery after grace period (6s wait) |
| 9 | Config validation (invalid URL, missing capabilities) | Plugin handles gracefully without crash |

**Plugin-specific additions:**
- **OpenCode**: Concurrent sessions (multiple `session.created` events → unique agent IDs)
- **OpenClaw**: Message correlation routing (send from session A → inbound result routes back to session A)

---

## Execution Phases

### Dependency Graph
```
Phase 1 (Claude Code modularization) ──┐
                                        ├──> Phase 3 (Claude Code E2E tests)
Phase 2 (OpenClaw E2E tests) ──────────┤
                                        ├──> Phase 5 (Shared harness)
Phase 4 (OpenCode E2E extension) ──────┤
                                        └──> Phase 6 (CI workflow)
                                                └──> Phase 7 (OpenClaw CI fix)
```

**Wave 1** (parallel): Phase 1 + Phase 2 + Phase 4
**Wave 2** (parallel): Phase 3 + Phase 5 (after Phase 1 completes)
**Wave 3** (sequential): Phase 6 → Phase 7

---

### Phase 1: Modularize Claude Code Plugin

**Goal**: Split the 674-line monolithic `viche-server.ts` into 4 focused modules matching the OpenCode/OpenClaw pattern, enabling InMemoryTransport testing.

**Files** (CONFIRMED by research):
- `channel/claude-code-plugin-viche/viche-server.ts` — DELETE (replaced by modules below)
- `channel/claude-code-plugin-viche/server.ts` — NEW: `createVicheServer()` factory, MCP Server setup, tool handler registration
- `channel/claude-code-plugin-viche/tools.ts` — NEW: tool definitions (discover, send, reply, deregister) + `formatAgentList()`
- `channel/claude-code-plugin-viche/service.ts` — NEW: `connectAndRegister()`, `connectAndRegisterWithRetry()`, `clearActiveConnection()`, `channelPush()`, WebSocket lifecycle, inbound message handler
- `channel/claude-code-plugin-viche/main.ts` — NEW: thin entry point (`if (import.meta.main)` guard), imports `createVicheServer()`, connects transport + service
- `channel/claude-code-plugin-viche/.mcp.json` — MODIFY: update command from `viche-server.ts` to `main.ts`
- `channel/claude-code-plugin-viche/package.json` — MODIFY: add `"test:e2e"` script

**Behavior preservation rules:**
- `createVicheServer()` returns a configured `Server` instance with all tool handlers registered
- `connectAndRegister(server)` takes the server instance and manages WebSocket lifecycle
- `main.ts` calls `createVicheServer()` → `connectAndRegisterWithRetry(server)` → `new StdioServerTransport()` → `server.connect(transport)`
- Module-level state (`activeChannel`, `activeSocket`, `activeAgentId`, `registryChannels`) moves to `service.ts` as module-scoped variables (same pattern as current code)
- `server.notification()` call in `new_message` handler requires the `server` reference — pass it to `connectAndRegister(server)` (already the current pattern)

**Tests** (behaviors, not names):
- Given `createVicheServer()` is called, when `listTools` is requested, then returns 4 tools (discover, send, reply, deregister)
- Given `createVicheServer()` is called, when connected via InMemoryTransport, then Client can call `listTools` and receive tool definitions
- Given `main.ts` is run via `bun main.ts`, when Phoenix server is running, then agent registers successfully (smoke test)

**Commands**:
```bash
# Verify build still works
cd channel/claude-code-plugin-viche && bun run build

# Verify main.ts runs (requires Phoenix server)
cd channel/claude-code-plugin-viche && timeout 10 bun main.ts 2>&1 || true
```

**Dependencies**: None (can start immediately)

**Must NOT do**:
- Change any tool behavior (input schemas, output formats, error messages)
- Change WebSocket connection logic (backoff, retry, error recovery)
- Change MCP notification format for inbound messages
- Add new features — this is a pure refactoring phase

**Pattern Reference**: Follow `channel/opencode-plugin-viche/` module structure (index.ts, service.ts, tools.ts)

**TDD Gates**:
- RED: Write test importing `createVicheServer` from `server.ts` — fails because file doesn't exist
- GREEN: Extract `createVicheServer()` factory, split into 4 files, all imports resolve
- VALIDATE: `bun run build` passes, `bun main.ts` registers against live server
- REFACTOR: Ensure consistent naming with OpenCode/OpenClaw patterns

---

### Phase 2: Create OpenClaw E2E Tests

**Goal**: Create comprehensive E2E test suite for the OpenClaw plugin using mock API + real Phoenix server.

**Files** (CONFIRMED by research):
- `channel/openclaw-plugin-viche/e2e.test.ts` — NEW: E2E test suite (follows OpenCode pattern)
- `channel/openclaw-plugin-viche/package.json` — MODIFY: add `"test:e2e"` and `"test"` scripts

**Test setup pattern** (from research — mock API approach):
```typescript
// Create mock API that captures tool factories
const api = { factories: [], registerTool(f) { this.factories.push(f); }, ... };
// Create shared state
const state = { agentId: null, channel: null, correlations: new Map(), mostRecentSessionKey: null };
// Create mock runtime
const runtime = { subagent: { run: mock(async () => ({ runId: "test" })) } };
// Register tools + start service
registerVicheTools(api, config, state);
const service = createVicheService(config, state, runtime, {});
await service.start({ logger });
```

**Tests** (9 core + 1 plugin-specific):
- Given service started, when checking state.agentId, then it matches UUID v4 format
- Given agent registered, when calling `viche_discover` with `capability: "*"`, then response contains our agent ID
- Given external agent registered via HTTP, when calling `viche_send`, then message appears in external agent's inbox via `GET /inbox/:id`
- Given external agent registered via HTTP, when calling `viche_reply`, then message appears in inbox with `type: "result"`
- Given agent registered with `registries: ["global", "e2e-test-registry"]`, when calling `viche_deregister` with `registry: "e2e-test-registry"`, then agent disappears from that registry but remains in global
- Given agent registered, when calling `viche_deregister` with no registry param, then agent disappears from all registries
- Given agent registered, when POST `/messages/:agent_id` is sent, then `runtime.subagent.run` is called with message content (wait 1s for WebSocket push)
- Given service started, when `service.stop()` is called and 6s elapses, then agent no longer appears in discovery
- Given invalid config (bad URL), when service.start() is called, then it throws/rejects without crashing the process
- **OpenClaw-specific**: Given message sent via `viche_send` from session A, when result reply arrives, then `runtime.subagent.run` is called with session A's sessionKey (correlation routing)

**Commands**:
```bash
# Run E2E tests (requires Phoenix server at localhost:4000)
cd channel/openclaw-plugin-viche && bun test e2e.test.ts

# Run via npm script
cd channel/openclaw-plugin-viche && bun run test:e2e
```

**Dependencies**: None (can start immediately — OpenClaw plugin is already modular)

**Must NOT do**:
- Modify OpenClaw plugin source code (service.ts, tools.ts, index.ts)
- Use OpenClaw SDK testing utilities (keep it simple with mock API)
- Test WebSocket reconnection (unit tests cover this)
- Test multi-registry join/leave (future work)

**Pattern Reference**: Follow `channel/opencode-plugin-viche/__tests__/e2e.test.ts:1-308` structure

**TDD Gates**:
- RED: Create `e2e.test.ts` with first test (registration) — fails because no `test:e2e` script exists
- GREEN: Add `test:e2e` script to `package.json`, implement all 10 tests
- VALIDATE: `bun run test:e2e` passes with Phoenix server running

---

### Phase 3: Create Claude Code E2E Tests

**Goal**: Create E2E test suite for the refactored Claude Code plugin using `InMemoryTransport.createLinkedPair()`.

**Files** (NEW — directory confirmed by research):
- `channel/claude-code-plugin-viche/e2e.test.ts` — NEW: E2E test suite using InMemoryTransport

**Test setup pattern** (from MCP SDK docs):
```typescript
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createVicheServer } from "./server.js";

const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
const server = createVicheServer();
await server.connect(serverTransport);
const client = new Client({ name: "test-client", version: "1.0.0" }, { capabilities: {} });
await client.connect(clientTransport);
// Wait for WebSocket registration to complete
await waitForRegistration(); // poll state or wait for stderr output
```

**Key design decision**: The `createVicheServer()` factory from Phase 1 must expose a way to:
1. Get the active agent ID (for assertions)
2. Know when registration is complete (for test setup)
3. Trigger cleanup (for afterAll)

Options (decide during Phase 1):
- Export getter functions: `getActiveAgentId()`, `isRegistered()`
- Return an object: `{ server, waitForReady(), getAgentId(), cleanup() }`
- Use event emitter pattern

**Tests** (9 core scenarios):
- Given server created via `createVicheServer()`, when client calls `listTools`, then returns 4 tools (discover, send, reply, deregister)
- Given server registered with Phoenix, when client calls `viche_discover` with `capability: "*"`, then response text contains our agent ID
- Given external agent registered via HTTP, when client calls `viche_send`, then message appears in external agent's inbox
- Given external agent registered via HTTP, when client calls `viche_reply`, then message appears in inbox with `type: "result"`
- Given agent registered with multiple registries, when client calls `viche_deregister` with specific registry, then agent leaves only that registry
- Given agent registered, when client calls `viche_deregister` with no params, then agent leaves all registries
- Given agent registered, when POST `/messages/:agent_id` is sent, then client receives MCP notification with message content
- Given server connected, when `server.close()` is called and 6s elapses, then agent no longer appears in discovery
- Given invalid registry URL in env, when `createVicheServer()` + `connectAndRegister()` is called, then it rejects without crashing

**Commands**:
```bash
# Run E2E tests (requires Phoenix server at localhost:4000)
cd channel/claude-code-plugin-viche && bun test e2e.test.ts

# Run via npm script
cd channel/claude-code-plugin-viche && bun run test:e2e
```

**Dependencies**: Phase 1 (Claude Code modularization must be complete)

**Must NOT do**:
- Use subprocess/inspector CLI approach (decided: InMemoryTransport)
- Test stdio transport path (that's integration, not E2E)
- Modify tool behavior

**Pattern Reference**: `@modelcontextprotocol/sdk` InMemoryTransport docs + `channel/opencode-plugin-viche/__tests__/e2e.test.ts` for scenario structure

**TDD Gates**:
- RED: Write test importing `createVicheServer` and calling `client.listTools()` — fails if Phase 1 incomplete
- GREEN: Implement all 9 tests using InMemoryTransport
- VALIDATE: `bun run test:e2e` passes with Phoenix server running

---

### Phase 4: Extend OpenCode E2E Tests

**Goal**: Add missing test scenarios to the existing `__tests__/e2e.test.ts`.

**Files** (CONFIRMED by research):
- `channel/opencode-plugin-viche/__tests__/e2e.test.ts` — MODIFY: add 4 new test cases after existing Test 5

**Existing coverage** (Tests 1–5):
- ✅ Plugin factory shape
- ✅ Registration + discovery
- ✅ viche_send → inbox delivery
- ✅ Inbound WebSocket push → promptAsync
- ✅ Session cleanup → deregistration

**New tests to add** (Tests 6–9):
- **Test 6: viche_reply sends a result message** — Register external agent, call `viche_reply` tool, verify inbox has `type: "result"` message
- **Test 7: viche_deregister (partial)** — Register with `registries: ["global", "e2e-partial-dereg"]`, call deregister with specific registry, verify agent removed from that registry only. Note: this test needs a fresh plugin instance with custom registries (set `VICHE_REGISTRY_TOKEN` env var before import)
- **Test 8: viche_deregister (full)** — Call deregister with no params, verify agent becomes undiscoverable
- **Test 9: concurrent sessions get unique agent IDs** — Create second mock client, load plugin, fire `session.created` for session B, extract agent ID, assert different from session A's agent ID, verify both appear in discovery

**Important**: Tests 7-8 (deregister) modify agent state. They should run AFTER the send/reply tests and BEFORE the cleanup test. Reorder if needed, or use a fresh plugin instance.

**Commands**:
```bash
# Run E2E tests (requires Phoenix server at localhost:4000)
cd channel/opencode-plugin-viche && bun run test:e2e
```

**Dependencies**: None (can start immediately — existing test infrastructure works)

**Must NOT do**:
- Modify existing Tests 1–5 (they work)
- Add config validation tests that require restarting the plugin with bad config (complex setup, low value)
- Break the `mock.module("phoenix")` workaround in beforeAll

**Pattern Reference**: Follow existing test structure in `channel/opencode-plugin-viche/__tests__/e2e.test.ts:167-307`

**TDD Gates**:
- RED: Add Test 6 (viche_reply) — fails because test doesn't exist yet
- GREEN: Implement Tests 6–9
- VALIDATE: `bun run test:e2e` passes with all 9 tests

---

### Phase 5: Shared E2E Test Harness

**Goal**: Create a shell script that starts Phoenix, runs all plugin E2E tests, and tears down cleanly.

**Files**:
- `scripts/run-e2e-tests.sh` — NEW: shared E2E test runner

**Script behavior**:
1. Start Phoenix server in background (`MIX_ENV=test mix phx.server &`)
2. Trap EXIT to kill server on script exit
3. Wait for health check (`GET /health`) with 30s timeout
4. Run OpenCode E2E tests (`cd channel/opencode-plugin-viche && bun run test:e2e`)
5. Run OpenClaw E2E tests (`cd channel/openclaw-plugin-viche && bun run test:e2e`)
6. Run Claude Code E2E tests (`cd channel/claude-code-plugin-viche && bun run test:e2e`)
7. Report results and exit

**Script template**:
```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Viche Plugin E2E Tests ==="

# Start Phoenix server in background
echo "Starting Phoenix server..."
MIX_ENV=test mix phx.server &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT

# Wait for server to be ready
echo "Waiting for server to be ready..."
MAX_WAIT=30
ELAPSED=0
until curl -sf http://localhost:4000/health >/dev/null 2>&1; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "ERROR: Phoenix server did not start within ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
echo "Phoenix server ready (PID: $SERVER_PID)"

# Run E2E tests for each plugin
FAILED=0

echo ""
echo "--- OpenCode Plugin E2E ---"
(cd channel/opencode-plugin-viche && bun run test:e2e) || FAILED=1

echo ""
echo "--- OpenClaw Plugin E2E ---"
(cd channel/openclaw-plugin-viche && bun run test:e2e) || FAILED=1

echo ""
echo "--- Claude Code Plugin E2E ---"
(cd channel/claude-code-plugin-viche && bun run test:e2e) || FAILED=1

echo ""
if [ $FAILED -eq 0 ]; then
  echo "=== All E2E tests passed! ==="
else
  echo "=== Some E2E tests FAILED ==="
  exit 1
fi
```

**Tests** (manual verification):
- Given Phoenix server is NOT running, when `./scripts/run-e2e-tests.sh` is run, then it starts the server and runs tests
- Given all plugins have passing E2E tests, when script runs, then exits 0
- Given one plugin has a failing test, when script runs, then exits 1 (but still runs remaining plugins)

**Commands**:
```bash
chmod +x scripts/run-e2e-tests.sh
./scripts/run-e2e-tests.sh
```

**Dependencies**: Phases 2, 3, 4 (all plugin E2E tests must exist)

**Must NOT do**:
- Start PostgreSQL (Viche uses in-memory state only)
- Install plugin dependencies (assume `bun install` already done)
- Run unit tests (this script is E2E only)

---

### Phase 6: Unified CI Workflow

**Goal**: Create a single GitHub Actions workflow that runs all plugin E2E tests on PRs touching `channel/`.

**Files**:
- `.github/workflows/ci-plugin-e2e.yml` — NEW: unified E2E CI workflow

**Workflow design**:
- **Trigger**: push to `main` + PR, filtered to `channel/**` path changes
- **Services**: PostgreSQL (required by Ecto config even though unused)
- **Setup**: Elixir + OTP + Bun + Node.js
- **Steps**: Install deps → Start Phoenix → Health check → Run all E2E suites
- **Caching**: Elixir deps, _build, Bun install caches

**Workflow template**:
```yaml
name: "CI: Plugin E2E Tests"

on:
  push:
    branches: [main]
    paths:
      - "channel/**"
  pull_request:
    paths:
      - "channel/**"

env:
  MIX_ENV: test
  ELIXIR_VERSION: "1.17"
  OTP_VERSION: "27"

jobs:
  e2e:
    name: Plugin E2E Tests
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: viche_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}

      - name: Set up Bun
        uses: oven-sh/setup-bun@v2

      - name: Cache Elixir deps
        uses: actions/cache@v4
        with:
          path: deps
          key: deps-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-${{ hashFiles('mix.lock') }}
          restore-keys: deps-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-

      - name: Cache _build
        uses: actions/cache@v4
        with:
          path: _build
          key: build-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-${{ env.MIX_ENV }}-${{ hashFiles('mix.lock') }}
          restore-keys: build-${{ runner.os }}-${{ env.ELIXIR_VERSION }}-${{ env.OTP_VERSION }}-${{ env.MIX_ENV }}-

      - name: Install Elixir dependencies
        run: mix deps.get

      - name: Compile
        run: mix compile

      - name: Install OpenCode plugin dependencies
        run: cd channel/opencode-plugin-viche && bun install --frozen-lockfile

      - name: Install OpenClaw plugin dependencies
        run: cd channel/openclaw-plugin-viche && npm install

      - name: Install Claude Code plugin dependencies
        run: cd channel/claude-code-plugin-viche && bun install --frozen-lockfile

      - name: Start Phoenix server
        run: |
          mix phx.server &
          echo "SERVER_PID=$!" >> $GITHUB_ENV

      - name: Wait for Phoenix server
        run: |
          timeout 30 bash -c 'until curl -sf http://localhost:4000/health >/dev/null 2>&1; do sleep 1; done'
          echo "Phoenix server ready"

      - name: Run OpenCode E2E tests
        run: cd channel/opencode-plugin-viche && bun run test:e2e

      - name: Run OpenClaw E2E tests
        run: cd channel/openclaw-plugin-viche && bun run test:e2e

      - name: Run Claude Code E2E tests
        run: cd channel/claude-code-plugin-viche && bun run test:e2e

      - name: Stop Phoenix server
        if: always()
        run: kill $SERVER_PID || true
```

**Tests** (manual verification):
- Given workflow file exists, when PR touches `channel/opencode-plugin-viche/`, then workflow triggers
- Given PR only touches `lib/` (Elixir code), then workflow does NOT trigger
- Given all E2E tests pass, then workflow exits green

**Commands**:
```bash
# Validate workflow syntax
act -l  # or push to branch and check GitHub Actions
```

**Dependencies**: Phases 2, 3, 4, 5 (all E2E tests must exist)

**Must NOT do**:
- Run unit tests (existing per-plugin CI handles that)
- Run `mix precommit` (existing `ci.yml` handles that)
- Create separate workflows per plugin (one unified workflow)

---

### Phase 7: Fix OpenClaw CI to Run Tests

**Goal**: Update the existing `ci-openclaw-plugin.yml` to run `bun test` for unit tests (currently only typechecks + builds).

**Files** (CONFIRMED by research):
- `.github/workflows/ci-openclaw-plugin.yml` — MODIFY: add Bun setup + test step
- `channel/openclaw-plugin-viche/package.json` — MODIFY: add `"test"` script

**Changes to `ci-openclaw-plugin.yml`**:
1. Add `oven-sh/setup-bun@v2` step (currently missing — uses npm but tests need bun)
2. Change `npm install` to `bun install` for consistency
3. Add `bun test` step after build

**Changes to `package.json`**:
```json
"scripts": {
  "build": "tsc",
  "clean": "rm -rf dist",
  "test": "bun test tools-websocket.test.ts channel-error-recovery.test.ts",
  "test:e2e": "bun test e2e.test.ts",
  "prepublishOnly": "npm run clean && npm run build"
}
```

**Commands**:
```bash
# Verify unit tests pass locally
cd channel/openclaw-plugin-viche && bun test
```

**Dependencies**: Phase 2 (E2E test file must exist for `test:e2e` script)

**Must NOT do**:
- Run E2E tests in the unit test CI (no Phoenix server available)
- Change the OpenCode CI workflow (it already works)
- Add Claude Code to per-plugin CI (covered by E2E workflow)

---

## Risks and Mitigations

| Risk | Trigger | Mitigation |
|------|---------|------------|
| InMemoryTransport doesn't support MCP notifications | Claude Code E2E tests can't verify inbound messages | Fall back to subprocess approach (Approach B from research); test notifications separately |
| `mock.module("phoenix")` leakage in OpenCode E2E | New tests break existing tests when run together | Follow existing workaround: re-import phoenix via absolute file path in beforeAll |
| Phoenix server startup race in CI | E2E tests fail because server isn't ready | Health check loop with 30s timeout; fail fast with clear error message |
| OpenClaw `registerTool` factory pattern is hard to mock | Can't extract tool instances for testing | Use the proven pattern from `tools-websocket.test.ts`: create mock API that captures factories |
| Claude Code modularization breaks MCP plugin loading | Claude Code plugin stops working after refactoring | Verify `.mcp.json` points to `main.ts`; smoke test with `bun main.ts` before E2E tests |
| Deregister tests leave agent in bad state for subsequent tests | Tests 7-8 (deregister) affect agent state | Run deregister tests last, or use fresh plugin instance per deregister test |
| CI workflow takes too long (>10 min) | Developer friction, CI queue pressure | E2E tests are fast (each suite ~30s); total with server startup ~2 min |

---

## Success Criteria

### Verification Commands
```bash
# Local: run all E2E tests
./scripts/run-e2e-tests.sh

# Per-plugin (requires Phoenix server running):
cd channel/opencode-plugin-viche && bun run test:e2e
cd channel/openclaw-plugin-viche && bun run test:e2e
cd channel/claude-code-plugin-viche && bun run test:e2e

# Elixir quality gate (no regressions):
mix precommit
```

### Final Checklist
- [ ] All "IN scope" items present
- [ ] All "OUT scope" items absent
- [ ] Claude Code plugin modularized (4 files: server.ts, tools.ts, service.ts, main.ts)
- [ ] All 3 plugins have E2E test files
- [ ] All E2E tests pass against live Phoenix server
- [ ] `scripts/run-e2e-tests.sh` works end-to-end
- [ ] `ci-plugin-e2e.yml` triggers on `channel/` changes
- [ ] OpenClaw CI runs `bun test` (unit tests)
- [ ] `mix precommit` passes
