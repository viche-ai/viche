---
date: 2026-04-06T12:00:00+00:00
researcher: mnemosyne
git_commit: HEAD
branch: main
repository: viche
topic: "WebSocket from parameter flow for send_message events"
scope: server (Elixir) + plugins (TypeScript)
query_type: map
tags: [research, websocket, messaging, security, impersonation-prevention]
status: complete
confidence: high
sources_scanned:
  files: 18
  thoughts_docs: 0
---

# Research: WebSocket `from` Parameter Flow for `send_message` Events

**Date**: 2026-04-06
**Commit**: HEAD
**Branch**: main
**Confidence**: high — all claims verified against code with file:line citations

## Query
Research how the `from` parameter flows through WebSocket message sending in the Viche codebase. Understand the full scope of removing `from` from WebSocket `send_message` events since the server already knows the agent_id from the socket connection.

## Summary
The server **already ignores** client-supplied `from` for WebSocket messages. `VicheWeb.AgentChannel.handle_in/3` derives `from` from `socket.assigns.agent_id` (line 114), which is set during socket connection. Any client-supplied `from` is silently overwritten. The plugins (claude-code, openclaw, opencode) do NOT send `from` via WebSocket — they only include `to`, `body`, and `type`. However, the openclaw and opencode plugins use HTTP REST for `viche_send`/`viche_reply` tools, where they DO include `from` in the request body.

## Key Entry Points

| File | Symbol | Purpose |
|------|--------|---------|
| `lib/viche_web/channels/agent_socket.ex:26-32` | `connect/3` | Stores `agent_id` in socket assigns |
| `lib/viche_web/channels/agent_channel.ex:109-126` | `handle_in("send_message", ...)` | Derives `from` from socket, ignores client `from` |
| `lib/viche/agents.ex:314-346` | `send_message/1` | Validates and delivers message with `from` field |
| `lib/viche_web/controllers/message_controller.ex:25-50` | `send_message/2` | HTTP endpoint — derives `from` from `conn.assigns.current_agent_id` |

## Architecture & Flow

### WebSocket Message Flow

```
Client (Plugin)
    │
    │ WebSocket connect with ?agent_id=UUID
    ▼
VicheWeb.AgentSocket.connect/3 (line 26-32)
    │ Validates agent_id param
    │ Stores in socket.assigns.agent_id
    ▼
VicheWeb.AgentChannel.join/3 (line 44-54)
    │ Verifies agent exists in Registry
    │ Copies agent_id to channel socket.assigns
    ▼
Client pushes "send_message" event
    │ Payload: {to, body, type} — NO from needed
    ▼
VicheWeb.AgentChannel.handle_in("send_message", ...) (line 109-126)
    │ from = socket.assigns.agent_id  ← SERVER DERIVES THIS
    │ Any client "from" is IGNORED
    ▼
Viche.Agents.send_message/1 (line 314-346)
    │ Creates Message struct with from field
    │ Broadcasts to agent:{to} channel
    ▼
Target agent receives "new_message" push
```

### HTTP Message Flow (for comparison)

```
Client (Plugin)
    │
    │ POST /messages/:agent_id
    │ Headers: X-Agent-Id: sender-uuid
    │ Body: {from, body, type}
    ▼
VicheWeb.Plugs.ApiAuth
    │ Validates X-Agent-Id header
    │ Sets conn.assigns.current_agent_id
    ▼
VicheWeb.MessageController.send_message/2 (line 25-50)
    │ from = conn.assigns[:current_agent_id]  ← SERVER DERIVES THIS
    │ Client "from" in body is IGNORED
    ▼
Viche.Agents.send_message/1
```

### Key Interfaces

| Interface/Type | Location | Used By |
|----------------|----------|---------|
| `socket.assigns.agent_id` | Set at `agent_socket.ex:32` | `AgentChannel.handle_in/3` |
| `conn.assigns.current_agent_id` | Set by `ApiAuth` plug | `MessageController.send_message/2` |
| `Viche.Message.t()` | `lib/viche/message.ex:9-15` | All message operations |

## Server-Side Implementation Details

### Socket Connection (`agent_socket.ex`)

```elixir
# lib/viche_web/channels/agent_socket.ex:26-32
def connect(%{"agent_id" => agent_id} = params, socket, _connect_info)
    when is_binary(agent_id) and agent_id != "" do
  token = params["token"]

  case authenticate_socket(token, agent_id) do
    :ok ->
      {:ok, assign(socket, :agent_id, agent_id)}  # ← agent_id stored here
    :error ->
      :error
  end
end
```

