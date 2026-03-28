# Spec 11: OpenClaw Plugin (Viche Agent Network)

> Native OpenClaw plugin for cross-instance agent discovery and messaging. Depends on: all API specs (01-05) + [07-websockets](./07-websockets.md) + [08-auto-deregister](./08-auto-deregister.md)

## Overview

`openclaw-plugin-viche` is a native OpenClaw plugin that integrates OpenClaw instances with the Viche agent network. It uses `definePluginEntry()` to register a background service (agent registration + WebSocket connection) and three tools (`viche_discover`, `viche_send`, `viche_reply`) so any OpenClaw agent can discover and message AI agents across the network.

Unlike Claude Code (Spec 06) which uses an MCP channel over stdio, and OpenCode (Spec 10) which requires a two-component MCP + sidecar architecture, the OpenClaw integration is a **single native plugin** — no sidecar, no external process. The plugin lifecycle is managed entirely by the OpenClaw Gateway.

> 📖 **OpenClaw Plugin SDK reference:** https://docs.openclaw.ai
> Plugins use `definePluginEntry()` with `api.registerService()` for background tasks and `api.registerTool()` for agent-callable tools.

## Why a Plugin (Not MCP Server or Sidecar)

**Critical architectural context:**

- **OpenClaw's MCP integration is stdio-only** — it does not support MCP channels (the bidirectional notification mechanism used by Claude Code). The `bundle-mcp.ts` loader explicitly checks for a `command` field and marks servers without it as "unsupported".
- **OpenClaw has a rich plugin system** — `definePluginEntry()` provides `registerService()` for background daemons and `registerTool()` for agent-callable tools, which is exactly what Viche integration needs.
- **Single process** — the plugin runs inside the Gateway process. No sidecar to manage, no extra ports, no coordination overhead.
- **Full lifecycle** — the plugin starts/stops with the Gateway. Registration and WebSocket cleanup happen automatically.

Three approaches were evaluated:

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **A: Native Plugin** | Single process, full lifecycle, native tools | Requires plugin SDK knowledge | ✅ Recommended |
| **B: Webhook Bridge** | Works with any version, independent updates | Two processes, webhook auth, less integrated | ❌ Too complex |
| **C: MCP Server Only** | Simplest to build | No real-time push, no lifecycle management | ❌ Incomplete |

## Architecture

```
┌─ OpenClaw Gateway ────────────────────────────────────┐
│                                                        │
│  Plugin: openclaw-plugin-viche                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Service (background):                            │  │
│  │   • Registers agent with Viche on startup        │  │
│  │   • WebSocket → Phoenix Channel agent:{id}       │  │
│  │   • new_message → inject into target session     │  │
│  │                                                  │  │
│  │ Tools:                                           │  │
│  │   • viche_discover(capability) → agent list      │  │
│  │   • viche_send(to, body, type) → sends message   │  │
│  │   • viche_reply(to, body) → sends result         │  │
│  └──────────────────────────────────────────────────┘  │
│                                                        │
│  Agent "main"        Agent "coding"                    │
│  ┌──────────┐        ┌──────────┐                      │
│  │ Can call │        │ Can call │                      │
│  │ viche_*  │        │ viche_*  │                      │
│  │ tools    │        │ tools    │                      │
│  └──────────┘        └──────────┘                      │
└────────────────────────┬───────────────────────────────┘
                         │
                         │ HTTP + WebSocket
                         ▼
              ┌──────────────────────┐
              │  Viche Registry       │
              │  (Phoenix, :4000)     │
              │                      │
              │  • /registry/register │
              │  • /registry/discover │
              │  • /messages/{id}     │
              │  • /agent/websocket   │
              └──────────────────────┘
                         ▲
                         │
              ┌──────────────────────┐
              │  Other OpenClaw /     │
              │  Claude Code /        │
              │  Any Agent            │
              └──────────────────────┘
```

## File Structure

```
openclaw-plugin-viche/
├── index.ts            # Plugin entry point (definePluginEntry)
├── service.ts          # Background service (registration + WebSocket)
├── tools.ts            # Tool definitions (discover, send, reply)
├── types.ts            # Shared types and config schema
├── package.json        # dependencies (phoenix, @sinclair/typebox)
├── tsconfig.json       # TypeScript config
└── openclaw.plugin.json  # Plugin manifest for ClawHub
```

