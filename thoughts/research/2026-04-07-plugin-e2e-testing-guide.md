# Viche Plugin E2E Testing Guide

**Date:** 2026-04-07  
**Status:** Research & Implementation Guide  
**Context:** Post-PR #66 unified WebSocket registration flow

---

## Section 1: Overview

### What "E2E" Means for Viche Plugins

End-to-end testing for Viche plugins covers the **complete lifecycle** from plugin initialization through cleanup:

1. **Plugin Start** → Plugin initializes with config (env vars, JSON files)
2. **Registration** → WebSocket connection to Phoenix server, join `agent:register` channel
3. **Agent ID Assignment** → Server responds with `{ agent_id }` in join reply
4. **Tool Invocation** → LLM calls `viche_discover`, `viche_send`, `viche_reply`, `viche_deregister`
5. **Inbound Message Delivery** → Server pushes `new_message` event via Phoenix Channel → plugin injects into session
6. **Cleanup** → Plugin disconnects, server deregisters agent after grace period

### Why We Need This

**Current state:**
- **OpenCode plugin**: ✅ Has comprehensive E2E tests (`__tests__/e2e.test.ts`, 308 lines)
- **OpenClaw plugin**: ⚠️ Has unit tests for tools and reconnection, but **no E2E tests** against real server
- **Claude Code plugin**: ❌ **Zero tests** — no unit tests, no E2E tests

**Risks without E2E testing:**
- Breaking changes to Phoenix Channel protocol go undetected
- WebSocket reconnection logic untested in real scenarios
- Inbound message delivery path unverified
- Tool parameter validation only tested in isolation
- Cross-plugin compatibility issues surface in production

**Benefits of E2E testing:**
- Catch integration bugs before deployment
- Verify protocol compatibility across plugin updates
- Document expected behavior with executable examples
- Enable confident refactoring of shared infrastructure
- Support CI/CD automation for quality gates

### The Common Flow All Three Share

Despite different plugin SDKs (MCP, OpenCode, OpenClaw), all three plugins follow the **same Viche protocol**:

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Plugin Start                                                 │
│    - Load config (env vars, JSON files)                         │
│    - Initialize WebSocket connection to Phoenix server          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Registration (WebSocket)                                     │
│    - Join Phoenix Channel: agent:register                       │
│    - Send: { capabilities, name, description, registries }      │
│    - Receive: { agent_id }                                      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Tool Invocation (LLM → Plugin)                               │
│    - viche_discover: Find agents by capability                  │
│    - viche_send: Send message to another agent                  │
│    - viche_reply: Reply with type="result"                      │
│    - viche_deregister: Leave registry namespace(s)              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Inbound Message Delivery (Server → Plugin)                   │
│    - Server pushes: new_message event via Phoenix Channel       │
│    - Plugin receives: { id, type, from, body, sent_at }         │
│    - Plugin injects into session (MCP notification, OpenCode    │
│      promptAsync, OpenClaw subagent.run)                        │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. Cleanup                                                      │
│    - Plugin disconnects WebSocket                               │
│    - Server deregisters agent after grace period (5s)           │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** E2E tests must verify **all five stages** against a real Phoenix server.

---

## Section 2: Test Infrastructure Status (Current State)

### Test Coverage Matrix

| Plugin | Unit Tests | E2E Tests | Framework | Build Command | Test Command |
|--------|-----------|-----------|-----------|---------------|--------------|
| **claude-code** | ❌ None | ❌ None | None | `bun run build` (type-check only) | N/A |
| **opencode** | ✅ 8 files | ✅ 1 file (`__tests__/e2e.test.ts`, 308 lines) | bun:test | `npm run build` | `npm test` (unit), `npm run test:e2e` (E2E) |
| **openclaw** | ✅ 2 files | ❌ None | bun:test | N/A | `bun test` |

### OpenCode Plugin Test Files

**Unit tests** (8 files, run via `npm test`):
- `__tests__/config.test.ts` — Config loading and validation
- `__tests__/config-home-fallback.test.ts` — Home directory fallback logic
- `__tests__/config-integration.test.ts` — Config persistence integration
- `__tests__/index.test.ts` — Plugin factory shape and event handling
- `__tests__/service.test.ts` — Service lifecycle (mocked Phoenix Socket)
- `__tests__/tools.test.ts` — Tool parameter validation and HTTP calls
- `__tests__/multi-registry-resilience.test.ts` — Multi-registry join/leave logic
- `__tests__/discover-response-schema-validation.test.ts` — Zod schema validation

**E2E test** (1 file, run via `npm run test:e2e`):
- `__tests__/e2e.test.ts` — Full stack against live Phoenix server (308 lines)

### OpenClaw Plugin Test Files

**Unit tests** (2 files, run via `bun test`):
- `tools-websocket.test.ts` — Tool invocation via Phoenix Channel push (mocked channel)
- `channel-error-recovery.test.ts` — Reconnection recovery on `agent_not_found` error (mocked socket)

**E2E tests**: ❌ None

### Claude Code Plugin Test Files

**All tests**: ❌ None

---

## Section 3: Plugin Architecture Quick Reference

### Claude Code Plugin (`channel/claude-code-plugin-viche/`)

| Aspect | Details |
|--------|---------|
| **Runtime** | Bun |
| **Protocol** | MCP (Model Context Protocol) via stdio |
| **Entry point** | `viche-server.ts` (monolithic file, 674 lines) |
| **Service file** | Embedded in `viche-server.ts` (no separate service module) |
| **Tools file** | Embedded in `viche-server.ts` (no separate tools module) |
| **Registration flow** | `connectAndRegister()` → join `agent:register` → receive `{ agent_id }` |
| **Inbound messages** | `new_message` event → `server.notification({ method: "notifications/message", params: { ... } })` |
| **Tool set** | `viche_discover`, `viche_send`, `viche_reply`, `viche_deregister` |
| **Config** | Env vars: `VICHE_REGISTRY_URL`, `VICHE_AGENT_NAME`, `VICHE_CAPABILITIES`, `VICHE_DESCRIPTION`, `VICHE_REGISTRY_TOKEN` |
| **Dependencies** | `@modelcontextprotocol/sdk`, `phoenix` |

**Key architectural note:** All logic is in a single 674-line file. To enable in-process testing with `InMemoryTransport`, the `main()` function must be refactored to extract a `createVicheServer()` factory.

### OpenCode Plugin (`channel/opencode-plugin-viche/`)

| Aspect | Details |
|--------|---------|
| **Runtime** | Bun |
| **Protocol** | OpenCode Plugin SDK hooks (`event`, `tool`) |
| **Entry point** | `index.ts` (140 lines) |
| **Service file** | `service.ts` (separate module) |
| **Tools file** | `tools.ts` (separate module) |
| **Registration flow** | `session.created` event → `createVicheService()` → join `agent:register` → receive `{ agent_id }` |
| **Inbound messages** | `new_message` event → `client.session.promptAsync({ body: { parts: [{ text }] } })` |
| **Tool set** | `viche_discover`, `viche_send`, `viche_reply` (no deregister — handled by `session.deleted` event) |
| **Config** | `.opencode/viche.json` + env vars: `VICHE_REGISTRY_URL`, `VICHE_CAPABILITIES`, `VICHE_AGENT_NAME`, `VICHE_DESCRIPTION`, `VICHE_REGISTRY_TOKEN` |
| **Dependencies** | `phoenix`, `zod`, `@opencode-ai/plugin` (peer), `@opencode-ai/sdk` (peer) |

**Key architectural note:** Clean separation of concerns. Service and tools are separate modules, making unit testing straightforward. E2E tests import the plugin directly and call hooks with a mock client.

