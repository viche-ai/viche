---
date: 2026-04-06T12:00:00+02:00
researcher: mnemosyne
git_commit: HEAD
branch: main
repository: viche
topic: "HTTP vs WebSocket transport usage in OpenClaw and OpenCode plugins"
scope: "channel/openclaw-plugin-viche/, channel/opencode-plugin-viche/, lib/viche_web/channels/"
query_type: map
tags: [research, plugins, transport, websocket, http, refactoring-scope]
status: complete
confidence: high
sources_scanned:
  files: 12
  thoughts_docs: 0
---

# Research: HTTP vs WebSocket Transport in Viche Plugins

**Date**: 2026-04-06
**Commit**: HEAD
**Branch**: main
**Confidence**: High - All relevant code paths traced with file:line citations

## Query
Deep-dive into the OpenClaw and OpenCode plugins to map exactly how they use HTTP vs WebSocket for all operations. Understand the full refactoring scope for moving `viche_send` and `viche_reply` tools from HTTP to WebSocket.

## Summary
Both plugins use a **hybrid transport model**: HTTP for registration and all tool operations (discover, send, reply), WebSocket for receiving inbound messages only. The server-side AgentChannel already supports `send_message` and `discover` events via WebSocket, making the refactoring feasible. Key differences exist in response formats between HTTP and WebSocket that would need handling.

## Transport Usage Map

### OpenClaw Plugin (`channel/openclaw-plugin-viche/`)

| Operation | Transport | File:Line | Notes |
|-----------|-----------|-----------|-------|
| Registration | HTTP POST | `service.ts:48-52` | `/registry/register` |
| WebSocket Connect | WS | `service.ts:243-248` | Phoenix Socket to `/agent/websocket` |
| Channel Join | WS | `service.ts:260-362` | Joins `agent:{agentId}` |
| Inbound Messages | WS | `service.ts:326-328` | Receives `new_message` events |
| `viche_discover` | HTTP GET | `tools.ts:119-150` | `/registry/discover?capability=...` |
| `viche_send` | HTTP POST | `tools.ts:200-238` | `/messages/{agentId}` |
| `viche_reply` | HTTP POST | `tools.ts:277-302` | `/messages/{agentId}` with type="result" |

### OpenCode Plugin (`channel/opencode-plugin-viche/`)

| Operation | Transport | File:Line | Notes |
|-----------|-----------|-----------|-------|
| Registration | HTTP POST | `service.ts:51-55` | `/registry/register` |
| WebSocket Connect | WS | `service.ts:104-109` | Phoenix Socket to `/agent/websocket` |
| Channel Join | WS | `service.ts:111-156` | Joins `agent:{agentId}` |
| Inbound Messages | WS | `service.ts:112-113` | Receives `new_message` events |
| `viche_discover` | HTTP GET | `tools.ts:138-216` | `/registry/discover?capability=...` (with multi-registry aggregation) |
| `viche_send` | HTTP POST | `tools.ts:254-261` via `postMessage` | `/messages/{to}` |
| `viche_reply` | HTTP POST | `tools.ts:297-304` via `postMessage` | `/messages/{to}` with type="result" |

## Key Entry Points

### HTTP Tool Handlers (To Be Replaced)

| File | Symbol | Purpose |
|------|--------|---------|
| `channel/openclaw-plugin-viche/tools.ts:114-151` | `viche_discover.execute` | HTTP GET discovery |
| `channel/openclaw-plugin-viche/tools.ts:187-239` | `viche_send.execute` | HTTP POST send message |
| `channel/openclaw-plugin-viche/tools.ts:266-304` | `viche_reply.execute` | HTTP POST reply |
| `channel/opencode-plugin-viche/tools.ts:133-217` | `viche_discover.execute` | HTTP GET discovery (multi-registry) |
| `channel/opencode-plugin-viche/tools.ts:239-264` | `viche_send.execute` | HTTP POST send message |
| `channel/opencode-plugin-viche/tools.ts:283-307` | `viche_reply.execute` | HTTP POST reply |
| `channel/opencode-plugin-viche/tools.ts:77-94` | `postMessage` | Shared HTTP POST helper |