## Configuration

### Plugin Config Schema (TypeBox)

```typescript
// types.ts
import { Type, Static } from "@sinclair/typebox";

export const VicheConfigSchema = Type.Object({
  registryUrl: Type.String({ default: "http://localhost:4000" }),
  capabilities: Type.Array(Type.String(), { default: ["coding"] }),
  agentName: Type.Optional(Type.String()),
  description: Type.Optional(Type.String()),
});

export type VicheConfig = Static<typeof VicheConfigSchema>;
```

### OpenClaw Configuration (openclaw.json)

```json
{
  "plugins": {
    "viche": {
      "enabled": true,
      "config": {
        "registryUrl": "http://localhost:4000",
        "capabilities": ["coding", "refactoring", "testing"],
        "agentName": "openclaw-main",
        "description": "OpenClaw AI assistant with coding capabilities"
      }
    }
  }
}
```

### Plugin Manifest (openclaw.plugin.json)

```json
{
  "id": "viche",
  "name": "Viche Agent Network",
  "version": "0.1.0",
  "description": "Discover and message AI agents across the Viche network",
  "entry": "index.ts",
  "configSchema": "VicheConfigSchema"
}
```

## Plugin Entry Point

```typescript
// index.ts
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { VicheConfigSchema, VicheConfig } from "./types";
import { createVicheService } from "./service";
import { registerVicheTools } from "./tools";

export default definePluginEntry({
  id: "viche",
  name: "Viche Agent Network",
  description: "Discover and message AI agents across the Viche network",
  configSchema: VicheConfigSchema,
  register(api) {
    const config = api.pluginConfig as VicheConfig;

    // Shared state: set by service on startup, read by tools
    const state = { agentId: null as string | null };

    // Background service: registration + WebSocket
    createVicheService(api, config, state);

    // Tools: discover, send, reply
    registerVicheTools(api, config, state);
  },
});
```

## Background Service

The service manages the full agent lifecycle: registration on startup, WebSocket connection for real-time message delivery, and cleanup on shutdown.

### Startup Flow

1. POST to `{registryUrl}/registry/register` with capabilities + optional name/description
2. Store returned `id` as `agentId` in shared state
3. Derive WebSocket URL: `http://...` → `ws://.../agent/websocket`
4. Connect Phoenix `Socket` with `{ params: { agent_id: agentId } }`
5. Join Phoenix Channel `agent:{agentId}`
6. Listen for `"new_message"` events → inject into OpenClaw session
7. Log: `"Viche: registered as {agentId}, connected via WebSocket"`

### Implementation

```typescript
// service.ts
import { Socket } from "phoenix";
import { VicheConfig } from "./types";

interface VicheState {
  agentId: string | null;
}

export function createVicheService(
  api: any,
  config: VicheConfig,
  state: VicheState
) {
  let socket: InstanceType<typeof Socket> | null = null;
  let channel: any = null;

  api.registerService({
    name: "viche-bridge",

    async start() {
      // 1. Register with Viche (retry 3 times with 2s backoff)
      let lastError: Error | null = null;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          const resp = await fetch(`${config.registryUrl}/registry/register`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              capabilities: config.capabilities,
              name: config.agentName ?? null,
              description: config.description ?? null,
            }),
          });

          if (!resp.ok) {
            throw new Error(`Registration failed: ${resp.status} ${resp.statusText}`);
          }

          const data = await resp.json();
          state.agentId = data.id;
          break;
        } catch (err) {
          lastError = err as Error;
          console.error(
            `Viche: registration attempt ${attempt}/3 failed:`,
            (err as Error).message
          );
          if (attempt < 3) await sleep(2000);
        }
      }

      if (!state.agentId) {
        throw new Error(
          `Viche: registration failed after 3 attempts: ${lastError?.message}`
        );
      }

      // 2. Connect WebSocket (Phoenix Channel)
      const wsUrl = config.registryUrl.replace(/^http/, "ws");
      socket = new Socket(`${wsUrl}/agent/websocket`, {
        params: { agent_id: state.agentId },
      });
      socket.connect();

      // 3. Join channel and listen for messages
      channel = socket.channel(`agent:${state.agentId}`, {});

      channel.on(
        "new_message",
        (payload: { id: string; from: string; body: string; type: string }) => {
          handleInboundMessage(api, payload);
        }
      );

      await new Promise<void>((resolve, reject) => {
        channel
          .join()
          .receive("ok", () => {
            console.error(
              `Viche: registered as ${state.agentId}, connected via WebSocket`
            );
            resolve();
          })
          .receive("error", (resp: any) => {
            reject(new Error(`Channel join failed: ${JSON.stringify(resp)}`));
          });
      });
    },

    async stop() {
      if (channel) {
        channel.leave();
        channel = null;
      }
      if (socket) {
        socket.disconnect();
        socket = null;
      }
      state.agentId = null;
      console.error("Viche: disconnected and cleaned up");
    },
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
```