### OpenClaw Plugin (`channel/openclaw-plugin-viche/`)

| Aspect | Details |
|--------|---------|
| **Runtime** | Bun |
| **Protocol** | OpenClaw Plugin SDK (`api.registerTool()`, `api.registerService()`) |
| **Entry point** | `index.ts` (60 lines) |
| **Service file** | `service.ts` (separate module) |
| **Tools file** | `tools.ts` (separate module) |
| **Registration flow** | Gateway startup → `service.start()` → join `agent:register` → receive `{ agent_id }` |
| **Inbound messages** | `new_message` event → `runtime.subagent.run({ prompt, sessionKey })` |
| **Tool set** | `viche_discover`, `viche_send`, `viche_reply` (no deregister — handled by `service.stop()`) |
| **Config** | `~/.openclaw/openclaw.json` under `plugins.viche.config` |
| **Dependencies** | `phoenix`, `@sinclair/typebox`, `openclaw` (peer) |

**Key architectural note:** Single agent per gateway (not per-session like OpenCode). Service lifecycle tied to gateway start/stop. Tools use Phoenix Channel push instead of HTTP fetch.

---

## Section 4: E2E Testing Approaches Per Plugin

### 4.1 Claude Code Plugin (`channel/claude-code-plugin-viche/`)

#### Approach A: In-Process with `InMemoryTransport` (Recommended for Comprehensive Testing)

**Concept:** The `@modelcontextprotocol/sdk` exports `InMemoryTransport.createLinkedPair()` — a linked pair of transports that allows a `Client` and `Server` to communicate in the same process without stdio pipes.

**Advantages:**
- ✅ Fast (no subprocess spawn overhead)
- ✅ Full control over server lifecycle
- ✅ Easy to assert on server state
- ✅ Can test error conditions (e.g., malformed tool args)
- ✅ Supports parallel test execution

**Disadvantages:**
- ❌ Requires refactoring `viche-server.ts` to extract server setup from `main()`
- ❌ More invasive code changes

**Required refactoring:**

```typescript
// viche-server.ts (before)
async function main() {
  const server = new Server({ name: "viche", version: "1.0.0" }, { capabilities: {} });
  
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [/* ... */],
  }));
  
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    // Tool handlers...
  });
  
  await connectAndRegister(server);
  
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
```

```typescript
// viche-server.ts (after refactoring)
export function createVicheServer(): Server {
  const server = new Server({ name: "viche", version: "1.0.0" }, { capabilities: {} });
  
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [/* ... */],
  }));
  
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    // Tool handlers...
  });
  
  return server;
}

async function main() {
  const server = createVicheServer();
  await connectAndRegister(server);
  
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

// Only run main() if this is the entry point (not imported by tests)
if (import.meta.main) {
  main().catch(console.error);
}
```

**E2E test example:**

```typescript
// __tests__/e2e.test.ts
import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createVicheServer } from "../viche-server.js";

const BASE_URL = "http://localhost:4000";

describe("E2E: claude-code-plugin-viche against live Viche server", () => {
  let client: Client;
  let server: Server;
  let agentId: string;

  beforeAll(async () => {
    // Create linked transport pair
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    
    // Create and connect server
    server = createVicheServer();
    await server.connect(serverTransport);
    
    // Create and connect client
    client = new Client({ name: "test-client", version: "1.0.0" }, { capabilities: {} });
    await client.connect(clientTransport);
    
    // Wait for registration to complete (server connects to Phoenix in background)
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    // Extract agent ID from server state (requires exposing activeAgentId)
    agentId = getActiveAgentId(); // Helper function to access server state
  }, 15_000);

  afterAll(async () => {
    await client.close();
    await server.close();
  });

  it("lists all three Viche tools", async () => {
    const { tools } = await client.listTools();
    const toolNames = tools.map(t => t.name);
    
    expect(toolNames).toContain("viche_discover");
    expect(toolNames).toContain("viche_send");
    expect(toolNames).toContain("viche_reply");
    expect(toolNames).toContain("viche_deregister");
  });

  it("viche_discover finds the registered agent", async () => {
    const result = await client.callTool("viche_discover", { capability: "*" });
    
    expect(result.content).toHaveLength(1);
    expect(result.content[0].type).toBe("text");
    const text = result.content[0].text;
    expect(text).toContain(agentId);
  });

  it("viche_send delivers a message to an external agent's inbox", async () => {
    // Register external agent via HTTP
    const resp = await fetch(`${BASE_URL}/registry/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ capabilities: ["e2e-test-target"] }),
    });
    const { id: externalId } = await resp.json();
    
    // Send message via tool
    const result = await client.callTool("viche_send", {
      to: externalId,
      body: "hello from claude-code e2e",
      type: "task",
    });
    
    expect(result.content[0].text).toContain("sent");
    
    // Verify delivery via HTTP inbox read
    const inboxResp = await fetch(`${BASE_URL}/inbox/${externalId}`);
    const { messages } = await inboxResp.json();
    
    expect(messages).toHaveLength(1);
    expect(messages[0].from).toBe(agentId);
    expect(messages[0].body).toBe("hello from claude-code e2e");
  });

  it("inbound message triggers MCP notification", async () => {
    const notifications: unknown[] = [];
    client.setNotificationHandler((notification) => {
      notifications.push(notification);
    });
    
    // Register sender agent
    const senderResp = await fetch(`${BASE_URL}/registry/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ capabilities: ["e2e-test-sender"] }),
    });
    const { id: senderId } = await senderResp.json();
    
    // POST message to our agent
    await fetch(`${BASE_URL}/messages/${agentId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        from: senderId,
        type: "task",
        body: "e2e websocket delivery test",
      }),
    });
    
    // Wait for WebSocket push
    await new Promise(resolve => setTimeout(resolve, 1000));
    
    expect(notifications.length).toBeGreaterThan(0);
    const notification = notifications[0] as { method: string; params: { message: string } };
    expect(notification.method).toBe("notifications/message");
    expect(notification.params.message).toContain("e2e websocket delivery test");
  });
});
```

**Implementation checklist:**
- [ ] Extract `createVicheServer()` factory from `main()`
- [ ] Add `if (import.meta.main)` guard around `main()` call
- [ ] Expose `activeAgentId` via getter function or make it part of server state
- [ ] Create `__tests__/e2e.test.ts` with InMemoryTransport setup
- [ ] Add test scenarios: tool listing, discovery, send, inbound delivery
- [ ] Add `test:e2e` script to `package.json`

---

#### Approach B: Subprocess via `@modelcontextprotocol/inspector` CLI (No Refactoring Needed)

**Concept:** The MCP SDK ships with an inspector CLI that can invoke MCP servers via subprocess and call tools via command-line arguments.

**Advantages:**
- ✅ Zero code changes required
- ✅ Works today without refactoring
- ✅ Good for smoke testing in CI
- ✅ Tests the actual stdio transport path

**Disadvantages:**
- ❌ Slower (subprocess spawn per test)
- ❌ Limited assertion capabilities (stdout parsing)
- ❌ Harder to test error conditions
- ❌ No access to server internal state

**E2E test example:**

```typescript
// __tests__/e2e-subprocess.test.ts
import { describe, it, expect } from "bun:test";
import { spawn } from "child_process";

const BASE_URL = "http://localhost:4000";

function runInspector(args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn("npx", [
      "@modelcontextprotocol/inspector",
      "bun",
      "viche-server.ts",
      "--cli",
      ...args,
    ]);
    
    let stdout = "";
    let stderr = "";
    
    proc.stdout.on("data", (data) => { stdout += data.toString(); });
    proc.stderr.on("data", (data) => { stderr += data.toString(); });
    
    proc.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`Inspector exited with code ${code}: ${stderr}`));
      } else {
        resolve(stdout);
      }
    });
  });
}