### Channel Join (`agent_channel.ex`)

```elixir
# lib/viche_web/channels/agent_channel.ex:44-49
def join("agent:" <> agent_id, _params, socket) do
  case Registry.lookup(Viche.AgentRegistry, agent_id) do
    [{pid, _meta}] ->
      send(pid, :websocket_connected)
      Logger.info("Agent #{agent_id} joined channel")
      {:ok, assign(socket, :agent_id, agent_id)}  # ← agent_id in channel assigns
    [] ->
      {:error, %{reason: "agent_not_found"}}
  end
end
```

### Send Message Handler (`agent_channel.ex`)

```elixir
# lib/viche_web/channels/agent_channel.ex:109-126
def handle_in("send_message", %{"to" => to, "body" => body} = params, socket) do
  # Always derive `from` from the server-verified socket identity.
  # Any client-supplied "from" key in `params` is intentionally ignored
  # to prevent impersonation — only the authenticated socket.assigns.agent_id
  # is trusted as the sender.
  from = socket.assigns.agent_id  # ← SERVER DERIVES FROM, IGNORES CLIENT
  type = Map.get(params, "type", "task")

  case Viche.Agents.send_message(%{to: to, from: from, body: body, type: type}) do
    {:ok, message_id} ->
      {:reply, {:ok, %{message_id: message_id}}, socket}
    {:error, reason} ->
      {:reply, {:error, %{error: to_string(reason), message: "..."}}, socket}
  end
end
```

### HTTP Controller (`message_controller.ex`)

```elixir
# lib/viche_web/controllers/message_controller.ex:25-33
def send_message(conn, %{"agent_id" => agent_id, "type" => type, "body" => body}) do
  # Derive `from` from the server-verified agent identity, ignoring any
  # client-supplied `"from"` param to prevent impersonation.
  from = conn.assigns[:current_agent_id]  # ← SERVER DERIVES FROM

  if is_nil(from) do
    invalid_message_response(conn)
  else
    attrs = %{to: agent_id, from: from, body: body, type: type}
    # ...
  end
end
```

## Plugin Implementation Details

### Claude Code Plugin (`viche-server.ts`)

**WebSocket send_message** — Does NOT include `from`:

```typescript
// channel/claude-code-plugin-viche/viche-server.ts:367-371
await channelPush(activeChannel, "send_message", {
  to: args.to,
  body: args.body,
  type: msgType,
  // NO "from" field — server derives it
});
```

```typescript
// channel/claude-code-plugin-viche/viche-server.ts:391-395
await channelPush(activeChannel, "send_message", {
  to: args.to,
  body: args.body,
  type: "result",
  // NO "from" field — server derives it
});
```

### OpenClaw Plugin (`tools.ts`)

**HTTP REST** — Includes `from` in body (but server ignores it):

```typescript
// channel/openclaw-plugin-viche/tools.ts:202-211
resp = await fetch(
  `${config.registryUrl}/messages/${encodeURIComponent(params.to)}`,
  {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Agent-Id": state.agentId! },
    body: JSON.stringify({
      from: state.agentId,  // ← Included but server ignores, uses X-Agent-Id header
      body: params.body,
      type: msgType,
    }),
  },
);
```

```typescript
// channel/openclaw-plugin-viche/tools.ts:279-288
resp = await fetch(
  `${config.registryUrl}/messages/${encodeURIComponent(params.to)}`,
  {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Agent-Id": state.agentId! },
    body: JSON.stringify({
      from: state.agentId,  // ← Included but server ignores
      body: params.body,
      type: "result",
    }),
  },
);
```

### OpenCode Plugin (`tools.ts`)

**HTTP REST** — Includes `from` in body:

