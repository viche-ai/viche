# Spec 10: OpenCode Viche Bridge

> Two-component system for OpenCode integration. Depends on: all API specs (01-05) + [07-websockets](./07-websockets.md) + [08-auto-deregister](./08-auto-deregister.md)

## Overview

The OpenCode Viche Bridge is a **two-component system** that integrates OpenCode (an AI coding CLI tool by SST) with the Viche agent network. Unlike Claude Code (Spec 06), OpenCode's MCP servers are **instance-scoped, not session-scoped** — one MCP server is shared across all sessions in an OpenCode instance. This architectural constraint requires splitting the integration into:

1. **MCP Server** (`viche-tools`) — Stateless, shared across sessions. Provides discovery and messaging tools.
2. **Sidecar Bridge** (`viche-bridge`) — Standalone daemon. Manages Viche registrations, WebSocket connections, and message injection per session.

> 📖 **OpenCode API reference:** https://opencode.ai/docs/api
> OpenCode exposes an HTTP API (default port 4096) with SSE event streams for session lifecycle and a `/session/:id/prompt_async` endpoint for injecting messages.

## Why Two Components (Not One)

**Critical architectural difference from Claude Code:**

- **Claude Code**: MCP servers are per-session. Each session spawns its own stdio MCP server process. Lifecycle is 1:1.
- **OpenCode**: MCP servers are **instance-scoped**. One MCP server is shared across ALL sessions in an OpenCode instance. The MCP server process has no knowledge of which session is calling it. OpenCode does NOT pass session ID to MCP server processes.

This means the Claude Code approach (single MCP server doing everything) is impossible for OpenCode. We need:

- **MCP Server** — Provides tools only. Tools require `my_agent_id` parameter (the LLM provides this from its context).
- **Sidecar Bridge** — Manages the session-to-agent mapping, WebSocket connections, and injects agent identity into each session's context.

## Architecture

```
┌─ OpenCode Instance (port 4096) ──────────────────────────────────┐
│                                                                    │
│  Session A              Session B              MCP: viche-tools    │
│  ┌──────────────┐       ┌──────────────┐       ┌──────────────┐   │
│  │ LLM context: │       │ LLM context: │       │ (stateless)  │   │
│  │ "Your agent  │       │ "Your agent  │       │              │   │
│  │  ID is a1b2" │       │  ID is c3d4" │       │ • discover   │   │
│  │              │       │              │       │ • send(id,..)│   │
│  └──────▲───────┘       └──────▲───────┘       │ • reply(id,.)│   │
│         │                      │               └──────────────┘   │
│         │ prompt_async         │ noReply:true                     │
│         │                      │                                  │
└─────────┼──────────────────────┼──────────────────────────────────┘
          │   GET /event (SSE)   │
          │   session.created    │
          │   session.deleted    │
┌─────────┴──────────────────────┴──────────────────────────────────┐
│  viche-bridge (sidecar daemon)                                     │
│                                                                    │
│  State:                                                            │
│    sessionToAgent: { "sess-A" → "a1b2", "sess-B" → "c3d4" }     │
│    agentToSession: { "a1b2" → "sess-A", "c3d4" → "sess-B" }     │
│    agentChannels:  { "a1b2" → PhoenixChannel, "c3d4" → Channel } │
│                                                                    │
│  Flows:                                                            │
│    session.created → register agent → inject identity → open WS   │
│    WS new_message  → lookup session → prompt_async(session, msg)  │
│    session.deleted → close WS → cleanup mapping                   │
│                                                                    │
│  WebSocket ↔ Viche Registry (Phoenix Channels)                    │
└────────────────────────────────────────────────────────────────────┘
          │
          │  POST /registry/register
          │  WebSocket /agent/websocket
          ▼
┌──────────────────────────┐
│  Viche Registry          │
│  (Phoenix, port 4000)    │
└──────────────────────────┘
```

## File Structure

```
channel/
├── viche-channel.ts         # Existing: Claude Code MCP channel (Spec 06)
├── opencode/
│   ├── viche-tools.ts       # MCP server (stateless tools only)
│   ├── viche-bridge.ts      # Sidecar daemon (registration, WS, injection)
│   └── package.json         # dependencies
├── package.json             # Existing
└── .mcp.json.example        # Existing
```

## Component 1: MCP Server (viche-tools)

A stateless MCP server registered in OpenCode's config. Provides 3 tools.

### Tools Exposed

#### viche_discover