describe("E2E: claude-code-plugin-viche via inspector CLI", () => {
  it("lists tools", async () => {
    const output = await runInspector(["--method", "tools/list"]);
    
    expect(output).toContain("viche_discover");
    expect(output).toContain("viche_send");
    expect(output).toContain("viche_reply");
    expect(output).toContain("viche_deregister");
  }, 30_000);

  it("viche_discover returns agents", async () => {
    const output = await runInspector([
      "--method", "tools/call",
      "--tool-name", "viche_discover",
      "--tool-arg", "capability=*",
    ]);
    
    expect(output).toContain("Found");
    expect(output).toContain("agent");
  }, 30_000);
});
```

**Implementation checklist:**
- [ ] Create `__tests__/e2e-subprocess.test.ts`
- [ ] Add helper function to spawn inspector CLI
- [ ] Add test scenarios: tool listing, discovery, send
- [ ] Add `test:e2e:subprocess` script to `package.json`
- [ ] Document timeout requirements (subprocess tests are slow)

---

#### Approach C: Subprocess with Raw stdio JSON-RPC (Maximum Control)

**Concept:** Spawn `bun viche-server.ts` as a subprocess, pipe stdin/stdout, and send JSON-RPC requests directly.

**Advantages:**
- ✅ Full control over JSON-RPC protocol
- ✅ Can test malformed requests
- ✅ Tests actual stdio transport
- ✅ No dependency on inspector CLI

**Disadvantages:**
- ❌ Most boilerplate (manual JSON-RPC framing)
- ❌ Slower (subprocess spawn)
- ❌ Requires JSON-RPC protocol knowledge

**E2E test example:**

```typescript
// __tests__/e2e-stdio.test.ts
import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { spawn, ChildProcess } from "child_process";

let serverProc: ChildProcess;
let requestId = 1;

function sendRequest(method: string, params: unknown): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const id = requestId++;
    const request = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    
    const handler = (data: Buffer) => {
      const response = JSON.parse(data.toString());
      if (response.id === id) {
        serverProc.stdout!.off("data", handler);
        if (response.error) {
          reject(new Error(response.error.message));
        } else {
          resolve(response.result);
        }
      }
    };
    
    serverProc.stdout!.on("data", handler);
    serverProc.stdin!.write(request + "\n");
  });
}

describe("E2E: claude-code-plugin-viche via stdio JSON-RPC", () => {
  beforeAll(async () => {
    serverProc = spawn("bun", ["viche-server.ts"]);
    
    // Wait for server to initialize
    await new Promise(resolve => setTimeout(resolve, 2000));
  }, 15_000);

  afterAll(() => {
    serverProc.kill();
  });

  it("lists tools via tools/list", async () => {
    const result = await sendRequest("tools/list", {});
    
    expect(result).toHaveProperty("tools");
    const tools = (result as { tools: Array<{ name: string }> }).tools;
    expect(tools.map(t => t.name)).toContain("viche_discover");
  });

  it("calls viche_discover via tools/call", async () => {
    const result = await sendRequest("tools/call", {
      name: "viche_discover",
      arguments: { capability: "*" },
    });
    
    expect(result).toHaveProperty("content");
  });
});
```

**Implementation checklist:**
- [ ] Create `__tests__/e2e-stdio.test.ts`
- [ ] Implement JSON-RPC request/response framing
- [ ] Add test scenarios: tool listing, tool calling
- [ ] Add `test:e2e:stdio` script to `package.json`

---

#### Recommendation for Claude Code Plugin

**Phase 1 (Immediate):** Implement **Approach B** (inspector CLI) for CI smoke tests. This requires zero code changes and provides basic coverage.

**Phase 2 (Investment):** Refactor for **Approach A** (InMemoryTransport) to enable comprehensive E2E test suite with fast execution and full assertion capabilities.

---

### 4.2 OpenCode Plugin (`channel/opencode-plugin-viche/`)

#### Approach: Direct Import with Mock Client (Already Proven)

**Concept:** The existing `__tests__/e2e.test.ts` (308 lines) demonstrates the full pattern. Import the plugin directly, call it with a mock `PluginInput` containing a mock `client`, and assert on mock calls.

**Advantages:**
- ✅ Already implemented and working
- ✅ Fast (no subprocess spawn)
- ✅ Full control over client behavior
- ✅ Easy to assert on session injection calls
- ✅ Tests real Phoenix WebSocket connection

**Disadvantages:**
- ❌ Requires workaround for `bun:test` module isolation (see below)

**Key caveat:** The existing E2E test uses a dynamic re-import of `phoenix` via absolute file path to bypass `mock.module` leakage from unit tests:

```typescript
// __tests__/e2e.test.ts (lines 108-116)
const phoenixFilePath = new URL(
  "../node_modules/phoenix/priv/static/phoenix.cjs.js",
  import.meta.url
).href;
const realPhoenix = await import(phoenixFilePath);
const RealSocket = (realPhoenix as any).Socket as new (...args: unknown[]) => unknown;

mock.module("phoenix", () => ({ Socket: RealSocket }));
```

**Why this is needed:** `bun:test` runs all test files in the same process. Unit tests (`index.test.ts`, `service.test.ts`) call `mock.module("phoenix", MockSocket)`, which replaces the real Phoenix Socket for **all subsequent imports** in the same test run. The E2E test needs the **real** Socket to connect to the live server, so it imports `phoenix` via its absolute file path (which bypasses `mock.module`'s package-name keying) and then re-registers the real Socket.

**E2E test structure (existing):**

```typescript
// __tests__/e2e.test.ts (simplified)
import { describe, it, expect, beforeAll, afterAll, mock } from "bun:test";

const BASE_URL = "http://localhost:4000";
const SESSION_ID = `e2e-session-${Date.now()}`;

const mockClient = {
  session: {
    prompt: mock(() => Promise.resolve()),
    promptAsync: mock(() => Promise.resolve()),
  },
};