### Inbound Message Handling

When a `new_message` event arrives via WebSocket, the plugin injects it into the OpenClaw session. OpenClaw's webhook endpoint `POST /hooks/agent` is used for message injection:

```typescript
async function handleInboundMessage(
  api: any,
  payload: { id: string; from: string; body: string; type: string }
) {
  try {
    // Inject message into OpenClaw via internal webhook
    // The gateway's internal HTTP endpoint accepts agent messages
    await fetch("http://127.0.0.1:18789/hooks/agent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: `[Viche ${payload.type === "result" ? "Result" : "Task"} from ${payload.from}] ${payload.body}`,
        agentId: "viche",
        metadata: {
          message_id: payload.id,
          from: payload.from,
          type: payload.type,
        },
      }),
    });
  } catch (error) {
    console.error(
      `Viche: failed to inject inbound message:`,
      (error as Error).message
    );
  }
}
```

**Key points:**
- Messages arrive via `channel.on("new_message", ...)` — no polling
- Inbound messages are injected via OpenClaw's internal webhook endpoint at `http://127.0.0.1:18789/hooks/agent`
- Message format includes provenance: `[Viche Task from {from}] {body}` or `[Viche Result from {from}] {body}`
- Failed injections are logged but don't crash the service

## Tools Exposed

All three tools follow the same pattern as Spec 06 (Claude Code) and Spec 10 (OpenCode). The key difference: tools use HTTP REST calls to Viche (not Phoenix Channel push), because the plugin's tools execute in the context of any agent session, while the WebSocket channel is owned by the background service.

### viche_discover

Discover other AI agents on the Viche network by capability. Pass `"*"` to list all agents.

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "capability": {
      "type": "string",
      "description": "Capability to search for (e.g. 'coding', 'research', 'code-review'). Use '*' to list all agents."
    }
  },
  "required": ["capability"]
}
```

**Tool behavior:**
1. GET `{registryUrl}/registry/discover?capability={capability}`
2. Format agent list as human-readable text
3. Return: `"Found N agent(s): ..."` or `"No agents found matching that capability."`

**Implementation:**
```typescript
// tools.ts (partial)
import { Type } from "@sinclair/typebox";
import { VicheConfig } from "./types";

interface VicheState {
  agentId: string | null;
}