### WebSocket Client Code (Already Exists)

| File | Symbol | Purpose |
|------|--------|---------|
| `channel/openclaw-plugin-viche/service.ts:243-248` | Socket constructor | Creates Phoenix Socket with `agent_id` param |
| `channel/openclaw-plugin-viche/service.ts:260` | `socket.channel()` | Creates channel for `agent:{agentId}` |
| `channel/openclaw-plugin-viche/service.ts:326-328` | `channel.on("new_message")` | Handles inbound messages |
| `channel/opencode-plugin-viche/service.ts:104-109` | Socket constructor | Creates Phoenix Socket |
| `channel/opencode-plugin-viche/service.ts:111` | `socket.channel()` | Creates channel for `agent:{agentId}` |
| `channel/opencode-plugin-viche/service.ts:112-113` | `channel.on("new_message")` | Handles inbound messages |

### Server-Side Channel Events (Already Available)

| File | Symbol | Purpose |
|------|--------|---------|
| `lib/viche_web/channels/agent_channel.ex:86-97` | `handle_in("discover", %{"capability" => cap})` | Discovery by capability |
| `lib/viche_web/channels/agent_channel.ex:99-109` | `handle_in("discover", %{"name" => name})` | Discovery by name |
| `lib/viche_web/channels/agent_channel.ex:112-128` | `handle_in("send_message", ...)` | Send message to another agent |
| `lib/viche_web/channels/agent_channel.ex:154-161` | `handle_in("inspect_inbox")` | Peek inbox |
| `lib/viche_web/channels/agent_channel.ex:174-181` | `handle_in("drain_inbox")` | Consume inbox |

## Response Format Comparison

### Discovery

**HTTP Response** (`GET /registry/discover`):
```json
{
  "agents": [
    {"id": "uuid", "name": "...", "capabilities": [...], "description": "..."}
  ]
}
```

**WebSocket Response** (`discover` event reply):
```json
{
  "agents": [
    {"id": "uuid", "name": "...", "capabilities": [...], "description": "..."}
  ]
}
```

**Difference**: None - formats are identical.

### Send Message

**HTTP Response** (`POST /messages/{agentId}`):
```json
{"message_id": "msg-uuid"}
```
Status: 202 Accepted

**WebSocket Response** (`send_message` event reply):
```json
{"message_id": "msg-uuid"}
```

**Difference**: HTTP uses `message_id` (underscore), WebSocket uses `message_id` (underscore). Formats are identical.

### Error Responses

**HTTP Errors**:
- 404: `{"error": "agent_not_found", "message": "..."}`
- 422: `{"error": "invalid_message", "message": "..."}`

**WebSocket Errors** (reply tuple `{:error, payload}`):
- `{"error": "agent_not_found", "message": "..."}`
- `{"error": "missing_field", "message": "required field 'to' is missing"}`
- `{"error": "missing_fields", "message": "required fields 'to' and 'body' are missing"}`

**Difference**: WebSocket has more granular error types for missing fields. HTTP lumps them into `invalid_message`.

## Architecture & Flow

### Current Flow (HTTP Tools)

```
Tool Invocation
    ↓
tools.ts execute()
    ↓ HTTP fetch()
VicheWeb.MessageController / RegistryController
    ↓
Viche.Agents context
    ↓
Response → Tool Result
```

### Target Flow (WebSocket Tools)

```
Tool Invocation
    ↓
tools.ts execute()
    ↓ channel.push("send_message", payload)
VicheWeb.AgentChannel.handle_in/3
    ↓
Viche.Agents context
    ↓
Reply → Tool Result
```

## Plugin-Specific Considerations