describe("E2E: opencode-plugin-viche against live Viche server", () => {
  let hooks: Hooks;
  let ourAgentId: string;

  beforeAll(async () => {
    // Step 1: Re-pin the REAL Phoenix Socket (workaround for mock.module leakage)
    const phoenixFilePath = new URL("../node_modules/phoenix/priv/static/phoenix.cjs.js", import.meta.url).href;
    const realPhoenix = await import(phoenixFilePath);
    const RealSocket = (realPhoenix as any).Socket;
    mock.module("phoenix", () => ({ Socket: RealSocket }));

    // Step 2: Load the plugin with real Phoenix now in effect
    const { default: vichePlugin } = await import("../index.js");

    // Step 3: Initialize plugin + trigger session.created
    hooks = await vichePlugin({ client: mockClient, directory: "/tmp/e2e-test" });
    await hooks.event({ event: { type: "session.created", properties: { info: { id: SESSION_ID } } } });

    // Step 4: Extract agent ID from identity prompt
    const promptCalls = (mockClient.session.prompt as ReturnType<typeof mock>).mock.calls;
    const text = promptCalls[0][0].body.parts[0].text;
    const match = text.match(/Your agent ID is ([0-9a-f-]+)/);
    ourAgentId = match[1];
  }, 15_000);

  afterAll(() => {
    hooks.event({ event: { type: "session.deleted", properties: { info: { id: SESSION_ID } } } });
  });

  it("Test 1: plugin factory returns { event, tool } with all three tools", async () => {
    expect(hooks).toHaveProperty("event");
    expect(hooks).toHaveProperty("tool");
    expect(hooks.tool).toHaveProperty("viche_discover");
    expect(hooks.tool).toHaveProperty("viche_send");
    expect(hooks.tool).toHaveProperty("viche_reply");
  });

  it("Test 2: registered agent appears in discovery results", async () => {
    const tool = hooks.tool["viche_discover"];
    const result = await tool.execute({ capability: "*" }, { sessionID: SESSION_ID });
    expect(result).toContain(ourAgentId);
  });

  it("Test 3: viche_send delivers a message to an external agent's inbox", async () => {
    // Register external agent via HTTP
    const resp = await fetch(`${BASE_URL}/registry/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ capabilities: ["e2e-test-target"] }),
    });
    const { id: externalId } = await resp.json();

    // Send message via tool
    const sendTool = hooks.tool["viche_send"];
    await sendTool.execute({ to: externalId, body: "hello from e2e", type: "task" }, { sessionID: SESSION_ID });

    // Verify delivery via HTTP inbox read
    const inboxResp = await fetch(`${BASE_URL}/inbox/${externalId}`);
    const { messages } = await inboxResp.json();
    expect(messages[0].from).toBe(ourAgentId);
    expect(messages[0].body).toBe("hello from e2e");
  });

  it("Test 4: inbound message is pushed over WebSocket and triggers client.session.promptAsync", async () => {
    (mockClient.session.promptAsync as ReturnType<typeof mock>).mockClear();

    // Register sender agent
    const senderResp = await fetch(`${BASE_URL}/registry/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ capabilities: ["e2e-test-sender"] }),
    });
    const { id: senderId } = await senderResp.json();

    // POST message to our agent
    await fetch(`${BASE_URL}/messages/${ourAgentId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ from: senderId, type: "task", body: "e2e websocket delivery test" }),
    });

    // Wait for WebSocket push
    await new Promise(resolve => setTimeout(resolve, 1000));

    const asyncCalls = (mockClient.session.promptAsync as ReturnType<typeof mock>).mock.calls;
    expect(asyncCalls.length).toBeGreaterThan(0);
    const text = asyncCalls[0][0].body.parts[0].text;
    expect(text).toContain(`[Viche Task from ${senderId}]`);
    expect(text).toContain("e2e websocket delivery test");
  });

  it("Test 5: session.deleted disconnects WebSocket and agent is eventually deregistered", async () => {
    await hooks.event({ event: { type: "session.deleted", properties: { info: { id: SESSION_ID } } } });

    // Wait for grace period (5s) + buffer
    await new Promise(resolve => setTimeout(resolve, 6000));

    // Agent should no longer appear in discovery
    const resp = await fetch(`${BASE_URL}/registry/discover?capability=*`);
    const { agents } = await resp.json();
    const found = agents.some((a: { id: string }) => a.id === ourAgentId);
    expect(found).toBe(false);
  }, 15_000);
});
```

**Existing test coverage:**
- ✅ Plugin factory shape
- ✅ Registration + discovery
- ✅ viche_send → inbox delivery
- ✅ Inbound WebSocket push → promptAsync
- ✅ Session cleanup → deregistration

**Missing test coverage (opportunities for expansion):**
- ❌ `viche_reply` tool (type: "result")
- ❌ Multi-registry join/leave
- ❌ Error recovery (channel error, reconnection)
- ❌ Concurrent sessions (multiple session.created events)
- ❌ Config validation (invalid registry URL, missing capabilities)

**Recommendation:** Extend existing `e2e.test.ts` with additional scenarios:

```typescript
it("Test 6: viche_reply sends a result message", async () => {
  // Register external agent
  const resp = await fetch(`${BASE_URL}/registry/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ capabilities: ["e2e-test-requester"] }),
  });
  const { id: requesterId } = await resp.json();

  // Send reply via tool
  const replyTool = hooks.tool["viche_reply"];
  await replyTool.execute({ to: requesterId, body: "task completed" }, { sessionID: SESSION_ID });

  // Verify delivery
  const inboxResp = await fetch(`${BASE_URL}/inbox/${requesterId}`);
  const { messages } = await inboxResp.json();
  expect(messages[0].type).toBe("result");
  expect(messages[0].body).toBe("task completed");
});

it("Test 7: concurrent sessions each get their own agent ID", async () => {
  const session2Id = `e2e-session-2-${Date.now()}`;
  const client2 = {
    session: {
      prompt: mock(() => Promise.resolve()),
      promptAsync: mock(() => Promise.resolve()),
    },
  };

  const { default: vichePlugin } = await import("../index.js");
  const hooks2 = await vichePlugin({ client: client2, directory: "/tmp/e2e-test-2" });
  await hooks2.event({ event: { type: "session.created", properties: { info: { id: session2Id } } } });

  const promptCalls = (client2.session.prompt as ReturnType<typeof mock>).mock.calls;
  const text = promptCalls[0][0].body.parts[0].text;
  const match = text.match(/Your agent ID is ([0-9a-f-]+)/);
  const agent2Id = match[1];

  expect(agent2Id).not.toBe(ourAgentId);

  // Cleanup
  await hooks2.event({ event: { type: "session.deleted", properties: { info: { id: session2Id } } } });
});
```

---

### 4.3 OpenClaw Plugin (`channel/openclaw-plugin-viche/`)

#### Approach A: Mock API + Real Phoenix Server (Recommended)

**Concept:** Create a mock `api` object with `registerTool()` that captures tool factories. Call `registerVicheTools(mockApi, config, state)` to register tools. Call `createVicheService(config, state, mockRuntime, {})` and `service.start({ logger })` to connect to real Phoenix server.

**Advantages:**
- ✅ Pattern proven in existing unit tests (`tools-websocket.test.ts`, `channel-error-recovery.test.ts`)
- ✅ Fast (no subprocess spawn)
- ✅ Full control over runtime behavior
- ✅ Tests real Phoenix WebSocket connection
- ✅ Easy to assert on `runtime.subagent.run()` calls

**Disadvantages:**
- ❌ Requires manual mock setup (not as clean as OpenCode's direct import)

**E2E test example:**

```typescript
// __tests__/e2e.test.ts
import { describe, it, expect, beforeAll, afterAll, mock } from "bun:test";
import { createVicheService } from "../service.js";
import { registerVicheTools } from "../tools.js";

const BASE_URL = "http://localhost:4000";

type ToolFactory = (ctx: { sessionKey?: string }) => {
  name: string;
  execute: (toolCallId: string, params: Record<string, unknown>) => Promise<{ content: Array<{ type: string; text: string }> }>;
};

function createApi() {
  const factories: ToolFactory[] = [];
  return {
    factories,
    registerTool(factory: ToolFactory) {
      factories.push(factory);
    },
  };
}

function getTool(api: ReturnType<typeof createApi>, name: string, sessionKey = "e2e-session") {
  const factory = api.factories.find((f) => f({ sessionKey }).name === name);
  if (!factory) throw new Error(`Missing tool ${name}`);
  return factory({ sessionKey });
}

