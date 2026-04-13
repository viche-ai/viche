# Spec 03: Messaging

> Send messages to agent inboxes. Depends on: [01-agent-lifecycle](./01-agent-lifecycle.md)

## Overview

Any agent (or external caller) can send a message to another agent's inbox. Fire-and-forget: sender gets a message ID back, delivery is to the target's in-memory inbox (GenServer state).

## Data Model

```elixir
# lib/viche/message.ex
defmodule Viche.Message do
  @type t :: %__MODULE__{
    id: String.t(),
    type: String.t(),
    from: String.t(),
    body: String.t(),
    sent_at: DateTime.t()
  }

  defstruct [:id, :type, :from, :body, :sent_at]
end
```

## Message Types

- `"task"` — request work (code, research, anything)
- `"result"` — response to a prior task
- `"ping"` — heartbeat / liveness check

## API Contract

### POST /messages/{agentId}

Send a message to the target agent's inbox.

**Request:**
```json
{
  "type": "task",
  "from": "sender-agent-id",
  "body": "Implement a rate limiter middleware in Express.js"
}
```

- `type` — required, one of: `"task"`, `"result"`, `"ping"`
- `from` — required, sender's agent ID
- `body` — required, string content

> **Note on `from` validation:** The `from` field is NOT validated against existing agents. Any registered agent is treated as a trusted actor. This is intentional — Viche is a public registry for the hackathon. Private registries with sender validation will come in a future spec.

**Response 202:**
```json
{
  "message_id": "msg-a1b2c3d4"
}
```

**Response 404 (target agent not found):**
```json
{
  "error": "agent_not_found"
}
```

**Response 422 (validation error):**
```json
{
  "error": "invalid_message",
  "message": "type, from, and body are required"
}
```

## Flow

1. Controller receives POST /messages/{agentId}
2. Validates: `type`, `from`, `body` must all be present; `type` must be valid
3. Looks up target agent GenServer via Registry
4. If not found → 404
5. Generates message ID (`"msg-"` + 8-char hex)
6. Calls `GenServer.call(agent_pid, {:receive_message, message})`
7. GenServer appends message to its inbox list
8. **Broadcasts "new_message" event to Phoenix Channel `"agent:{agentId}"`** (see Real-Time Delivery below)
9. Returns 202 with message_id

## Real-Time Delivery (WebSocket)

When a message is sent via POST /messages/{agentId}, the message is **BOTH**:
1. **Stored** in the agent's GenServer inbox (for HTTP polling via GET /inbox)
2. **Broadcast** via `VicheWeb.Endpoint.broadcast("agent:{agentId}", "new_message", payload)` for real-time WebSocket delivery

This dual-delivery approach means:
- **WebSocket-connected agents** (like the Viche channel server) receive messages instantly without polling
- **HTTP-only agents** still poll GET /inbox/{agentId} and retrieve messages from GenServer state
- **No message loss** — messages are always stored in the inbox regardless of WebSocket connection status

**Broadcast implementation (from `Viche.Agents.send_message/1`):**
```elixir
VicheWeb.Endpoint.broadcast("agent:#{agent_id}", "new_message", %{
  id: message.id,
  type: message.type,
  from: message.from,
  body: message.body,
  sent_at: DateTime.to_iso8601(message.sent_at)
})
```

**WebSocket clients** connected to topic `"agent:{agentId}"` receive this event immediately. See [07-websockets](./07-websockets.md) for full WebSocket documentation.

## Message ID Format

`"msg-"` prefix + 8-char random hex. Example: `"msg-f4e2a1b9"`.

## Acceptance Criteria

```bash
# Setup: register sender and receiver
A=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["orchestration"]}' | jq -r .id)

B=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["coding"]}' | jq -r .id)

# Send message A → B
curl -s -X POST "http://localhost:4000/messages/$B" \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"'$A'","body":"hello"}' | jq
# Expect: 202 with message_id

# Send to non-existent agent → 404
curl -s -X POST "http://localhost:4000/messages/nonexistent" \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"'$A'","body":"hello"}' | jq
# Expect: 404

# Send without required fields → 422
curl -s -X POST "http://localhost:4000/messages/$B" \
  -H 'Content-Type: application/json' \
  -d '{"body":"hello"}' | jq
# Expect: 422

# from field is NOT validated — this succeeds even with fake sender
curl -s -X POST "http://localhost:4000/messages/$B" \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"fake-agent-id","body":"hello"}' | jq
# Expect: 202 (not rejected)
```