### OpenClaw Plugin

**State Access**: Tools access `state.agentId` directly (`tools.ts:192-193`, `tools.ts:271-272`)

**Channel Access**: The channel is owned by the service (`service.ts:221-222`), not exposed to tools. Refactoring requires either:
1. Exposing channel reference in `VicheState`
2. Adding channel push methods to state object

**Correlation Tracking**: `viche_send` records `message_id → sessionKey` for routing replies (`tools.ts:226-236`). WebSocket response also returns `message_id`, so this continues to work.

**Session Context**: Tools capture `ctx.sessionKey` for correlation (`tools.ts:163`, `tools.ts:249`).

### OpenCode Plugin

**State Access**: Tools call `ensureSessionReady(sessionID)` to get `SessionState` which contains `agentId` (`tools.ts:244-249`, `tools.ts:287-293`)

**Channel Access**: `SessionState` already contains `socket` and `channel` references (`types.ts:30-39`). Tools can access channel via `sessionState.channel`.

**No Correlation Tracking**: OpenCode plugin does not track message correlations (simpler model).

**Session Context**: Tools receive `context.sessionID` and use it to get session state.

## WebSocket Channel Push Pattern

Phoenix JS client push pattern:
```typescript
channel.push("send_message", { to, body, type })
  .receive("ok", (resp) => { /* success: resp.message_id */ })
  .receive("error", (resp) => { /* error: resp.error, resp.message */ })
  .receive("timeout", () => { /* timeout */ });
```

This is already used in the service layer for channel join (`service.ts:330-361` OpenClaw, `service.ts:128-154` OpenCode).

## Gaps Identified

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| No existing WebSocket push in tools | "channel.push", "push(" | `channel/*/tools.ts` |
| No channel reference in OpenClaw VicheState | "channel", "socket" in VicheState | `channel/openclaw-plugin-viche/types.ts` |

## Evidence Index

### Code Files
- `channel/openclaw-plugin-viche/tools.ts:1-307` - OpenClaw tool definitions
- `channel/openclaw-plugin-viche/service.ts:1-425` - OpenClaw service with WebSocket
- `channel/openclaw-plugin-viche/types.ts:1-362` - OpenClaw types including VicheState
- `channel/opencode-plugin-viche/tools.ts:1-311` - OpenCode tool definitions
- `channel/opencode-plugin-viche/service.ts:1-402` - OpenCode service with WebSocket
- `channel/opencode-plugin-viche/types.ts:1-88` - OpenCode types including SessionState
- `lib/viche_web/channels/agent_channel.ex:1-212` - Server-side channel handlers
- `lib/viche_web/controllers/message_controller.ex:1-67` - HTTP message endpoint
- `lib/viche_web/controllers/registry_controller.ex:1-214` - HTTP registry endpoints

## Related Research
- `thoughts/research/2026-03-24-openclaw-viche-integration.md` - Original OpenClaw integration design

---

## Handoff Inputs

**If planning needed** (for @prometheus):
- Scope: Both plugins' tools.ts files, OpenClaw types.ts (to add channel to state)
- Entry points: `viche_send.execute`, `viche_reply.execute`, `viche_discover.execute` in both plugins
- Constraints: 
  - OpenClaw needs channel reference added to VicheState
  - OpenCode already has channel in SessionState
  - Response formats are compatible (no transformation needed)
  - Error handling differs slightly (WebSocket more granular)
- Open questions:
  - Should `viche_discover` also move to WebSocket? (Currently HTTP, server supports WS)
  - How to handle WebSocket timeout vs HTTP timeout?

**If implementation needed** (for @vulkanus):
- Test locations: `channel/openclaw-plugin-viche/*.test.ts`, `channel/opencode-plugin-viche/__tests__/*.ts`
- Pattern to follow: Existing `channel.push().receive()` pattern in service.ts files
- Entry points: `tools.ts` in both plugins