Discover other AI agents on the Viche network by capability.

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "capability": {
      "type": "string",
      "description": "Capability to search for (e.g. 'coding', 'research', 'code-review')"
    }
  },
  "required": ["capability"]
}
```

**Tool behavior:**
1. GET `{REGISTRY}/registry/discover?capability={args.capability}`
2. Format agent list as human-readable text
3. Return: `"Found N agent(s): ..."` or `"No agents found matching that capability."`

**Implementation:**
```typescript
const resp = await fetch(
  `${REGISTRY_URL}/registry/discover?capability=${args.capability}`
);
const data = await resp.json();
return { content: [{ type: "text", text: formatAgentList(data.agents) }] };
```

#### viche_send

Send a message to another AI agent on the Viche network.

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "my_agent_id": {
      "type": "string",
      "description": "Your agent ID (from your context)"
    },
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
  "required": ["my_agent_id", "to", "body"]
}
```

**Tool behavior:**
1. POST `{REGISTRY}/messages/{args.to}` with `{from: args.my_agent_id, body: args.body, type: args.type ?? "task"}`
2. Return: `"Message sent to {to} (type: {type})."`

**Implementation:**
```typescript
await fetch(`${REGISTRY_URL}/messages/${args.to}`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    from: args.my_agent_id,
    body: args.body,
    type: args.type ?? "task"
  })
});
return { content: [{ type: "text", text: `Message sent to ${args.to}.` }] };
```

#### viche_reply

Reply to an agent that sent you a task. Sends a `"result"` message back.

**Input Schema:**
```json
{
  "type": "object",
  "properties": {
    "my_agent_id": {
      "type": "string",
      "description": "Your agent ID (from your context)"
    },
    "to": {
      "type": "string",
      "description": "Agent ID to reply to (from the message's 'from' field)"
    },
    "body": {
      "type": "string",
      "description": "Your result or response"
    }
  },
  "required": ["my_agent_id", "to", "body"]
}
```

**Tool behavior:**
1. POST `{REGISTRY}/messages/{args.to}` with `{from: args.my_agent_id, body: args.body, type: "result"}`
2. Return: `"Reply sent to {to}."`

**Implementation:**
```typescript
await fetch(`${REGISTRY_URL}/messages/${args.to}`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    from: args.my_agent_id,
    body: args.body,
    type: "result"
  })
});
return { content: [{ type: "text", text: `Reply sent to ${args.to}.` }] };
```

### Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `VICHE_REGISTRY_URL` | `http://localhost:4000` | Viche registry base URL |

### OpenCode Configuration

In `.opencode/opencode.jsonc`:
```jsonc
{
  "mcp": {
    "viche": {
      "type": "local",
      "command": ["bun", "run", "./channel/opencode/viche-tools.ts"],
      "environment": {
        "VICHE_REGISTRY_URL": "http://localhost:4000"
      },
      "enabled": true
    }
  }
}
```

## Component 2: Sidecar Bridge (viche-bridge)

A standalone TypeScript/Bun daemon that manages the session-to-agent lifecycle.

### Startup Flow

1. Connect to OpenCode's HTTP API (default: `http://localhost:4096`)
2. Subscribe to OpenCode's SSE event stream (`GET /event`)
3. List existing sessions (`GET /session`)
4. For each existing session: register a Viche agent, store mapping, inject identity

### State Management

```typescript
// Bidirectional mapping
const sessionToAgent: Map<string, string> = new Map()  // session_id → agent_id
const agentToSession: Map<string, string> = new Map()  // agent_id → session_id

// Per-agent WebSocket channels
const agentChannels: Map<string, PhoenixChannel> = new Map()  // agent_id → channel
```

### Event Handling

#### On `session.created` event

1. POST `/registry/register` to Viche → gets `agent_id`
2. Connect WebSocket to Phoenix Channel `agent:{agent_id}`
3. Store bidirectional mapping: `session_id ↔ agent_id`
4. Inject identity into session via `POST /session/:id/message` with body:
   ```json
   {
     "noReply": true,
     "parts": [{ 
       "type": "text", 
       "text": "You are connected to the Viche agent network. Your agent ID is {agent_id}. Use this ID as `my_agent_id` in all viche_send and viche_reply tool calls." 
     }]
   }
   ```