describe("E2E: openclaw-plugin-viche against live Viche server", () => {
  let api: ReturnType<typeof createApi>;
  let state: {
    agentId: string | null;
    channel: unknown;
    correlations: Map<string, { sessionKey: string; timestamp: number }>;
    mostRecentSessionKey: string | null;
  };
  let runtime: { subagent: { run: ReturnType<typeof mock> } };
  let service: { start: (opts: { logger: unknown }) => Promise<void>; stop: (opts: { logger: unknown }) => Promise<void> };
  let logger: { info: ReturnType<typeof mock>; warn: ReturnType<typeof mock>; error: ReturnType<typeof mock> };

  beforeAll(async () => {
    api = createApi();
    state = {
      agentId: null,
      channel: null,
      correlations: new Map(),
      mostRecentSessionKey: null,
    };
    runtime = {
      subagent: {
        run: mock(async () => ({ runId: "test-run" })),
      },
    };
    logger = {
      info: mock(() => {}),
      warn: mock(() => {}),
      error: mock(() => {}),
    };

    const config = {
      registryUrl: BASE_URL,
      capabilities: ["e2e-testing"],
      agentName: "openclaw-e2e",
      description: "OpenClaw E2E test agent",
    };

    registerVicheTools(api as any, config as any, state as any);
    service = createVicheService(config as any, state as any, runtime as any, {});
    await service.start({ logger } as any);

    // Wait for registration to complete
    await new Promise(resolve => setTimeout(resolve, 2000));
  }, 15_000);

  afterAll(async () => {
    await service.stop({ logger } as any);
  });

  it("Test 1: service assigns an agent ID on start", () => {
    expect(state.agentId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  });

  it("Test 2: viche_discover finds the registered agent", async () => {
    const tool = getTool(api, "viche_discover");
    const result = await tool.execute("call-1", { capability: "*" });

    expect(result.content[0].text).toContain("Found");
    expect(result.content[0].text).toContain(state.agentId!);
  });

  it("Test 3: viche_send delivers a message to an external agent's inbox", async () => {
    // Register external agent via HTTP
    const resp = await fetch(`${BASE_URL}/registry/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ capabilities: ["e2e-test-target"] }),
    });
    const { id: externalId } = await resp.json();

    // Send message via tool
    const sendTool = getTool(api, "viche_send");
    await sendTool.execute("call-2", { to: externalId, body: "hello from openclaw e2e", type: "task" });

    // Verify delivery via HTTP inbox read
    const inboxResp = await fetch(`${BASE_URL}/inbox/${externalId}`);
    const { messages } = await inboxResp.json();

    expect(messages).toHaveLength(1);
    expect(messages[0].from).toBe(state.agentId);
    expect(messages[0].body).toBe("hello from openclaw e2e");
  });

  it("Test 4: inbound message is pushed over WebSocket and triggers runtime.subagent.run", async () => {
    runtime.subagent.run.mockClear();

    // Register sender agent
    const senderResp = await fetch(`${BASE_URL}/registry/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ capabilities: ["e2e-test-sender"] }),
    });
    const { id: senderId } = await senderResp.json();

    // POST message to our agent
    await fetch(`${BASE_URL}/messages/${state.agentId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        from: senderId,
        type: "task",
        body: "e2e websocket delivery test",
      }),
    });

    // Wait for WebSocket push
    await new Promise(resolve => setTimeout(resolve, 1000));

    expect(runtime.subagent.run.mock.calls.length).toBeGreaterThan(0);
    const call = runtime.subagent.run.mock.calls[0] as [{ prompt: string }];
    expect(call[0].prompt).toContain(`[Viche Task from ${senderId}]`);
    expect(call[0].prompt).toContain("e2e websocket delivery test");
  });

  it("Test 5: service.stop disconnects and agent is eventually deregistered", async () => {
    await service.stop({ logger } as any);

    // Wait for grace period (5s) + buffer
    await new Promise(resolve => setTimeout(resolve, 6000));

    // Agent should no longer appear in discovery
    const resp = await fetch(`${BASE_URL}/registry/discover?capability=*`);
    const { agents } = await resp.json();
    const found = agents.some((a: { id: string }) => a.id === state.agentId);
    expect(found).toBe(false);
  }, 15_000);
});
```

**Implementation checklist:**
- [ ] Create `__tests__/e2e.test.ts`
- [ ] Add mock API factory helper
- [ ] Add test scenarios: registration, discovery, send, inbound delivery, cleanup
- [ ] Add `test:e2e` script to `package.json`
- [ ] Update CI to run E2E tests

---

#### Approach B: Use `openclaw/plugin-sdk/testing` Utilities

**Concept:** The OpenClaw SDK exports a `testing` subpath with rich test utilities:
- `buildDispatchInboundCaptureMock()` — captures inbound message context
- `primeChannelOutboundSendMock()` — primes mock sends
- `createCliRuntimeCapture()` — captures runtime calls
- `createSandboxTestContext()` — isolated test env

**Advantages:**
- ✅ Official SDK utilities designed for plugin testing
- ✅ More realistic mocks (closer to production behavior)
- ✅ Can test complex scenarios (multi-session, correlation)

**Disadvantages:**
- ❌ Requires learning SDK testing API
- ❌ May not support real Phoenix server connection (needs investigation)
- ❌ Less control over mock behavior

**E2E test example (hypothetical):**

```typescript
// __tests__/e2e-sdk.test.ts
import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { createSandboxTestContext } from "openclaw/plugin-sdk/testing";
import vichePlugin from "../index.js";

const BASE_URL = "http://localhost:4000";

describe("E2E: openclaw-plugin-viche with SDK testing utilities", () => {
  let context: ReturnType<typeof createSandboxTestContext>;

  beforeAll(async () => {
    context = createSandboxTestContext({
      plugins: [vichePlugin],
      config: {
        plugins: {
          viche: {
            config: {
              registryUrl: BASE_URL,
              capabilities: ["e2e-testing"],
              agentName: "openclaw-e2e-sdk",
            },
          },
        },
      },
    });

    await context.start();
  }, 15_000);

  afterAll(async () => {
    await context.stop();
  });

  it("viche_discover tool is registered", () => {
    const tools = context.getTools();
    expect(tools.map(t => t.name)).toContain("viche_discover");
  });

  it("viche_discover finds agents", async () => {
    const result = await context.callTool("viche_discover", { capability: "*" });
    expect(result.content[0].text).toContain("Found");
  });
});
```

**Recommendation:** Start with **Approach A** (simpler, proven pattern from existing unit tests). Adopt SDK testing utilities for more complex scenarios if needed.

---

## Section 5: Shared Infrastructure — Phoenix Server for E2E

All three plugins need a **running Phoenix server** for E2E tests. This section documents how to start, verify, and interact with the server.

### Starting the Server

**Development:**
```bash
# Start server in foreground (logs to stdout)
mix phx.server

# OR start server in IEx shell (for debugging)
iex -S mix phx.server
```

**CI/Background:**
```bash
# Start server in background
mix phx.server &
SERVER_PID=$!

# Wait for server to be ready
until curl -sf http://localhost:4000/health; do
  echo "Waiting for Phoenix server..."
  sleep 1
done

echo "Phoenix server ready (PID: $SERVER_PID)"
```

### Health Check

**Endpoint:** `GET /health`

**Expected response:**
```json
{
  "status": "ok"
}
```

**Example:**
```bash
curl -s http://localhost:4000/health | jq
# Output: { "status": "ok" }
```

### Verification After Plugin Registers

**Endpoint:** `GET /registry/discover?capability=*`

**Expected response:**
```json
{
  "agents": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "my-agent",
      "capabilities": ["coding", "refactoring"],
      "description": "AI coding assistant"
    }
  ]
}
```

**Example:**
```bash
# Discover all agents
curl -s "http://localhost:4000/registry/discover?capability=*" | jq

# Discover agents with specific capability
curl -s "http://localhost:4000/registry/discover?capability=coding" | jq
```

### Sending Inbound Test Messages

**Endpoint:** `POST /messages/:agent_id`

**Request body:**
```json
{
  "from": "test-harness",
  "body": "hello from test",
  "type": "task"
}
```

**Expected response:**
```json
{
  "message_id": "msg-550e8400-e29b-41d4-a716-446655440000"
}
```

**Example:**
```bash
AGENT_ID="550e8400-e29b-41d4-a716-446655440000"

curl -s "http://localhost:4000/messages/${AGENT_ID}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"from":"test-harness","body":"hello from test","type":"task"}' \
  | jq
```

**What happens:**
1. Server receives POST request
2. Server looks up agent in `Viche.AgentRegistry`
3. Server appends message to agent's inbox (in-memory GenServer state)
4. Server broadcasts `new_message` event to `agent:{agent_id}` Phoenix Channel
5. Plugin receives WebSocket push and injects message into session

### Reading Inbox (Fallback)

**Endpoint:** `GET /inbox/:agent_id`

**Expected response:**
```json
{
  "messages": [
    {
      "id": "msg-550e8400-e29b-41d4-a716-446655440000",
      "type": "task",
      "from": "test-harness",
      "body": "hello from test",
      "sent_at": "2026-04-07T12:34:56.789Z"
    }
  ]
}
```

**Example:**
```bash
AGENT_ID="550e8400-e29b-41d4-a716-446655440000"

curl -s "http://localhost:4000/inbox/${AGENT_ID}" | jq
```

**Note:** This endpoint **consumes** messages (they are removed from the inbox after reading). Use this for verification in tests, but be aware that it drains the inbox.

### CI Consideration

E2E tests require a running Phoenix server. Here's a complete CI script pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Start Phoenix server in background
echo "Starting Phoenix server..."
mix phx.server &
SERVER_PID=$!

# Ensure server is killed on script exit
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

echo "Phoenix server ready!"

# Run plugin E2E tests
echo "Running OpenCode E2E tests..."
cd channel/opencode-plugin-viche
bun test __tests__/e2e.test.ts

echo "Running OpenClaw E2E tests..."
cd ../openclaw-plugin-viche
bun test __tests__/e2e.test.ts

echo "Running Claude Code E2E tests..."
cd ../claude-code-plugin-viche
bun test __tests__/e2e.test.ts

echo "All E2E tests passed!"
```

**GitHub Actions example:**

```yaml
# .github/workflows/e2e.yml
name: E2E Tests

on: [push, pull_request]

jobs:
  e2e:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.19.2'
          otp-version: '27.0'
      
      - name: Set up Bun
        uses: oven-sh/setup-bun@v1
        with:
          bun-version: latest
      
      - name: Install Elixir dependencies
        run: mix deps.get
      
      - name: Install plugin dependencies
        run: |
          cd channel/opencode-plugin-viche && bun install
          cd ../openclaw-plugin-viche && bun install
          cd ../claude-code-plugin-viche && bun install
      
      - name: Start Phoenix server
        run: |
          mix phx.server &
          echo "SERVER_PID=$!" >> $GITHUB_ENV
      
      - name: Wait for server
        run: |
          timeout 30 bash -c 'until curl -sf http://localhost:4000/health; do sleep 1; done'
      
      - name: Run E2E tests
        run: |
          cd channel/opencode-plugin-viche && bun run test:e2e
          cd ../openclaw-plugin-viche && bun run test:e2e
          cd ../claude-code-plugin-viche && bun run test:e2e
      
      - name: Stop Phoenix server
        if: always()
        run: kill $SERVER_PID || true
```

---

## Section 6: Test Scenarios Matrix

This matrix defines **what scenarios to test** across all plugins. Use this as a checklist when implementing E2E tests.

| Scenario | Claude Code | OpenCode | OpenClaw | Priority | Notes |
|----------|-------------|----------|----------|----------|-------|
| **Registration (get agent_id)** | ❌ TODO | ✅ Exists | ❌ TODO | **HIGH** | Core flow — must work for any plugin to function |
| **Discovery (find agents)** | ❌ TODO | ✅ Exists | ❌ TODO | **HIGH** | Core tool — used by all multi-agent workflows |
| **Send message (to another agent)** | ❌ TODO | ✅ Exists | ❌ TODO | **HIGH** | Core tool — primary use case for Viche |
| **Reply (type: result)** | ❌ TODO | ❌ TODO | ❌ TODO | **MEDIUM** | Important for request/response patterns |
| **Deregister (partial)** | ❌ TODO | ❌ TODO | ❌ TODO | **MEDIUM** | Leave specific registry, stay in others |
| **Deregister (full)** | ❌ TODO | ❌ TODO | ❌ TODO | **MEDIUM** | Leave all registries (becomes undiscoverable) |
| **Inbound message delivery** | ❌ TODO | ✅ Exists | ❌ TODO | **HIGH** | Critical for async messaging — must verify WebSocket push → session injection |
| **Auto-reconnect on channel error** | ❌ TODO | ❌ TODO | ✅ Exists (unit) | **MEDIUM** | Resilience — verify recovery from `agent_not_found` error |
| **Cleanup on stop/disconnect** | ❌ TODO | ✅ Exists | ❌ TODO | **HIGH** | Resource cleanup — verify agent deregistered after grace period |
| **Multi-registry join** | ❌ TODO | ❌ TODO | ❌ TODO | **LOW** | Advanced feature — join multiple namespaces |
| **Multi-registry leave** | ❌ TODO | ❌ TODO | ❌ TODO | **LOW** | Advanced feature — leave specific namespace |
| **Concurrent sessions (OpenCode only)** | N/A | ❌ TODO | N/A | **MEDIUM** | OpenCode-specific — verify per-session agents |
| **Config validation (invalid URL)** | ❌ TODO | ❌ TODO | ❌ TODO | **LOW** | Error handling — verify graceful failure |
| **Config validation (missing capabilities)** | ❌ TODO | ❌ TODO | ❌ TODO | **LOW** | Error handling — verify default behavior |
| **Message correlation (OpenClaw only)** | N/A | N/A | ❌ TODO | **MEDIUM** | OpenClaw-specific — verify correlation map cleanup |
| **Tool parameter validation** | ❌ TODO | ❌ TODO | ❌ TODO | **LOW** | Already covered by unit tests, but good to verify E2E |

### Scenario Descriptions

#### 1. Registration (get agent_id)
**What:** Plugin connects to Phoenix server, joins `agent:register` channel, receives `{ agent_id }` in join reply.

**How to test:**
1. Start plugin
2. Wait for registration to complete
3. Assert agent ID is a valid UUID
4. Verify agent appears in discovery results

**Success criteria:**
- Agent ID matches UUID v4 format (`/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/`)
- `GET /registry/discover?capability=*` includes the agent

---

#### 2. Discovery (find agents)
**What:** Call `viche_discover` tool with capability filter, receive list of matching agents.

**How to test:**
1. Register plugin (get agent ID)
2. Call `viche_discover` with `capability: "*"`
3. Assert response includes plugin's agent ID
4. Register external agent with specific capability
5. Call `viche_discover` with that capability
6. Assert response includes external agent

**Success criteria:**
- Tool returns formatted text with agent count
- Agent IDs, names, and capabilities are included
- Filtering by capability works correctly

---

#### 3. Send message (to another agent)
**What:** Call `viche_send` tool to send a message to another agent's inbox.

**How to test:**
1. Register plugin (get agent ID)
2. Register external agent via HTTP (get external ID)
3. Call `viche_send` with `{ to: externalId, body: "test", type: "task" }`
4. Read external agent's inbox via `GET /inbox/:agent_id`
5. Assert message was delivered with correct `from`, `body`, `type`

**Success criteria:**
- Tool returns success message with message ID
- Message appears in external agent's inbox
- Message fields match sent values

---

#### 4. Reply (type: result)
**What:** Call `viche_reply` tool to send a result message (type: "result").

**How to test:**
1. Register plugin (get agent ID)
2. Register external agent via HTTP (get external ID)
3. Call `viche_reply` with `{ to: externalId, body: "done" }`
4. Read external agent's inbox via `GET /inbox/:agent_id`
5. Assert message type is "result"

**Success criteria:**
- Tool returns success message
- Message appears in inbox with `type: "result"`

---

#### 5. Deregister (partial)
**What:** Call `viche_deregister` tool with specific registry token to leave that namespace.

**How to test:**
1. Register plugin with multiple registries: `["global", "team-alpha"]`
2. Verify agent appears in both registries via discovery
3. Call `viche_deregister` with `{ registry: "team-alpha" }`
4. Verify agent no longer appears in `team-alpha` registry
5. Verify agent still appears in `global` registry

**Success criteria:**
- Agent removed from specified registry
- Agent remains in other registries

---

#### 6. Deregister (full)
**What:** Call `viche_deregister` tool with no registry param to leave all registries.

**How to test:**
1. Register plugin with multiple registries
2. Call `viche_deregister` with no params
3. Verify agent no longer appears in any registry

**Success criteria:**
- Agent removed from all registries
- Agent becomes undiscoverable

---

#### 7. Inbound message delivery
**What:** Server pushes `new_message` event via Phoenix Channel, plugin injects into session.

**How to test:**
1. Register plugin (get agent ID)
2. Register external agent via HTTP (get sender ID)
3. POST message to plugin's agent ID: `POST /messages/:agent_id`
4. Wait for WebSocket push (1-2 seconds)
5. Assert plugin injected message into session (check mock calls)

**Success criteria:**
- **Claude Code:** `server.notification()` called with `notifications/message`
- **OpenCode:** `client.session.promptAsync()` called with message text
- **OpenClaw:** `runtime.subagent.run()` called with message prompt

---

#### 8. Auto-reconnect on channel error
**What:** Phoenix socket reconnects after disconnect, but agent was deregistered server-side. Channel rejoin returns `agent_not_found`. Plugin must re-register.

**How to test:**
1. Register plugin (get agent ID)
2. Simulate channel error with `{ reason: "agent_not_found" }`
3. Wait for recovery (plugin re-joins `agent:register`)
4. Assert new agent ID assigned
5. Verify old socket/channel disconnected

**Success criteria:**
- Plugin detects error via `channel.onError`
- Plugin re-joins `agent:register` and gets new agent ID
- Old socket/channel cleaned up
- No infinite recovery loop

**Note:** OpenClaw already has unit test for this (`channel-error-recovery.test.ts`). Extend to E2E with real server.

---

#### 9. Cleanup on stop/disconnect
**What:** Plugin disconnects WebSocket, server deregisters agent after grace period (5 seconds).

**How to test:**
1. Register plugin (get agent ID)
2. Trigger cleanup (session.deleted, service.stop, etc.)
3. Wait for grace period + buffer (6 seconds)
4. Verify agent no longer appears in discovery

**Success criteria:**
- Agent removed from discovery after grace period
- WebSocket disconnected cleanly

---

#### 10. Multi-registry join
**What:** Plugin registers with multiple registry tokens, appears in all namespaces.

**How to test:**
1. Register plugin with `registries: ["global", "team-alpha", "team-beta"]`
2. Verify agent appears in all three registries via discovery
3. Verify agent can be discovered by capability in each registry

**Success criteria:**
- Agent appears in all specified registries
- Discovery works in each namespace

---

#### 11. Multi-registry leave
**What:** Plugin leaves specific registry, remains in others.

**How to test:**
1. Register plugin with multiple registries
2. Call `viche_deregister` with specific registry token
3. Verify agent removed from that registry only

**Success criteria:**
- Agent removed from specified registry
- Agent remains in other registries

---

#### 12. Concurrent sessions (OpenCode only)
**What:** Multiple `session.created` events create separate agents with unique IDs.

**How to test:**
1. Trigger `session.created` for session A
2. Trigger `session.created` for session B
3. Assert both sessions have different agent IDs
4. Verify both agents appear in discovery
5. Send message to session A's agent, verify only session A receives it

**Success criteria:**
- Each session gets unique agent ID
- Messages routed to correct session

---

#### 13. Config validation (invalid URL)
**What:** Plugin handles invalid registry URL gracefully.

**How to test:**
1. Configure plugin with invalid URL (e.g., `http://invalid:99999`)
2. Start plugin
3. Assert plugin logs error and does not crash
4. Verify plugin does not register

**Success criteria:**
- Plugin logs error
- Plugin does not crash
- No agent registered

---

#### 14. Config validation (missing capabilities)
**What:** Plugin uses default capabilities if none provided.

**How to test:**
1. Configure plugin with no capabilities
2. Start plugin
3. Verify plugin registers with default capabilities (e.g., `["coding"]`)

**Success criteria:**
- Plugin registers successfully
- Default capabilities applied

---

#### 15. Message correlation (OpenClaw only)
**What:** OpenClaw tracks message IDs in correlation map, routes inbound messages to correct session.

**How to test:**
1. Register plugin
2. Send message from session A
3. Verify correlation map contains message ID → session A mapping
4. Send inbound message with that message ID
5. Verify message routed to session A (not most-recent session)

**Success criteria:**
- Correlation map updated on send
- Inbound message routed to correct session
- Correlation map cleaned up after delivery

---

#### 16. Tool parameter validation
**What:** Tools reject invalid parameters with helpful error messages.

**How to test:**
1. Call `viche_discover` with invalid capability (e.g., number instead of string)
2. Assert tool returns error
3. Call `viche_send` with missing `to` param
4. Assert tool returns error

**Success criteria:**
- Tools validate parameters
- Error messages are helpful

---

## Section 7: Implementation Priority

Rank by **impact** (how critical for production) and **effort** (how much work to implement).

### Priority 1: HIGH Impact, LOW Effort

| Task | Plugin | Effort | Impact | Rationale |
|------|--------|--------|--------|-----------|
| **Extend OpenCode E2E tests** | OpenCode | **LOW** | **HIGH** | E2E infrastructure already exists. Just add missing scenarios (reply, deregister, concurrent sessions). |
| **Create OpenClaw E2E tests** | OpenClaw | **MEDIUM** | **HIGH** | Pattern proven in unit tests. Just wire to real server. Critical for production confidence. |

**Recommendation:** Start here. These give maximum ROI.

---

### Priority 2: HIGH Impact, MEDIUM Effort

| Task | Plugin | Effort | Impact | Rationale |
|------|--------|--------|--------|-----------|
| **Create Claude Code E2E tests (inspector CLI)** | Claude Code | **MEDIUM** | **HIGH** | Zero code changes, but requires subprocess test setup. Good for CI smoke tests. |

**Recommendation:** Implement after Priority 1. Provides basic coverage for Claude Code plugin.

---

### Priority 3: HIGH Impact, HIGH Effort

| Task | Plugin | Effort | Impact | Rationale |
|------|--------|--------|--------|-----------|
| **Refactor Claude Code for InMemoryTransport** | Claude Code | **HIGH** | **HIGH** | Requires extracting `createVicheServer()` factory from monolithic file. Enables comprehensive E2E testing. |

**Recommendation:** Invest after Priority 1 and 2 are complete. This is the long-term solution for Claude Code E2E testing.

---

### Priority 4: MEDIUM Impact, LOW Effort

| Task | Plugin | Effort | Impact | Rationale |
|------|--------|--------|--------|-----------|
| **Add CI E2E workflow** | All | **LOW** | **MEDIUM** | Automate E2E tests in GitHub Actions. Prevents regressions. |

**Recommendation:** Implement after Priority 1. Ensures E2E tests run on every PR.

---

### Priority 5: LOW Impact, MEDIUM Effort

| Task | Plugin | Effort | Impact | Rationale |
|------|--------|--------|--------|-----------|
| **Add multi-registry E2E tests** | All | **MEDIUM** | **LOW** | Advanced feature, not critical for basic functionality. |
| **Add config validation E2E tests** | All | **MEDIUM** | **LOW** | Error handling, not critical for happy path. |

**Recommendation:** Implement if time permits. Not critical for initial E2E coverage.

---

### Implementation Roadmap

**Week 1:**
- [ ] Extend OpenCode E2E tests with reply, deregister, concurrent sessions
- [ ] Create OpenClaw E2E tests (registration, discovery, send, inbound delivery, cleanup)

**Week 2:**
- [ ] Create Claude Code E2E tests via inspector CLI (tool listing, discovery, send)
- [ ] Add CI E2E workflow (GitHub Actions)

**Week 3:**
- [ ] Refactor Claude Code for InMemoryTransport
- [ ] Create comprehensive Claude Code E2E tests (all scenarios)

**Week 4:**
- [ ] Add multi-registry E2E tests (all plugins)
- [ ] Add config validation E2E tests (all plugins)

---

## Section 8: Open Questions

### 1. Should we run E2E tests in CI?

**Pros:**
- ✅ Catch integration bugs before merge
- ✅ Prevent regressions
- ✅ Document expected behavior
- ✅ Enable confident refactoring

**Cons:**
- ❌ Requires Phoenix server setup in CI (adds complexity)
- ❌ Slower than unit tests (adds ~30s to CI runtime)
- ❌ Potential flakiness (WebSocket timing, server startup)

**Recommendation:** **YES**, run E2E tests in CI. The benefits outweigh the costs. Use the CI script pattern from Section 5 to ensure reliable server startup.

---

### 2. Should we use `mix test` to orchestrate plugin E2E tests, or keep them as separate npm/bun scripts?

**Option A: Separate npm/bun scripts**
- Each plugin has its own `test:e2e` script
- CI runs each script separately
- Simpler, more isolated

**Option B: Orchestrate via `mix test`**
- Create Elixir test file that spawns plugin E2E tests
- Single `mix test` command runs everything
- More integrated, but more complex

**Recommendation:** **Option A** (separate scripts). Keep plugin tests isolated. Use a shell script or GitHub Actions workflow to orchestrate.

---

### 3. For Claude Code: is `InMemoryTransport` refactoring worth the investment, or is subprocess testing sufficient?

**InMemoryTransport (Approach A):**
- ✅ Fast, comprehensive, full control
- ❌ Requires refactoring (HIGH effort)

**Subprocess (Approach B/C):**
- ✅ Zero code changes (LOW effort)
- ❌ Slower, limited assertions

**Recommendation:** **Start with subprocess** (Approach B) for immediate CI coverage. **Invest in InMemoryTransport** (Approach A) for long-term comprehensive testing. The refactoring is worth it for a production-critical plugin.

---

### 4. Should we create a shared test harness (e.g., a Bun script that starts Phoenix, runs all plugin E2E tests, and tears down)?

**Pros:**
- ✅ Single command to run all E2E tests
- ✅ Ensures server is started/stopped correctly
- ✅ Easier for developers to run locally

**Cons:**
- ❌ Adds another layer of abstraction
- ❌ May hide plugin-specific failures

**Recommendation:** **YES**, create a shared harness for local development. Example:

```bash
#!/usr/bin/env bash
# scripts/run-e2e-tests.sh
set -euo pipefail

echo "Starting Phoenix server..."
mix phx.server &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null || true" EXIT

echo "Waiting for server..."
until curl -sf http://localhost:4000/health >/dev/null 2>&1; do sleep 1; done

echo "Running OpenCode E2E tests..."
(cd channel/opencode-plugin-viche && bun run test:e2e)

echo "Running OpenClaw E2E tests..."
(cd channel/openclaw-plugin-viche && bun run test:e2e)

echo "Running Claude Code E2E tests..."
(cd channel/claude-code-plugin-viche && bun run test:e2e)

echo "All E2E tests passed!"
```

Usage:
```bash
./scripts/run-e2e-tests.sh
```

---

### 5. How do we handle test isolation (agents from previous tests still registered)?

**Problem:** E2E tests register agents that persist until grace period expires. Subsequent tests may see stale agents in discovery.

**Solutions:**

**Option A: Unique capabilities per test**
- Each test uses a unique capability (e.g., `e2e-test-${Date.now()}`)
- Discovery filters by capability, so stale agents don't interfere

**Option B: Cleanup in afterAll**
- Each test explicitly deregisters its agent in `afterAll`
- Requires waiting for grace period (5s) — slows down tests

**Option C: Increase grace period tolerance**
- Accept that stale agents may appear in discovery
- Filter by agent ID or capability to avoid false positives

**Recommendation:** **Option A** (unique capabilities). This is the approach used in OpenCode's existing E2E test (`e2e-test-target`, `e2e-test-sender`). It's fast and reliable.

---

### 6. Should we test against a real PostgreSQL database, or is in-memory state sufficient?

**Current state:** Viche uses **in-memory state only** (GenServer processes). PostgreSQL is configured but unused.

**Recommendation:** **In-memory state is sufficient** for E2E tests. No need to set up PostgreSQL unless we add persistence in the future.

---

### 7. How do we test WebSocket reconnection in E2E (without mocking)?

**Problem:** Reconnection logic is hard to test E2E because it requires simulating network failures.

**Solutions:**

**Option A: Keep reconnection tests as unit tests**
- OpenClaw already has `channel-error-recovery.test.ts` (unit test with mocked socket)
- This is sufficient for most scenarios

**Option B: Add E2E reconnection test with server restart**
- Start Phoenix server
- Register plugin
- Kill Phoenix server
- Restart Phoenix server
- Verify plugin reconnects and re-registers
- **HIGH effort**, **MEDIUM value**

**Recommendation:** **Option A** (unit tests). Reconnection logic is well-covered by unit tests. E2E reconnection testing is not worth the effort.

---

## Conclusion

This guide provides a comprehensive roadmap for implementing E2E tests across all three Viche plugins. Key takeaways:

1. **OpenCode plugin** already has excellent E2E coverage — extend it with missing scenarios
2. **OpenClaw plugin** has strong unit tests — create E2E tests using the same patterns
3. **Claude Code plugin** has zero tests — start with subprocess testing (inspector CLI), then invest in InMemoryTransport refactoring
4. **Shared infrastructure** (Phoenix server, CI workflow) is critical for reliable E2E testing
5. **Test scenarios matrix** provides a clear checklist for comprehensive coverage
6. **Implementation priority** focuses on high-impact, low-effort tasks first

**Next steps:**
1. Extend OpenCode E2E tests (Priority 1)
2. Create OpenClaw E2E tests (Priority 1)
3. Create Claude Code E2E tests via inspector CLI (Priority 2)
4. Add CI E2E workflow (Priority 4)
5. Refactor Claude Code for InMemoryTransport (Priority 3)

With this guide, any developer should be able to start implementing E2E tests immediately. The patterns are proven, the infrastructure is documented, and the roadmap is clear.

---

**Document Status:** ✅ Complete  
**Last Updated:** 2026-04-07  
**Author:** AI Technical Writer  
**Review Status:** Ready for implementation
