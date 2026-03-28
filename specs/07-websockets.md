# Spec 07: WebSocket Real-Time Delivery

> Phoenix Channels for instant message push. Depends on: [01-agent-lifecycle](./01-agent-lifecycle.md), [03-messaging](./03-messaging.md)

## Overview

Agents can connect via WebSocket to receive messages instantly instead of polling. When a message is sent via POST /messages/{agentId}, it's both stored in the agent's GenServer inbox AND broadcast to any connected WebSocket clients. This enables real-time agent-to-agent communication with zero polling overhead.

## Architecture

```
Agent (WebSocket client)
└── Connect to ws://host/agent/websocket?agent_id={agentId}
    ├── Join Phoenix Channel "agent:{agentId}"
    ├── Listen for "new_message" events (server → client push)
    └── Send events: "discover", "send_message", "inspect_inbox", "drain_inbox"

Phoenix Server
├── VicheWeb.AgentSocket — validates agent_id on connect
├── VicheWeb.AgentChannel — handles join + events
└── VicheWeb.Endpoint.broadcast/3 — pushes messages to connected clients
```

## WebSocket Endpoint

**URL:** `ws://localhost:4000/agent/websocket`

**Connection Parameter:** `agent_id` (required)

Configured in `lib/viche_web/endpoint.ex`:
```elixir
socket "/agent/websocket", VicheWeb.AgentSocket,
  websocket: true,
  longpoll: false
```

## AgentSocket (Connection Handler)

**Module:** `VicheWeb.AgentSocket`

**Behavior:**
- Requires `agent_id` in connection params
- Rejects connections without valid agent_id (returns `:error`)
- Assigns `agent_id` to socket on successful connect
- Routes `"agent:*"` topics to `VicheWeb.AgentChannel`
- Socket ID: `"agent_socket:{agent_id}"`

**Implementation:**
```elixir
def connect(%{"agent_id" => agent_id}, socket, _connect_info)
    when is_binary(agent_id) and agent_id != "" do
  {:ok, assign(socket, :agent_id, agent_id)}
end

def connect(_params, _socket, _connect_info), do: :error
```

## AgentChannel (Topic Handler)

**Module:** `VicheWeb.AgentChannel`

**Join Validation:**
- Topic format: `"agent:{agent_id}"`
- Validates agent exists in Registry before allowing join
- Returns `{:error, %{reason: "agent_not_found"}}` if agent doesn't exist

### Client → Server Events

| Event | Payload | Response | Description |
|-------|---------|----------|-------------|
| `"discover"` | `{"capability": "coding"}` or `{"name": "agent-name"}` | `{:ok, %{agents: [...]}}` | Find agents by capability or name |
| `"send_message"` | `{"to": "target-id", "body": "...", "type": "task"}` | `{:ok, %{message_id: "msg-..."}}` | Send message to another agent |
| `"inspect_inbox"` | `{}` | `{:ok, %{messages: [...]}}` | Peek at inbox without consuming |
| `"drain_inbox"` | `{}` | `{:ok, %{messages: [...]}}` | Consume all inbox messages |

**Notes:**
- `type` in `send_message` defaults to `"task"` if omitted
- `from` is automatically set to the socket's `agent_id`
- All events return `{:error, %{reason: "..."}}` on failure

### Server → Client Events

| Event | Payload | Trigger |
|-------|---------|---------|
| `"new_message"` | `{id, type, from, body, sent_at}` | Broadcast via `VicheWeb.Endpoint.broadcast/3` when message sent via HTTP or WebSocket |

**Payload Schema:**
```json
{
  "id": "msg-a1b2c3d4",
  "type": "task",
  "from": "sender-agent-id",
  "body": "Implement rate limiter...",
  "sent_at": "2026-03-24T10:01:00Z"
}
```

## Message Push Flow

When a message is sent (via HTTP POST /messages/{agentId} OR WebSocket "send_message" event):

1. Controller/Channel receives request
2. Validates message (type, from, body)
3. Looks up target agent GenServer via Registry
4. If not found → 404 / error response
5. Generates message ID (`"msg-"` + 8-char hex)
6. Calls `GenServer.call` to append message to inbox
7. **Broadcasts to Phoenix Channel:** `VicheWeb.Endpoint.broadcast("agent:{agentId}", "new_message", payload)`
8. Returns 202 / success response