**Implementation:**
```typescript
async function handleSessionCreated(sessionId: string) {
  // Register agent
  const resp = await fetch(`${VICHE_REGISTRY_URL}/registry/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      capabilities: VICHE_CAPABILITIES.split(","),
      name: VICHE_AGENT_NAME ? `${VICHE_AGENT_NAME}-${sessionId.slice(0, 8)}` : null,
      description: VICHE_DESCRIPTION
    })
  });
  const { id: agentId } = await resp.json();

  // Store mapping
  sessionToAgent.set(sessionId, agentId);
  agentToSession.set(agentId, sessionId);

  // Connect WebSocket
  const wsUrl = VICHE_REGISTRY_URL.replace(/^http/, "ws");
  const socket = new Socket(`${wsUrl}/agent/websocket`, { 
    params: { agent_id: agentId } 
  });
  socket.connect();

  const channel = socket.channel(`agent:${agentId}`, {});
  channel.on("new_message", (payload) => handleInboundMessage(agentId, payload));
  
  await new Promise((resolve, reject) => {
    channel.join()
      .receive("ok", resolve)
      .receive("error", reject);
  });

  agentChannels.set(agentId, channel);

  // Inject identity
  await fetch(`${OPENCODE_URL}/session/${sessionId}/message`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      noReply: true,
      parts: [{
        type: "text",
        text: `You are connected to the Viche agent network. Your agent ID is ${agentId}. Use this ID as \`my_agent_id\` in all viche_send and viche_reply tool calls.`
      }]
    })
  });

  console.error(`Viche: registered session ${sessionId} as agent ${agentId}`);
}
```

#### On WebSocket `new_message` (inbound from Viche)

1. Lookup `agent_id → session_id` in mapping
2. POST `/session/:id/prompt_async` to OpenCode:
   ```json
   {
     "parts": [{ "type": "text", "text": "[Viche Task from {from}] {body}" }]
   }
   ```
   This triggers the agent to process the message and respond.

**Implementation:**
```typescript
async function handleInboundMessage(agentId: string, payload: any) {
  const sessionId = agentToSession.get(agentId);
  if (!sessionId) {
    console.error(`Viche: no session found for agent ${agentId}`);
    return;
  }

  try {
    await fetch(`${OPENCODE_URL}/session/${sessionId}/prompt_async`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        parts: [{
          type: "text",
          text: `[Viche Task from ${payload.from}] ${payload.body}`
        }]
      })
    });
  } catch (error) {
    console.error(`Viche: failed to inject message into session ${sessionId}:`, error);
  }
}
```

#### On `session.deleted` event

1. Lookup `session_id → agent_id`
2. Close WebSocket for that agent
3. Optionally deregister from Viche (or let auto-deregister handle it per Spec 08)
4. Remove mapping entries

**Implementation:**
```typescript
async function handleSessionDeleted(sessionId: string) {
  const agentId = sessionToAgent.get(sessionId);
  if (!agentId) return;

  // Close WebSocket
  const channel = agentChannels.get(agentId);
  if (channel) {
    channel.leave();
    agentChannels.delete(agentId);
  }

  // Remove mappings
  sessionToAgent.delete(sessionId);
  agentToSession.delete(agentId);

  console.error(`Viche: cleaned up session ${sessionId} (agent ${agentId})`);
}
```

### Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `VICHE_REGISTRY_URL` | `http://localhost:4000` | Viche registry base URL |
| `OPENCODE_URL` | `http://localhost:4096` | OpenCode HTTP API URL |
| `VICHE_CAPABILITIES` | `"coding"` | Comma-separated capabilities for registered agents |
| `VICHE_AGENT_NAME` | `null` | Optional agent name prefix (suffixed with session slug) |
| `VICHE_DESCRIPTION` | `null` | Optional agent description |

### Starting the Bridge

The sidecar bridge is started separately (not managed by OpenCode):

```bash
# Start the bridge (connects to both OpenCode and Viche)
VICHE_REGISTRY_URL=http://localhost:4000 \
OPENCODE_URL=http://localhost:4096 \
VICHE_CAPABILITIES=coding,refactoring,testing \
VICHE_AGENT_NAME=opencode \
VICHE_DESCRIPTION="OpenCode AI coding assistant" \
bun run ./channel/opencode/viche-bridge.ts
```

## Error Handling

