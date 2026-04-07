---
date: 2026-04-07T08:04:12Z
researcher: mnemosyne
git_commit: 9f2ded0486a6db694130fb8d69a004d8d8fd1562
branch: feature/register-on-join-websocket
repository: viche
topic: "Research the architecture, lifecycle, and existing test infrastructure of all three Viche plugins to understand what E2E testing paths exist"
scope: channel/claude-code-plugin-viche/, channel/opencode-plugin-viche/, channel/openclaw-plugin-viche/
query_type: map
tags: [research, plugins, e2e-testing, claude-code, opencode, openclaw]
status: complete
confidence: high
sources_scanned:
  files: 47
  thoughts_docs: 0
---

# Research: Viche Plugin E2E Testing Architecture

**Date**: 2026-04-07T08:04:12Z
**Commit**: 9f2ded0486a6db694130fb8d69a004d8d8fd1562
**Branch**: feature/register-on-join-websocket
**Confidence**: high — all three plugins fully analyzed with file:line citations

## Query
Research the architecture, lifecycle, and existing test infrastructure of all three Viche plugins to understand what E2E testing paths exist.

## Summary
All three plugins share a common architecture: TypeScript/Bun runtime, Phoenix Channel WebSocket transport (register-on-join), and four exposed tools (viche_discover, viche_send, viche_reply, viche_deregister). The opencode plugin has the most mature test infrastructure with a working E2E test suite against a live server. The claude-code plugin has zero tests. The openclaw plugin has unit tests only. All plugins use `bun:test` as the test framework.

## Key Entry Points

| Plugin | Entry File | Runtime | Host Protocol |
|--------|------------|---------|---------------|
| claude-code | `channel/claude-code-plugin-viche/viche-server.ts:670` | Bun | MCP stdio |
| opencode | `channel/opencode-plugin-viche/index.ts:85` | Bun | OpenCode Plugin SDK |
| openclaw | `channel/openclaw-plugin-viche/index.ts:19` | Bun | OpenClaw Plugin API |

---

## Plugin 1: claude-code-plugin-viche

### Architecture

**Entry point**: `viche-server.ts:670-674` — `main()` called at module level
**Runtime**: Bun (declared in `.mcp.json:4`)
**Host protocol**: MCP (Model Context Protocol) via stdio transport (`viche-server.ts:656-657`)

**How Claude Code loads it**: Claude Code reads `.mcp.json` at plugin installation. The `mcpServers.viche` entry spawns `bun run viche-server.ts`. Communication is over stdio using `StdioServerTransport`.

### Transport Protocol

**Registration**: WebSocket only (no HTTP)
- `viche-server.ts:184-187` — creates channel on topic `"agent:register"` with registration payload as join params
- `viche-server.ts:138-139` — WebSocket URL: `${registryUrl.replace(/^http/, "ws")}/agent/websocket`

**Channel topics subscribed**:
- `"agent:register"` — primary channel (`viche-server.ts:184`)
- `"registry:{token}"` — one per configured registry token (`viche-server.ts:279-289`)

### Lifecycle

| Phase | Location | Description |
|-------|----------|-------------|
| MCP Server created | `viche-server.ts:386-399` | Creates server with tool + channel capabilities |
| Tool handlers registered | `viche-server.ts:402`, `viche-server.ts:493` | ListTools and CallTool handlers |
| stdio transport started | `viche-server.ts:656-657` | Claude Code can now call tools |
| WebSocket connect | `viche-server.ts:660` | `connectAndRegisterWithRetry()` — 3 attempts, 2000ms backoff |
| Channel join | `viche-server.ts:266` | `registerChannel.join()` |
| On join "ok" | `viche-server.ts:268-295` | Sets `activeAgentId`, joins registry channels |
| Message receive | `viche-server.ts:240-264` | `channel.on("new_message")` → `server.notification()` |
| Shutdown | `viche-server.ts:90-112` | `clearActiveConnection()` — leaves channels, disconnects socket |

### Tools Exposed

| Tool | Location | Channel Event |
|------|----------|---------------|
| `viche_discover` | `viche-server.ts:496-548` | `"discover"` |
| `viche_send` | `viche-server.ts:550-581` | `"send_message"` |
| `viche_reply` | `viche-server.ts:583-604` | `"send_message"` (type: "result") |
| `viche_deregister` | `viche-server.ts:606-650` | `"deregister"` |

### Test Infrastructure

**Test framework**: None
**Test files**: None
**Test commands**: None (`package.json:7` has only `"build": "tsc --noEmit"`)

**What exists**:
- `package.json:6-8` — only script is `"build"`
- No `.test.ts`, `.spec.ts`, or `__tests__/` directory
- No test framework in dependencies