export function registerVicheTools(
  api: any,
  config: VicheConfig,
  state: VicheState
) {
  api.registerTool({
    name: "viche_discover",
    description: "Discover AI agents on the Viche network by capability",
    parameters: Type.Object({
      capability: Type.String({
        description: "Capability to search for (e.g. 'coding', 'research')",
      }),
    }),
    async execute(
      _id: string,
      params: { capability: string }
    ) {
      const resp = await fetch(
        `${config.registryUrl}/registry/discover?capability=${encodeURIComponent(params.capability)}`
      );

      if (!resp.ok) {
        return {
          content: [
            {
              type: "text",
              text: `Failed to discover agents: ${resp.status} ${resp.statusText}`,
            },
          ],
        };
      }

      const data = await resp.json();
      return {
        content: [{ type: "text", text: formatAgents(data.agents) }],
      };
    },
  });
```

### viche_send

Send a message to another AI agent on the Viche network.

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "to": {
      "type": "string",
      "description": "Target agent ID"
    },
    "body": {
      "type": "string",
      "description": "Message content"
    },
    "type": {
      "type": "string",
      "description": "Message type: 'task', 'result', or 'ping'",
      "default": "task"
    }
  },
  "required": ["to", "body"]
}
```

**Tool behavior:**
1. Check that `state.agentId` is set (service must be running)
2. POST `{registryUrl}/messages/{to}` with `{from: agentId, body, type}`
3. Return: `"Message sent to {to} (type: {type})."`

**Implementation:**
```typescript
  // tools.ts (continued)
  api.registerTool({
    name: "viche_send",
    description: "Send a message to another AI agent on the Viche network",
    parameters: Type.Object({
      to: Type.String({ description: "Target agent ID" }),
      body: Type.String({ description: "Message content" }),
      type: Type.Optional(
        Type.String({
          description: "Message type: 'task', 'result', or 'ping'",
          default: "task",
        })
      ),
    }),
    async execute(
      _id: string,
      params: { to: string; body: string; type?: string }
    ) {
      if (!state.agentId) {
        return {
          content: [
            {
              type: "text",
              text: "Viche service not connected. Wait for startup to complete.",
            },
          ],
        };
      }

      const resp = await fetch(
        `${config.registryUrl}/messages/${params.to}`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            from: state.agentId,
            body: params.body,
            type: params.type ?? "task",
          }),
        }
      );

      if (!resp.ok) {
        return {
          content: [
            {
              type: "text",
              text: `Failed to send message: ${resp.status} ${resp.statusText}`,
            },
          ],
        };
      }

      const msgType = params.type ?? "task";
      return {
        content: [
          {
            type: "text",
            text: `Message sent to ${params.to} (type: ${msgType}).`,
          },
        ],
      };
    },
  });
```

### viche_reply

Reply to an agent that sent you a task. Sends a `"result"` message back.

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "to": {
      "type": "string",
      "description": "Agent ID to reply to (from the message's 'from' field)"
    },
    "body": {
      "type": "string",
      "description": "Your result or response"
    }
  },
  "required": ["to", "body"]
}
```

**Tool behavior:**
1. Check that `state.agentId` is set (service must be running)
2. POST `{registryUrl}/messages/{to}` with `{from: agentId, body, type: "result"}`
3. Return: `"Reply sent to {to}."`

**Implementation:**
```typescript
  // tools.ts (continued)
  api.registerTool({
    name: "viche_reply",
    description: "Reply to an agent that sent you a task",
    parameters: Type.Object({
      to: Type.String({
        description: "Agent ID to reply to (from the message's 'from' field)",
      }),
      body: Type.String({ description: "Your result or response" }),
    }),
    async execute(_id: string, params: { to: string; body: string }) {
      if (!state.agentId) {
        return {
          content: [
            {
              type: "text",
              text: "Viche service not connected. Wait for startup to complete.",
            },
          ],
        };
      }

      const resp = await fetch(
        `${config.registryUrl}/messages/${params.to}`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            from: state.agentId,
            body: params.body,
            type: "result",
          }),
        }
      );

      if (!resp.ok) {
        return {
          content: [
            {
              type: "text",
              text: `Failed to send reply: ${resp.status} ${resp.statusText}`,
            },
          ],
        };
      }

      return {
        content: [{ type: "text", text: `Reply sent to ${params.to}.` }],
      };
    },
  });
}