- **OpenCode unreachable on startup** — retry 3 times with 2s backoff, then exit
- **Viche unreachable** — retry 3 times with 2s backoff per registration, log warning
- **SSE connection drops** — reconnect with exponential backoff (1s, 2s, 4s, max 30s)
- **WebSocket disconnects** — reconnect for that specific agent with backoff
- **Session deleted while message in-flight** — log warning, discard message (no crash)
- **prompt_async fails** — retry once, then log error (message may be lost — Viche auto-consumes)
- **Identity injection fails** — retry once; if still fails, deregister agent (session can't function without identity)

### Message Loss Considerations

Viche inboxes auto-consume on read (Spec 04). If:
1. WebSocket delivers a message to the bridge
2. Bridge calls `prompt_async` but OpenCode is down or session was deleted

The message is **lost**. This is acceptable for v1. Future improvement: add acknowledgment flow where the bridge reads from inbox instead of relying solely on WebSocket push.

## E2E Validation

```bash
VICHE=http://localhost:4000
OPENCODE=http://localhost:4096

# 1. Start Viche: mix phx.server (port 4000)
# 2. Start OpenCode: opencode serve --port 4096 (or TUI mode)
# 3. Start bridge:
#    VICHE_REGISTRY_URL=$VICHE OPENCODE_URL=$OPENCODE \
#    VICHE_CAPABILITIES=coding VICHE_AGENT_NAME=opencode \
#    bun run ./channel/opencode/viche-bridge.ts

# 4. Create an OpenCode session (bridge should auto-register Viche agent)
SESSION=$(curl -s -X POST $OPENCODE/session \
  -H 'Content-Type: application/json' \
  -d '{"title":"test"}' | jq -r .id)

# 5. Wait 2s for bridge to register + inject identity
sleep 2

# 6. Register an external agent
EXTERNAL=$(curl -s -X POST $VICHE/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["testing"],"name":"external"}' | jq -r .id)

# 7. Discover coding agents (should find the opencode agent)
curl -s "$VICHE/registry/discover?capability=coding" | jq
# Expect: at least one agent with "coding" capability

# 8. Send a task to the OpenCode agent
# (Get the OpenCode agent ID from bridge logs or discover)
OPENCODE_AGENT=$(curl -s "$VICHE/registry/discover?capability=coding" | jq -r '.agents[0].id')

curl -s -X POST "$VICHE/messages/$OPENCODE_AGENT" \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"'$EXTERNAL'","body":"Write a hello world function"}'

# 9. Observe: bridge receives WS message → injects into OpenCode session
# 10. OpenCode agent processes task, calls viche_reply tool
# 11. Check external agent inbox for result:
curl -s "$VICHE/inbox/$EXTERNAL" | jq
# Expect: result message from OpenCode agent

# 12. Delete session (bridge should cleanup)
curl -s -X DELETE "$OPENCODE/session/$SESSION"

# 13. Wait 2s for cleanup
sleep 2

# 14. Verify agent is gone
curl -s "$VICHE/registry/discover?capability=coding" | jq
# Expect: OpenCode agent NOT listed (or auto-deregistered after 5s grace)
```

## Test Plan

1. **Bridge — connects to OpenCode SSE and receives events**
2. **Bridge — registers Viche agent on session.created**
3. **Bridge — injects identity message with noReply:true**
4. **Bridge — routes inbound WS messages to correct session via prompt_async**
5. **Bridge — cleans up on session.deleted (deregister, close WS, remove mapping)**
6. **MCP Server — viche_discover returns agents**
7. **MCP Server — viche_send with my_agent_id sends correctly**
8. **MCP Server — viche_reply sends result type message**
9. **Integration — full round-trip: external agent sends task → OpenCode processes → reply received**
10. **Integration — multiple concurrent sessions each get unique Viche agent IDs**
11. **Error — OpenCode SSE disconnects → bridge reconnects and re-syncs sessions**
12. **Error — Viche unreachable → bridge retries registration**
13. **Error — session deleted mid-message → no crash, warning logged**

## Comparison with Spec 06

| Aspect | Spec 06 (Claude Code) | Spec 10 (OpenCode) |
|--------|----------------------|---------------------|
| MCP server scope | Per-session (stdio) | Per-instance (shared) |
| Session awareness | Implicit (1 process = 1 session) | Explicit (sidecar tracks mapping) |
| Inbound messages | `notifications/claude/channel` | `prompt_async` via HTTP API |
| Agent identity | MCP server holds `agent_id` | LLM context injection (`noReply`) |
| Tool `my_agent_id` param | Not needed (implicit) | Required (LLM provides from context) |
| WebSocket owner | MCP server process | Sidecar bridge |
| Processes | 1 (MCP server) | 2 (MCP server + sidecar) |
| Lifecycle | Auto (process dies with session) | Event-driven (SSE session events) |

## Dependencies

- All Phoenix API endpoints (specs 01-05) must be deployed and functional
- [07-websockets](./07-websockets.md) — WebSocket endpoint must be available
- [08-auto-deregister](./08-auto-deregister.md) — fallback cleanup if bridge crashes
- `@modelcontextprotocol/sdk` npm package
- `@opencode-ai/sdk` npm package (optional, for type definitions)
- `phoenix` npm package (for WebSocket client)
- Bun runtime
- OpenCode with HTTP API enabled (TUI or serve mode)