### Build/Run Commands

```bash
# Build (type-check only)
npm run build  # → tsc --noEmit

# Run manually
bun run viche-server.ts

# Claude Code launch
claude --dangerously-load-development-channels plugin:viche@viche
```

### Key Files

| File | Role |
|------|------|
| `viche-server.ts` | Entire plugin (674 lines) — MCP server, WebSocket, tools |
| `package.json` | Dependencies, build script |
| `.mcp.json` | Claude Code MCP server declaration |
| `.claude-plugin/plugin.json` | Marketplace metadata, config schema |
| `hooks/hooks.json` | SessionStart hook for `bun install` |

---

## Plugin 2: opencode-plugin-viche

### Architecture

**Entry point**: `index.ts:85-88` — exports `vichePlugin` async factory function
**Runtime**: Bun (`package.json:19-21` — test scripts use `bun test`)
**Host protocol**: OpenCode Plugin SDK (peer dependency)

**How OpenCode loads it**: Plugin exports `{ event, tool }` hooks object. OpenCode calls the factory with `{ client, directory }`.

### Transport Protocol

**Registration**: WebSocket only (no HTTP)
- `service.ts:104-108` — Phoenix Socket to `${wsBase}/agent/websocket`
- `service.ts:117-119` — channel on topic `"agent:register"` with config as join payload

**Channel topics subscribed**:
- `"agent:register"` — primary channel (`service.ts:117-119`)
- `"registry:{token}"` — one per configured registry (`service.ts:165-175`)

### Lifecycle

| Phase | Location | Description |
|-------|----------|-------------|
| Plugin load | `index.ts:90-102` | `loadConfig()`, create state, create service + tools |
| session.created | `index.ts:119-124` | ROOT sessions only → `service.handleSessionCreated()` |
| ensureSessionReady | `service.ts:408-436` | Idempotent init — returns existing or starts new |
| initSession | `service.ts:296-393` | `registerAgent()` → `connectWebSocket()` |
| Channel join | `service.ts:148-163` | On "ok" → extract `agent_id`, join registry channels |
| Message receive | `service.ts:121-123` | `channel.on("new_message")` → `handleInboundMessage()` |
| handleInboundMessage | `service.ts:269-290` | `client.session.promptAsync()` injection |
| session.deleted | `index.ts:127-129` | `service.handleSessionDeleted()` |
| teardownSession | `service.ts:194-221` | `channel.leave()`, registry channels leave, `socket.disconnect()` |

### Tools Exposed

| Tool | Location | Channel Event |
|------|----------|---------------|
| `viche_discover` | `tools.ts:211-268` | `"discover"` |
| `viche_send` | `tools.ts:272-316` | `"send_message"` |
| `viche_reply` | `tools.ts:320-360` | `"send_message"` (type: "result") |
| `viche_deregister` | `tools.ts:364-414` | `"deregister"` |

### Test Infrastructure

**Test framework**: `bun:test`
**Test files**: 9 files in `__tests__/`

| File | Lines | Coverage |
|------|-------|----------|
| `config.test.ts` | 417 | Config loading, defaults, env vars, token validation |
| `config-home-fallback.test.ts` | 199 | Home directory fallback logic |
| `config-integration.test.ts` | 223 | Config → service integration |
| `index.test.ts` | 266 | Plugin entry, session routing, tool presence |
| `service.test.ts` | 359 | WebSocket lifecycle, retry, recovery, teardown |
| `tools.test.ts` | 151 | Tool channel events, payloads |
| `multi-registry-resilience.test.ts` | 50 | Discovery error handling |
| `discover-response-schema-validation.test.ts` | 54 | Malformed response handling |
| `e2e.test.ts` | 308 | **Full E2E against live server** |

**Mocking patterns**:
- `mock.module("phoenix", ...)` — replaces Phoenix Socket (`service.test.ts:80`)
- `MockSocket` class captures constructor args, delegates to `mock()` functions
- `makeJoinSequence()` — controls join outcomes (`service.test.ts:19-45`)
- `backoffMs: 0` option eliminates retry delays (`service.test.ts:315`)

### E2E Test Details (`__tests__/e2e.test.ts`)

**Requires**: Live Phoenix server at `http://localhost:4000`

| Test | Lines | What it verifies |
|------|-------|------------------|
| Plugin shape | `167-193` | Returns `{ event, tool }` with all tools |
| Real registration + discovery | `198-213` | Agent appears in `viche_discover` results |
| Message delivery | `217-240` | `viche_send` delivers to inbox (verified via HTTP) |
| Inbound push | `244-280` | HTTP POST triggers WebSocket push → `promptAsync()` |
| Cleanup on delete | `284-307` | `session.deleted` disconnects, agent disappears |