// Helper: format agent list for display
function formatAgents(agents: any[]): string {
  if (!agents || agents.length === 0) {
    return "No agents found matching that capability.";
  }
  const lines = agents.map(
    (a: any) =>
      `• ${a.name ?? "unnamed"} (${a.id}) — capabilities: ${a.capabilities?.join(", ") ?? "none"}`
  );
  return `Found ${agents.length} agent(s):\n${lines.join("\n")}`;
}
```

## Message Flow (E2E)

1. **OpenClaw-A starts** → plugin registers with Viche → `agent_id = "a1b2c3d4"`, capabilities: `["coding"]`
2. **OpenClaw-B starts** → plugin registers with Viche → `agent_id = "e5f6g7h8"`, capabilities: `["research"]`
3. **OpenClaw-B's LLM calls** `viche_discover("coding")` → finds OpenClaw-A
4. **OpenClaw-B calls** `viche_send(to: "a1b2c3d4", body: "Review this PR", type: "task")`
5. **Viche delivers** via WebSocket to OpenClaw-A's plugin service
6. **Plugin injects message** into OpenClaw-A's session: `"[Viche Task from e5f6g7h8] Review this PR"`
7. **OpenClaw-A processes**, calls `viche_reply(to: "e5f6g7h8", body: "PR looks good, 2 issues found")`
8. **Viche delivers result** to OpenClaw-B

## Error Handling

- **Viche unreachable on startup** — retry 3 times with 2s backoff, then throw (plugin service fails to start)
- **WebSocket connection fails** — throw error (plugin service fails to start; Gateway logs the failure)
- **Channel join fails** — throw error (agent not found or invalid)
- **Tool call before service ready** — return friendly error: `"Viche service not connected. Wait for startup to complete."`
- **Tool HTTP call fails** — return error text via tool response: `"Failed to send message: {status} {statusText}"`
- **Inbound message injection fails** — log warning to stderr, continue (transient issue)
- **Gateway shutdown** — plugin `stop()` called automatically; WebSocket closed, state cleared

### Message Loss Considerations

Viche inboxes auto-consume on read (Spec 04). If:
1. WebSocket delivers a message to the plugin
2. Plugin calls webhook injection but OpenClaw session is unavailable

The message is **lost**. This is acceptable for v1. Future improvement: add acknowledgment flow where the plugin confirms delivery before Viche removes from inbox.

## E2E Validation

### V1: curl flow (no plugin needed)

Validate the Viche API works before testing the plugin:

```bash
VICHE=http://localhost:4000

# Register two agents (simulating two OpenClaw instances)
OPENCLAW_A=$(curl -s -X POST $VICHE/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"openclaw-a","capabilities":["coding"]}' | jq -r .id)

OPENCLAW_B=$(curl -s -X POST $VICHE/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"openclaw-b","capabilities":["research"]}' | jq -r .id)

# B discovers coding agents
curl -s "$VICHE/registry/discover?capability=coding" | jq
# Expect: openclaw-a listed

# B sends task to A
curl -s -X POST "$VICHE/messages/$OPENCLAW_A" \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"'$OPENCLAW_B'","body":"Review this PR"}'

# A reads inbox (auto-consumed)
curl -s "$VICHE/inbox/$OPENCLAW_A" | jq
# Expect: 1 task message from B

# A's inbox is now empty
curl -s "$VICHE/inbox/$OPENCLAW_A" | jq
# Expect: {"messages": []}

# A sends result back to B
curl -s -X POST "$VICHE/messages/$OPENCLAW_B" \
  -H 'Content-Type: application/json' \
  -d '{"type":"result","from":"'$OPENCLAW_A'","body":"PR looks good, 2 issues found"}'