```typescript
// channel/opencode-plugin-viche/tools.ts:77-85
async function postMessage(args: PostMessageArgs): Promise<string | null> {
  const { registryUrl, to, from, body, type } = args;
  let resp: Response;
  try {
    resp = await fetch(`${registryUrl}/messages/${to}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ from, body, type }),  // ← Includes from
    });
  }
  // ...
}
```

```typescript
// channel/opencode-plugin-viche/tools.ts:254-260
const err = await postMessage({
  registryUrl: config.registryUrl,
  to,
  from: sessionState.agentId,  // ← Passed to postMessage
  body,
  type: msgType,
});
```

## Test Coverage

### Impersonation Prevention Tests

| Test | Location | Purpose |
|------|----------|---------|
| `"send_message 'from' is always socket.assigns.agent_id, ignoring any client-supplied 'from'"` | `agent_channel_test.exs:136-152` | Verifies client `from` is ignored |
| `"client-supplied 'from' is silently overwritten by socket.assigns.agent_id"` | `agent_channel_test.exs:203-218` | Confirms impersonation prevention |
| `"message is attributed to the correct socket-verified agent even when 'from' is absent"` | `agent_channel_test.exs:220-233` | Verifies `from` derived when absent |
| `"two different authenticated sockets produce correct distinct 'from' values"` | `agent_channel_test.exs:235-273` | Multi-agent isolation test |

### Test Code Example

```elixir
# test/viche_web/channels/agent_channel_test.exs:136-152
test "send_message 'from' is always socket.assigns.agent_id, ignoring any client-supplied 'from'",
     %{socket: socket, agent_id: sender_id, receiver_id: receiver_id} do
  ref =
    push(socket, "send_message", %{
      "to" => receiver_id,
      "body" => "impersonation attempt",
      "type" => "task",
      # client tries to set from — must be ignored
      "from" => "evil-impersonator-id"
    })

  assert_reply ref, :ok, %{message_id: _}

  assert {:ok, [msg]} = Agents.inspect_inbox(receiver_id)
  assert msg.from == sender_id
  refute msg.from == "evil-impersonator-id"
end
```

## Files That Would Need Changes

### If Removing `from` from WebSocket Events (No Changes Needed)

The server already ignores client-supplied `from`. The Claude Code plugin already does NOT send `from` via WebSocket. **No server changes needed for WebSocket.**

### If Removing `from` from HTTP REST Body

These files include `from` in HTTP request bodies:

| File | Lines | Current Behavior |
|------|-------|------------------|
| `channel/openclaw-plugin-viche/tools.ts` | 208, 285 | Sends `from` in body, also sends `X-Agent-Id` header |
| `channel/opencode-plugin-viche/tools.ts` | 84 | Sends `from` in body, NO `X-Agent-Id` header |

**Note**: The opencode plugin does NOT send `X-Agent-Id` header, so the server's `MessageController` would need to handle this case if `from` is removed from the body.

## Gaps Identified

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| No prior research on this topic | "from", "websocket", "impersonation" | `thoughts/research/` |
| OpenCode plugin missing `X-Agent-Id` header | "X-Agent-Id" | `channel/opencode-plugin-viche/` |

## Evidence Index

### Code Files
- `lib/viche_web/channels/agent_socket.ex:26-32` — Socket connection, agent_id storage
- `lib/viche_web/channels/agent_channel.ex:44-54` — Channel join
- `lib/viche_web/channels/agent_channel.ex:109-126` — send_message handler (key file)
- `lib/viche/agents.ex:314-346` — Domain send_message function
- `lib/viche/message.ex:9-17` — Message struct definition
- `lib/viche_web/controllers/message_controller.ex:25-50` — HTTP endpoint
- `channel/claude-code-plugin-viche/viche-server.ts:367-395` — WebSocket send (no from)
- `channel/openclaw-plugin-viche/tools.ts:202-211,279-288` — HTTP send (includes from)
- `channel/opencode-plugin-viche/tools.ts:77-85,254-260` — HTTP send (includes from)
- `test/viche_web/channels/agent_channel_test.exs:136-152,203-273` — Impersonation tests

## Related Research

None found in `thoughts/research/` on this specific topic.

---

## Handoff Inputs

**If implementation needed** (for @vulkanus):

**Current State**: Server already ignores client `from` for WebSocket. Claude Code plugin already omits `from` from WebSocket payloads.

**Scope of potential changes**:
1. **WebSocket (server)**: No changes needed — already secure
2. **WebSocket (plugins)**: Claude Code already correct; openclaw/opencode use HTTP not WebSocket for tools
3. **HTTP (plugins)**: openclaw sends `X-Agent-Id` header (server uses this); opencode does NOT send header (relies on body `from`)

**Entry points**:
- `lib/viche_web/channels/agent_channel.ex:109-126` — WebSocket handler
- `lib/viche_web/controllers/message_controller.ex:25-50` — HTTP handler
- `channel/opencode-plugin-viche/tools.ts:77-85` — HTTP client

**Test locations**:
- `test/viche_web/channels/agent_channel_test.exs:136-273` — Impersonation prevention tests

**Open questions**:
- Should opencode plugin add `X-Agent-Id` header for consistency with openclaw?
- Should HTTP endpoint require `X-Agent-Id` header and reject requests without it?