**E2E setup** (`e2e.test.ts:100-149`):
- Re-pins real Phoenix via absolute file path import (bypasses `mock.module` leakage)
- Loads plugin, fires `session.created`, extracts `ourAgentId`
- Only mock: `mockClient` — plain object with `session.prompt/promptAsync` mocks

### Build/Run Commands

```bash
# Build
npm run build  # → tsc

# Unit tests (excludes e2e)
npm test  # → bun test __tests__/config.test.ts ... (explicit list)

# E2E tests (requires live server)
npm run test:e2e  # → bun test __tests__/e2e.test.ts

# All tests
npm run test:all  # → npm run test && npm run test:e2e
```

### Key Files

| File | Role |
|------|------|
| `index.ts` | Plugin factory, session routing |
| `service.ts` | WebSocket lifecycle, message relay, recovery |
| `tools.ts` | Tool definitions, Zod schemas, `pushWithAck` |
| `config.ts` | Multi-source config resolution |
| `types.ts` | TypeScript interfaces |
| `__tests__/e2e.test.ts` | E2E test suite |

---

## Plugin 3: openclaw-plugin-viche

### Architecture

**Entry point**: `index.ts:19` — exports default object with `register(api)` method
**Runtime**: Bun (`tools-websocket.test.ts:1` imports from `"bun:test"`)
**Host protocol**: OpenClaw Plugin API

**How OpenClaw loads it**: Reads `package.json:56-60` `"openclaw": { "extensions": ["./dist/index.js"] }`, imports and calls `.register(api)`.

### Transport Protocol

**Registration**: WebSocket only (no HTTP)
- `service.ts:203` — Phoenix Socket to `${wsBase}/agent/websocket`
- `service.ts:218` — channel on topic `"agent:register"` with registration payload

**Channel topics subscribed**:
- `"agent:register"` — primary channel (`service.ts:218`)
- `"registry:{token}"` — one per configured registry (`service.ts:315`)

### Lifecycle

| Phase | Location | Description |
|-------|----------|-------------|
| Plugin register | `index.ts:28` | `register(api)` called by OpenClaw |
| Config parse | `index.ts:32-38` | `VicheConfigSchema.safeParse(api.config)` |
| Service start | `index.ts:44-45` | `createVicheService().start(ctx)` |
| connectAndRegisterOnce | `service.ts:201-339` | Socket connect, channel create, join |
| On join "ok" | `service.ts:298-325` | Extract `agent_id`, join registry channels |
| Message receive | `service.ts:286-293` | `channel.on("new_message")` → `handleInboundMessage()` |
| handleInboundMessage | `service.ts:121-163` | `runtime.subagent.run()` injection |
| Channel error recovery | `service.ts:230-284` | Re-registers with new `agent_id` |
| Service stop | `service.ts:394-422` | `channel.leave()`, `socket.disconnect()` |

### Tools Exposed

| Tool | Location | Channel Event |
|------|----------|---------------|
| `viche_discover` | `tools.ts:162-228` | `"discover"` |
| `viche_send` | `tools.ts:236-304` | `"send_message"` |
| `viche_reply` | `tools.ts:309-360` | `"send_message"` (type: "result") |
| `viche_deregister` | `tools.ts:365-423` | `"deregister"` |

### Test Infrastructure

**Test framework**: `bun:test`
**Test files**: 2 files

| File | Lines | Coverage |
|------|-------|----------|
| `tools-websocket.test.ts` | 101 | Tool channel events, no HTTP fetch |
| `channel-error-recovery.test.ts` | 222 | Service recovery flow |

**Test commands**: None in `package.json`. Run directly with `bun test`.

**Mocking patterns**:
- `mock.module("phoenix", ...)` — replaces Phoenix Socket (`channel-error-recovery.test.ts:58-66`)
- `createChannel(status, payload)` — fake channel with fluent `receive()` (`tools-websocket.test.ts:12-21`)
- `globalThis.fetch` replaced with throwing mock (`tools-websocket.test.ts:41-43`)

**What is NOT tested**:
- `viche_deregister` tool
- Config validation (`VicheConfigSchema`)
- Session routing (`resolveSessionKey`)
- Registry channel join
- `handleInboundMessage` routing
- `viche_discover` with token param

### Build/Run Commands

```bash
# Build
npm run build  # → tsc

# Clean
npm run clean  # → rm -rf dist

# Tests (no npm script)
bun test  # auto-discovers *.test.ts
```

### Key Files

| File | Role |
|------|------|
| `index.ts` | Plugin entry, config parse, service/tools init |
| `service.ts` | WebSocket lifecycle, message routing, recovery |
| `tools.ts` | Tool definitions, validation helpers |
| `types.ts` | TypeScript types, `VicheConfigSchema` |
| `openclaw.plugin.json` | Plugin manifest for OpenClaw |