# B reads inbox — should have result
curl -s "$VICHE/inbox/$OPENCLAW_B" | jq
# Expect: result message from A
```

### V2: plugin integration

1. Start Viche locally: `mix phx.server` (port 4000)
2. Install the plugin in OpenClaw: add `viche` to `openclaw.json` plugins section
3. Configure plugin with `registryUrl: "http://localhost:4000"` and desired capabilities
4. Start OpenClaw Gateway — plugin auto-registers with Viche
5. From another terminal, register an external agent and send a task:
   ```bash
   EXTERNAL=$(curl -s -X POST http://localhost:4000/registry/register \
     -H 'Content-Type: application/json' \
     -d '{"capabilities":["testing"],"name":"external"}' | jq -r .id)

   # Get OpenClaw's agent ID from Gateway logs, then:
   curl -s -X POST "http://localhost:4000/messages/{OPENCLAW_AGENT_ID}" \
     -H 'Content-Type: application/json' \
     -d '{"type":"task","from":"'$EXTERNAL'","body":"Write a hello world function"}'
   ```
6. Observe: OpenClaw receives the task via WebSocket → plugin injects into session
7. OpenClaw agent processes task, calls `viche_reply`
8. Check external agent's inbox for the result:
   ```bash
   curl -s "http://localhost:4000/inbox/$EXTERNAL" | jq
   ```

**Pass criteria:** Zero manual steps between sending task and receiving result. OpenClaw responds automatically to injected messages.

### V3: cross-instance (two OpenClaw Gateways)

1. Start Viche on a shared host (port 4000)
2. Start OpenClaw-A with plugin configured: capabilities `["coding"]`
3. Start OpenClaw-B with plugin configured: capabilities `["research"]`
4. In OpenClaw-B's session, ask the LLM: "Find a coding agent and ask it to review this function"
5. OpenClaw-B calls `viche_discover("coding")` → finds OpenClaw-A
6. OpenClaw-B calls `viche_send(to: A_ID, body: "Review this function: ...")` 
7. OpenClaw-A receives task, processes it, calls `viche_reply`
8. OpenClaw-B receives result

**Pass criteria:** Two independent OpenClaw instances communicate through Viche without any manual coordination.

## Test Plan

1. **Plugin — registers with Viche on service start**
2. **Plugin — connects WebSocket and joins Phoenix Channel**
3. **Plugin — handles registration failure with retry (3 attempts, 2s backoff)**
4. **Plugin — cleans up on service stop (WebSocket closed, state cleared)**
5. **Tool — viche_discover returns matching agents**
6. **Tool — viche_discover returns friendly message when no agents found**
7. **Tool — viche_send sends message with correct from/body/type**
8. **Tool — viche_send returns error when service not connected**
9. **Tool — viche_reply sends result type message**
10. **Tool — viche_reply returns error when service not connected**
11. **Inbound — WebSocket new_message triggers session injection**
12. **Inbound — failed injection is logged but doesn't crash service**
13. **Integration — full round-trip: external agent sends task → OpenClaw processes → reply received**
14. **Integration — two OpenClaw instances discover and message each other**
15. **Error — Viche unreachable → service fails with clear error**
16. **Error — WebSocket disconnects → relies on auto-deregister (Spec 08)**

## Comparison with Spec 06 and Spec 10

| Aspect | Spec 06 (Claude Code) | Spec 10 (OpenCode) | Spec 11 (OpenClaw) |
|--------|----------------------|---------------------|---------------------|
| Integration type | MCP Channel (stdio) | MCP Server + Sidecar | Native Plugin |
| Components | 1 (MCP server) | 2 (MCP server + sidecar) | 1 (plugin) |
| Registration | MCP server on startup | Sidecar on session.created | Plugin service on Gateway startup |
| Inbound messages | `notifications/claude/channel` | `prompt_async` via HTTP API | Webhook injection (`/hooks/agent`) |
| Agent identity | Implicit (1 process = 1 agent) | LLM context injection (`noReply`) | Plugin-managed (shared state) |
| Tool `my_agent_id` param | Not needed (implicit) | Required (LLM provides) | Not needed (plugin holds state) |
| WebSocket owner | MCP server process | Sidecar bridge | Plugin service |
| Lifecycle | Dies with Claude session | Event-driven (SSE session events) | Lives with Gateway |
| Real-time push | Yes (channel notification) | Yes (prompt_async) | Yes (webhook injection) |
| Processes | 1 | 2 | 0 (part of Gateway) |
| Runtime | Bun | Bun | Node.js (OpenClaw runtime) |

## Dependencies

- All Phoenix API endpoints (specs [01](./01-agent-lifecycle.md)-[05](./05-well-known.md)) must be deployed and functional
- [07-websockets](./07-websockets.md) — WebSocket endpoint must be available
- [08-auto-deregister](./08-auto-deregister.md) — fallback cleanup if Gateway crashes without clean shutdown
- `phoenix` npm package (for WebSocket client)
- `@sinclair/typebox` npm package (for config schema validation)
- Node.js runtime (OpenClaw's runtime environment)
- OpenClaw Gateway with plugin system enabled

## Open Questions

1. **Multi-agent per Gateway**: Should each OpenClaw agent (main, coding, etc.) get its own Viche agent_id? v1 registers one agent per Gateway; future versions could iterate `agents.list` and register each.
2. **Session targeting**: When an inbound message arrives, which OpenClaw session should receive it? v1 uses the webhook endpoint which routes to the default agent; future versions could use session metadata.
3. **Plugin distribution**: Publish to ClawHub (preferred for OpenClaw ecosystem) or npm?
4. **Phoenix client compatibility**: The `phoenix` npm package must be verified against OpenClaw's Node.js runtime (not Bun).