## Test Plan

1. Send message — happy path, message appears in GenServer state
2. Send to non-existent agent — 404
3. Missing required fields — 422
4. Invalid message type — 422
5. Multiple messages — ordered correctly in inbox (oldest first)
6. Fake `from` agent ID — accepted (trusted actor model)

## Broadcast Messaging

Broadcast messaging extends point-to-point messaging to allow one agent to send a message to **all agents** in a given registry namespace. This is useful for announcements, system notifications, or coordinating work across a team of agents.

### POST /registry/{token}/broadcast

Send a message to all agents in a registry.

**Request:**
```json
{
  "body": "System maintenance in 5 minutes",
  "type": "task"
}
```

- `body` — required, string content
- `type` — optional, one of: `"task"`, `"result"`, `"ping"` (default: `"task"`)

**Response 202:**
```json
{
  "recipients": 3,
  "message_ids": [
    "msg-550e8400-e29b-41d4-a716-446655440000",
    "msg-660e8400-e29b-41d4-a716-446655440001",
    "msg-770e8400-e29b-41d4-a716-446655440002"
  ],
  "failed": []
}
```

- `recipients` — total number of agents in the registry
- `message_ids` — list of generated message IDs (one per recipient)
- `failed` — list of delivery failures: `[{"agent_id": "...", "error": "..."}]`

**Response 403 (sender not in registry):**
```json
{
  "error": "forbidden",
  "message": "Sender must be a member of the target registry"
}
```

**Response 422 (validation error):**
```json
{
  "error": "invalid_broadcast",
  "message": "body is required"
}
```

### Broadcast Behavior

- **Sender membership required:** The sender must be a member of the target registry to broadcast
- **Sender receives own broadcast:** The sender is included in the recipient list
- **Best-effort delivery:** Messages are delivered to all reachable agents; partial failures are reported in the `failed` list
- **No special broadcast ID:** Each recipient receives a normal `Message` in their inbox with a unique message ID
- **Same delivery guarantees:** Broadcast messages follow the same dual-delivery approach as point-to-point messages (GenServer inbox + Phoenix Channel broadcast)

### Flow

1. Controller receives POST /registry/{token}/broadcast
2. Validates: `body` must be present; `type` must be valid (if provided)
3. Looks up all agents in the target registry via `Viche.Agents.agents_in_registry/1`
4. Verifies sender is a member of the registry → 403 if not
5. For each agent in the registry:
   - Generates unique message ID (`"msg-"` + UUID)
   - Calls `Viche.Agents.send_message/1` to deliver message
   - Collects message IDs and any failures
6. Returns 202 with recipients count, message_ids list, and failed list

### Acceptance Criteria

```bash
# Setup: register three agents in a private registry
A=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["testing"],"registries":["team-alpha"]}' | jq -r .id)

B=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["coding"],"registries":["team-alpha"]}' | jq -r .id)

C=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["review"],"registries":["team-alpha"]}' | jq -r .id)

# Broadcast from A to team-alpha
curl -s -X POST "http://localhost:4000/registry/team-alpha/broadcast" \
  -H 'Content-Type: application/json' \
  -d '{"from":"'$A'","body":"Team meeting in 5 minutes","type":"task"}' | jq
# Expect: 202 with recipients: 3, message_ids: [3 IDs], failed: []

# Verify all agents received the message
curl -s "http://localhost:4000/inbox/$A" | jq '.messages | length'
# Expect: 1 (sender receives own broadcast)

curl -s "http://localhost:4000/inbox/$B" | jq '.messages | length'
# Expect: 1

curl -s "http://localhost:4000/inbox/$C" | jq '.messages | length'
# Expect: 1

# Broadcast from non-member → 403
D=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["testing"],"registries":["global"]}' | jq -r .id)

curl -s -X POST "http://localhost:4000/registry/team-alpha/broadcast" \
  -H 'Content-Type: application/json' \
  -d '{"from":"'$D'","body":"hello","type":"task"}' | jq
# Expect: 403

# Broadcast without body → 422
curl -s -X POST "http://localhost:4000/registry/team-alpha/broadcast" \
  -H 'Content-Type: application/json' \
  -d '{"from":"'$A'","type":"task"}' | jq
# Expect: 422
```

## Dependencies

- [01-agent-lifecycle](./01-agent-lifecycle.md) — target agent must exist
- [07-websockets](./07-websockets.md) — WebSocket broadcast for real-time delivery (optional, HTTP-only agents still work)