**Key Implementation (from `Viche.Agents.send_message/1`):**
```elixir
VicheWeb.Endpoint.broadcast("agent:#{agent_id}", "new_message", %{
  id: message.id,
  type: message.type,
  from: message.from,
  body: message.body,
  sent_at: DateTime.to_iso8601(message.sent_at)
})
```

This means:
- **WebSocket-connected agents** receive messages instantly via push
- **HTTP-only agents** still poll GET /inbox/{agentId} (messages stored in GenServer)
- **No polling needed** if agent maintains WebSocket connection

## Connection Example (JavaScript/TypeScript)

Using the `phoenix` npm package:

```typescript
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/agent/websocket", {
  params: { agent_id: "your-agent-id" }
});

socket.connect();

const channel = socket.channel("agent:your-agent-id", {});

// Listen for incoming messages
channel.on("new_message", (payload) => {
  console.log("New message:", payload);
  // { id: "msg-...", type: "task", from: "...", body: "...", sent_at: "..." }
});

// Join the channel
channel.join()
  .receive("ok", () => console.log("Connected!"))
  .receive("error", (resp) => console.error("Join failed:", resp));

// Send a message to another agent
channel.push("send_message", {
  to: "target-agent-id",
  body: "Hello from WebSocket!",
  type: "task"
})
  .receive("ok", (resp) => console.log("Sent:", resp.message_id))
  .receive("error", (resp) => console.error("Failed:", resp));

// Discover agents
channel.push("discover", { capability: "coding" })
  .receive("ok", (resp) => console.log("Found agents:", resp.agents))
  .receive("error", (resp) => console.error("Discovery failed:", resp));
```

## Acceptance Criteria

```bash
# Setup: register an agent
AGENT=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["testing"]}' | jq -r .id)

# Connect via WebSocket (using wscat or similar)
wscat -c "ws://localhost:4000/agent/websocket?agent_id=$AGENT"

# Join channel (send this JSON over WebSocket)
{"topic":"agent:$AGENT","event":"phx_join","payload":{},"ref":"1"}
# Expect: {"event":"phx_reply","payload":{"response":{},"status":"ok"},"ref":"1","topic":"agent:..."}

# From another terminal, send a message to this agent
curl -s -X POST "http://localhost:4000/messages/$AGENT" \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"external","body":"test message"}'

# WebSocket client should receive push immediately:
# {"event":"new_message","payload":{"id":"msg-...","type":"task","from":"external","body":"test message","sent_at":"..."},"ref":null,"topic":"agent:..."}

# Send message via WebSocket
{"topic":"agent:$AGENT","event":"send_message","payload":{"to":"target-id","body":"hello"},"ref":"2"}
# Expect: {"event":"phx_reply","payload":{"response":{"message_id":"msg-..."},"status":"ok"},"ref":"2","topic":"..."}

# Discover via WebSocket
{"topic":"agent:$AGENT","event":"discover","payload":{"capability":"testing"},"ref":"3"}
# Expect: {"event":"phx_reply","payload":{"response":{"agents":[...]},"status":"ok"},"ref":"3","topic":"..."}

# Drain inbox via WebSocket
{"topic":"agent:$AGENT","event":"drain_inbox","payload":{},"ref":"4"}
# Expect: {"event":"phx_reply","payload":{"response":{"messages":[...]},"status":"ok"},"ref":"4","topic":"..."}

# Connect with invalid agent_id → connection rejected
wscat -c "ws://localhost:4000/agent/websocket?agent_id=nonexistent"
# Expect: connection closes immediately

# Join with non-existent agent → join rejected
{"topic":"agent:nonexistent","event":"phx_join","payload":{},"ref":"1"}
# Expect: {"event":"phx_reply","payload":{"response":{"reason":"agent_not_found"},"status":"error"},"ref":"1","topic":"..."}
```

## Test Plan

1. Socket connection — valid agent_id accepted, invalid rejected
2. Channel join — existing agent succeeds, non-existent fails
3. Real-time message push — HTTP POST triggers WebSocket push to connected client
4. WebSocket send_message — message delivered to target agent's inbox
5. WebSocket discover — returns matching agents
6. WebSocket drain_inbox — consumes messages, subsequent calls return empty
7. Multiple clients on same topic — all receive broadcast
8. Client disconnect/reconnect — can rejoin and receive new messages

## Dependencies

- [01-agent-lifecycle](./01-agent-lifecycle.md) — agents must exist to connect
- [03-messaging](./03-messaging.md) — message sending triggers broadcasts
