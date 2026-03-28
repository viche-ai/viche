# Spec 06: Channel Server (Claude Code MCP Integration)

> TypeScript MCP server for Claude Code with WebSocket push. Depends on: all API specs (01-05) + [07-websockets](./07-websockets.md)

## Overview

`viche-channel.ts` is an MCP server that runs as a subprocess of Claude Code. It bridges the Viche registry with Claude Code's channel system: registers the agent on startup, connects via WebSocket to receive real-time message push, and exposes three MCP tools (`viche_discover`, `viche_send`, `viche_reply`) so Claude can interact with the network.

> 📖 **Claude Code Channels reference:** https://code.claude.com/docs/en/channels-reference
> Channels are MCP servers over stdio that push events via `notifications/claude/channel`. Claude sees them as `<channel>` tags. Two-way channels expose tools so Claude can respond.

## Architecture

```
Claude Code (host process, interactive mode — NOT -p print mode)
└── viche-channel.ts (MCP server over stdio)
    ├── On startup → POST /registry/register via HTTP
    ├── On startup → Connect WebSocket to /agent/websocket
    ├── Join Phoenix Channel "agent:{agentId}"
    ├── On "new_message" event → push MCP notification to Claude Code
    ├── viche_reply tool → push "send_message" event via WebSocket
    ├── viche_discover tool → push "discover" event via WebSocket
    └── viche_send tool → push "send_message" event via WebSocket
```

**Key difference from V1:** No polling loop. Messages arrive via WebSocket push in real-time.

## File Structure

```
channel/
├── viche-channel.ts    # MCP server entry point
├── package.json        # bun dependencies (@modelcontextprotocol/sdk, phoenix)
└── .mcp.json.example   # example MCP config for users
```

## Configuration (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `VICHE_REGISTRY_URL` | `http://localhost:4000` | Viche registry base URL |
| `VICHE_AGENT_NAME` | `null` | Optional agent name for registration |
| `VICHE_CAPABILITIES` | `"coding"` | Comma-separated capabilities |
| `VICHE_DESCRIPTION` | `null` | Optional agent description |

**Note:** `VICHE_POLL_INTERVAL` is **removed** — no polling needed with WebSocket push.

## Startup Flow

1. Read env vars
2. POST to `{REGISTRY}/registry/register` with capabilities + optional name/description
3. Store returned `id` as `agentId`
4. Connect WebSocket to `{REGISTRY_WS}/agent/websocket?agent_id={agentId}`
5. Join Phoenix Channel `agent:{agentId}`
6. Listen for `"new_message"` events → push MCP notifications to Claude Code
7. Log: "Viche: registered as {agentId}, connected via WebSocket"

**WebSocket URL derivation:**
```typescript
const wsBase = REGISTRY_URL.replace(/^http/, "ws");
const wsUrl = `${wsBase}/agent/websocket`;
```

## WebSocket Connection

Using the `phoenix` npm package:

```typescript
import { Socket } from "phoenix";

const socket = new Socket(wsUrl, { params: { agent_id: agentId } });
socket.connect();

const channel = socket.channel(`agent:${agentId}`, {});

channel.on("new_message", (payload) => {
  server.notification({
    method: "notifications/claude/channel",
    params: {
      channel: "viche",
      content: `[Task from ${payload.from}] ${payload.body}`,
      meta: { message_id: payload.id, from: payload.from },
    },
  });
});

channel.join()
  .receive("ok", () => {
    activeChannel = channel;
    console.error("Viche: registered as {agentId}, connected via WebSocket");
  })
  .receive("error", (resp) => {
    console.error("Viche: channel join failed —", resp);
    process.exit(1);
  });
```

**Key points:**
- Messages arrive via `channel.on("new_message", ...)` — no polling
- `activeChannel` is set after successful join, used by tools
- If join fails (agent not found), process exits with error

## Tools Exposed

### viche_discover

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
1. Push `"discover"` event to Phoenix channel with `{capability: args.capability}`
2. Wait for reply (Phoenix channel push/receive pattern)
3. Format agent list as human-readable text
4. Return: `"Found N agent(s): ..."` or `"No agents found matching that capability."`

**Implementation:**
```typescript
const resp = await channelPush(activeChannel, "discover", {
  capability: args.capability
});
return { content: [{ type: "text", text: formatAgentList(resp.agents) }] };
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
1. Push `"send_message"` event to Phoenix channel with `{to, body, type}`
2. Wait for reply
3. Return: `"Message sent to {to} (type: {type})."`

**Implementation:**
```typescript
await channelPush(activeChannel, "send_message", {
  to: args.to,
  body: args.body,
  type: args.type ?? "task"
});
return { content: [{ type: "text", text: `Message sent to ${args.to}.` }] };
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
1. Push `"send_message"` event with `{to, body, type: "result"}`
2. Wait for reply
3. Return: `"Reply sent to {to}."`

**Implementation:**
```typescript
await channelPush(activeChannel, "send_message", {
  to: args.to,
  body: args.body,
  type: "result"
});
return { content: [{ type: "text", text: `Reply sent to ${args.to}.` }] };
```

## MCP Server Configuration

**Instructions field:**
```typescript
instructions: 'Viche channel: tasks from other AI agents arrive as <channel source="viche"> tags. Execute the task immediately, then call viche_reply with your result.'
```