---

## Cross-Plugin Comparison

### Test Infrastructure Summary

| Plugin | Framework | Unit Tests | E2E Tests | Test Command |
|--------|-----------|------------|-----------|--------------|
| claude-code | None | 0 files | None | None |
| opencode | bun:test | 8 files | 1 file | `npm test`, `npm run test:e2e` |
| openclaw | bun:test | 2 files | None | `bun test` |

### Shared Architecture Patterns

All three plugins share:
1. **Runtime**: Bun
2. **Transport**: Phoenix Channel WebSocket (register-on-join)
3. **Registration topic**: `"agent:register"` with config as join payload
4. **Registry topics**: `"registry:{token}"` for each configured registry
5. **Tools**: `viche_discover`, `viche_send`, `viche_reply`, `viche_deregister`
6. **Inbound event**: `"new_message"` on agent channel
7. **Reconnect backoff**: `[1000, 2000, 5000, 10000]` ms schedule

### What "E2E" Means for Each Plugin

| Plugin | E2E Definition |
|--------|----------------|
| claude-code | Start Phoenix → spawn `viche-server.ts` → send MCP `tools/call` → verify WebSocket delivery → verify `server.notification()` |
| opencode | Start Phoenix → load plugin → fire `session.created` → call tools → verify WebSocket delivery → verify `client.session.promptAsync()` |
| openclaw | Start Phoenix → start OpenClaw Gateway → call tools → verify WebSocket delivery → verify `runtime.subagent.run()` |

### Existing E2E Patterns (opencode only)

The opencode plugin's `e2e.test.ts` provides a reference implementation:

1. **Server requirement**: Live Phoenix at `http://localhost:4000`
2. **Mock bypass**: Re-import phoenix via absolute file path (`e2e.test.ts:108-116`)
3. **Minimal mocking**: Only mock the SDK client, not transport
4. **HTTP verification**: Use `fetch()` to verify inbox delivery
5. **Timing**: `wait(1000)` and `wait(6000)` for async operations
6. **Cleanup**: `session.deleted` event triggers teardown

---

## Gaps Identified

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| No tests in claude-code plugin | "test", "spec", "jest", "vitest", "bun:test" | `channel/claude-code-plugin-viche/` |
| No E2E tests in openclaw plugin | "e2e", "integration", "live server" | `channel/openclaw-plugin-viche/` |
| No `viche_deregister` test in openclaw | "deregister", "test" | `channel/openclaw-plugin-viche/` |
| No config validation tests in openclaw | "VicheConfigSchema", "safeParse", "test" | `channel/openclaw-plugin-viche/` |

---

## Evidence Index

### Code Files

**claude-code-plugin-viche**:
- `viche-server.ts:670-674` — main entry point
- `viche-server.ts:386-399` — MCP server creation
- `viche-server.ts:184-187` — channel creation
- `viche-server.ts:240-264` — message receive handler
- `viche-server.ts:496-650` — tool handlers
- `.mcp.json:4-5` — Bun runtime declaration
- `package.json:6-8` — scripts (build only)

**opencode-plugin-viche**:
- `index.ts:85-88` — plugin factory
- `service.ts:104-108` — Socket creation
- `service.ts:117-119` — channel creation
- `service.ts:269-290` — message injection
- `tools.ts:211-414` — tool definitions
- `__tests__/e2e.test.ts:100-307` — E2E test suite
- `package.json:19-21` — test scripts

**openclaw-plugin-viche**:
- `index.ts:19-28` — plugin entry
- `service.ts:201-339` — WebSocket lifecycle
- `service.ts:121-163` — message handling
- `tools.ts:162-423` — tool definitions
- `tools-websocket.test.ts:1-101` — unit tests
- `channel-error-recovery.test.ts:14-222` — recovery tests

---

## Handoff Inputs

**If planning E2E test infrastructure** (for @prometheus):
- Scope: All three plugins under `channel/`
- Reference implementation: `channel/opencode-plugin-viche/__tests__/e2e.test.ts`
- Test framework: `bun:test` (already used by opencode and openclaw)
- Server requirement: Live Phoenix at `http://localhost:4000`
- Key challenge: claude-code uses MCP stdio (not direct function calls)
- Key challenge: openclaw requires OpenClaw Gateway runtime

**If implementing E2E tests** (for @vulkanus):
- Test location: `__tests__/e2e.test.ts` in each plugin
- Pattern to follow: opencode's E2E test structure
- Mock bypass: Import phoenix via absolute file path
- Verification: HTTP `GET /inbox/{agentId}` for message delivery