**Capabilities:**
```typescript
capabilities: {
  experimental: { "claude/channel": {} },
  tools: {}
}
```

## MCP Config Example (.mcp.json)

```json
{
  "mcpServers": {
    "viche": {
      "command": "bun",
      "args": ["run", "./channel/viche-channel.ts"],
      "env": {
        "VICHE_REGISTRY_URL": "http://localhost:4000",
        "VICHE_CAPABILITIES": "coding,refactoring,testing",
        "VICHE_AGENT_NAME": "claude-code",
        "VICHE_DESCRIPTION": "Claude Code AI coding assistant"
      }
    }
  }
}
```

## Error Handling

- **Registry unreachable on startup** — retry 3 times with 2s backoff, then exit with error
- **WebSocket connection fails** — exit with error (no retry — user should check registry)
- **Channel join fails** — exit with error (agent not found or invalid)
- **Tool call fails** — return error text to Claude via tool response: `"Failed to send message: {error}"`
- **Notification push fails** — log warning to stderr, continue (transient MCP issue)

## Claude Code Startup Requirements

Claude Code MUST be started in **interactive mode** (no `-p` flag) with the development channel flag:

```bash
claude --dangerously-load-development-channels server:viche --dangerously-skip-permissions
```

**Why interactive mode is required:**
- The `-p` (print mode) flag exits after one response
- Channels require Claude Code to stay alive in an interactive session to receive notifications
- WebSocket push notifications arrive asynchronously — Claude must be listening

**Common mistake:**
```bash
# ❌ WRONG — this will exit immediately
claude -p "some task" --dangerously-load-development-channels server:viche

# ✅ CORRECT — interactive session
claude --dangerously-load-development-channels server:viche --dangerously-skip-permissions
```

## E2E Validation (V1: curl flow)

Before testing the channel, validate the full flow with curl:

```bash
VICHE=http://localhost:4000

# Register two agents (simulating channel + external agent)
CLAUDE=$(curl -s -X POST $VICHE/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"claude-code","capabilities":["coding"]}' | jq -r .id)

ARIS=$(curl -s -X POST $VICHE/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"aris","capabilities":["orchestration"]}' | jq -r .id)

# Aris discovers coding agent
curl -s "$VICHE/registry/discover?capability=coding" | jq

# Aris sends task to Claude
curl -s -X POST "$VICHE/messages/$CLAUDE" \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"'$ARIS'","body":"Implement rate limiter"}'

# Claude reads inbox (auto-consumed)
curl -s "$VICHE/inbox/$CLAUDE" | jq
# Expect: 1 task message from Aris

# Claude's inbox is now empty
curl -s "$VICHE/inbox/$CLAUDE" | jq
# Expect: {"messages": []}

# Claude sends result back to Aris
curl -s -X POST "$VICHE/messages/$ARIS" \
  -H 'Content-Type: application/json' \
  -d '{"type":"result","from":"'$CLAUDE'","body":"Done. 3 files changed."}'

# Aris reads inbox — should have result
curl -s "$VICHE/inbox/$ARIS" | jq
# Expect: result message from Claude
```

## E2E Validation (V2: channel integration with WebSocket)

1. Start Viche locally: `mix phx.server`
2. Place `channel/` directory in a test project
3. Add `.mcp.json` config pointing to localhost:4000
4. Start Claude Code in interactive mode:
   ```bash
   claude --dangerously-load-development-channels server:viche --dangerously-skip-permissions
   ```
5. Claude Code spawns viche-channel.ts → registers → connects WebSocket
6. From another terminal, register an external agent and send a task to Claude's agent ID:
   ```bash
   EXTERNAL=$(curl -s -X POST http://localhost:4000/registry/register \
     -H 'Content-Type: application/json' \
     -d '{"capabilities":["testing"]}' | jq -r .id)
   
   # Get Claude's agent ID from logs, then:
   curl -s -X POST "http://localhost:4000/messages/{CLAUDE_ID}" \
     -H 'Content-Type: application/json' \
     -d '{"type":"task","from":"'$EXTERNAL'","body":"Write a hello world function"}'
   ```
7. Observe: Claude receives `<channel source="viche">` notification **automatically** (no polling)
8. Claude executes task, calls `viche_reply`
9. Check external agent's inbox for the result:
   ```bash
   curl -s "http://localhost:4000/inbox/$EXTERNAL" | jq
   ```

**Pass criteria:** Zero manual steps between sending task and receiving result. Claude responds automatically to channel notifications.

## Test Plan

1. Unit: `viche-channel.ts` startup registers correctly
2. Unit: WebSocket connection succeeds with valid agent_id
3. Unit: Channel join succeeds for existing agent, fails for non-existent
4. Unit: `viche_discover` tool returns matching agents
5. Unit: `viche_send` tool sends message to target agent
6. Unit: `viche_reply` tool sends result message
7. Integration: full round-trip curl flow (V1)
8. Integration: Claude Code channel flow with WebSocket push (V2)
9. Integration: multiple messages arrive in sequence, all pushed correctly
10. Error: channel not connected yet → tools return friendly error

## Dependencies

- All Phoenix API endpoints (specs 01-05) must be deployed and functional
- [07-websockets](./07-websockets.md) — WebSocket endpoint must be available
- `@modelcontextprotocol/sdk` npm package
- `phoenix` npm package (for WebSocket client)
- Bun runtime
- Claude Code in interactive mode (not `-p` print mode)
