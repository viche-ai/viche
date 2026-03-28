---
date: 2026-03-24T12:00:00+02:00
researcher: mnemosyne
git_commit: HEAD
branch: main
repository: viche
topic: "Viche agent lifecycle — registration, WebSocket connection, channel join, long polling, and process management"
scope: lib/viche/, lib/viche_web/channels/, lib/viche_web/controllers/
query_type: map
tags: [research, agent-lifecycle, otp, websocket, channels]
status: complete
confidence: high
sources_scanned:
  files: 15
  thoughts_docs: 1
---

# Research: Viche Agent Lifecycle

**Date**: 2026-03-24
**Commit**: HEAD
**Branch**: main
**Confidence**: high — all claims verified against source code

## Query
Research the current Viche agent lifecycle — registration, WebSocket connection, channel join, long polling (inbox read), and process management. Understand how agents are created, connected, and what cleanup exists today.

## Summary
Viche agents are OTP GenServer processes supervised by a DynamicSupervisor. Registration creates a new GenServer process registered in an Elixir Registry. WebSocket connections validate agent_id on connect, and Channel joins verify the agent exists in the Registry. Long polling drains the inbox atomically. **No cleanup or deregistration logic exists today** — agent processes persist indefinitely until manually terminated or the application restarts.

## Key Entry Points

| File | Symbol | Purpose |
|------|--------|---------|
| `lib/viche/agents.ex:55-69` | `register_agent/1` | Creates agent GenServer via DynamicSupervisor |
| `lib/viche/agent_server.ex:27-37` | `start_link/1` | GenServer init, registers in Registry with metadata |
| `lib/viche_web/channels/agent_socket.ex:17-22` | `connect/3` | WebSocket connection handler, validates agent_id param |
| `lib/viche_web/channels/agent_channel.ex:26-34` | `join/3` | Channel join, verifies agent exists in Registry |
| `lib/viche_web/controllers/inbox_controller.ex:18-29` | `read_inbox/2` | Long polling endpoint, drains inbox atomically |
| `lib/viche/application.ex:15-16` | children list | Starts Registry and DynamicSupervisor |

## Architecture & Flow

### Process Tree
```
Viche.Supervisor (one_for_one)
├── VicheWeb.Telemetry
├── Viche.Repo
├── DNSCluster
├── Phoenix.PubSub (name: Viche.PubSub)
├── Registry (keys: :unique, name: Viche.AgentRegistry)
├── DynamicSupervisor (name: Viche.AgentSupervisor, strategy: :one_for_one)
│   └── Viche.AgentServer (one per registered agent)
└── VicheWeb.Endpoint
```

### Registration Flow
```
POST /registry/register
    │
    ▼
VicheWeb.RegistryController.register/2
    │ lib/viche_web/controllers/registry_controller.ex:13-37
    ▼
Viche.Agents.register_agent/1
    │ lib/viche/agents.ex:55-69
    │
    ├── generate_unique_id() → 8-char hex (lib/viche/agents.ex:229-236)
    │
    ├── DynamicSupervisor.start_child(Viche.AgentSupervisor, child_spec)
    │   │ lib/viche/agents.ex:64
    │   ▼
    │   Viche.AgentServer.start_link/1
    │       │ lib/viche/agent_server.ex:27-37
    │       │
    │       ├── Registers via {:via, Registry, {Viche.AgentRegistry, agent_id, meta}}
    │       │   lib/viche/agent_server.ex:34
    │       │
    │       └── init/1 creates %Viche.Agent{} struct
    │           lib/viche/agent_server.ex:64-79
    │
    └── Returns {:ok, %Viche.Agent{}}
```

### WebSocket Connection Flow
```
ws://host/agent/websocket?agent_id={id}
    │
    ▼
VicheWeb.AgentSocket.connect/3
    │ lib/viche_web/channels/agent_socket.ex:17-22
    │
    ├── Validates agent_id is present and non-empty
    │   (does NOT verify agent exists in Registry)
    │
    └── Returns {:ok, socket} with agent_id assigned
        OR :error if agent_id missing
```

### Channel Join Flow
```
Join topic "agent:{agent_id}"
    │
    ▼
VicheWeb.AgentChannel.join/3
    │ lib/viche_web/channels/agent_channel.ex:26-34
    │
    ├── Registry.lookup(Viche.AgentRegistry, agent_id)
    │   lib/viche_web/channels/agent_channel.ex:27
    │
    ├── If found: {:ok, socket} with agent_id assigned
    │
    └── If not found: {:error, %{reason: "agent_not_found"}}
```

### Long Polling (Inbox Read) Flow
```
GET /inbox/{agent_id}
    │
    ▼
VicheWeb.InboxController.read_inbox/2
    │ lib/viche_web/controllers/inbox_controller.ex:18-29
    │
    ▼
Viche.Agents.drain_inbox/1
    │ lib/viche/agents.ex:175-184
    │
    ├── Registry.lookup to verify agent exists
    │   lib/viche/agents.ex:222-227
    │
    └── AgentServer.drain_inbox/1 (GenServer.call :drain_inbox)
        │ lib/viche/agent_server.ex:49-52
        │
        └── Returns all messages, clears inbox atomically
            lib/viche/agent_server.ex:94-96
```

### Message Delivery Flow (with real-time push)
```
POST /messages/{agent_id} OR WebSocket "send_message"
    │
    ▼
Viche.Agents.send_message/1
    │ lib/viche/agents.ex:109-139
    │
    ├── Validate message type (task|result|ping)
    │   lib/viche/message.ex:19, 30-31
    │
    ├── Lookup agent in Registry
    │
    ├── Create %Viche.Message{} with "msg-" prefixed ID
    │   lib/viche/agents.ex:115-121
    │
    ├── AgentServer.receive_message/2 → appends to inbox
    │   lib/viche/agent_server.ex:88-91
    │
    └── VicheWeb.Endpoint.broadcast("agent:{id}", "new_message", payload)
        lib/viche/agents.ex:126-132
        (pushes to any connected WebSocket clients)
```

## Agent Struct Fields

| Field | Type | Description | Location |
|-------|------|-------------|----------|
| `id` | `String.t()` | 8-char hex ID | `lib/viche/agent.ex:10` |
| `name` | `String.t() \| nil` | Optional display name | `lib/viche/agent.ex:11` |
| `capabilities` | `[String.t()]` | List of capability strings | `lib/viche/agent.ex:12` |
| `description` | `String.t() \| nil` | Optional description | `lib/viche/agent.ex:13` |
| `inbox` | `list()` | List of `%Viche.Message{}` | `lib/viche/agent.ex:14` |
| `registered_at` | `DateTime.t()` | Registration timestamp | `lib/viche/agent.ex:15` |

## Message Struct Fields

| Field | Type | Description | Location |
|-------|------|-------------|----------|
| `id` | `String.t()` | "msg-" + 8-char hex | `lib/viche/message.ex:10` |
| `type` | `String.t()` | "task" \| "result" \| "ping" | `lib/viche/message.ex:11, 19` |
| `from` | `String.t()` | Sender agent ID | `lib/viche/message.ex:12` |
| `body` | `String.t()` | Message content | `lib/viche/message.ex:13` |
| `sent_at` | `DateTime.t()` | Send timestamp | `lib/viche/message.ex:14` |

## Related Components

### Registry Metadata
The Registry stores agent metadata alongside the PID for efficient discovery:
```elixir
meta = %{name: name, capabilities: capabilities, description: description}
via = {:via, Registry, {Viche.AgentRegistry, agent_id, meta}}
```
Location: `lib/viche/agent_server.ex:33-34`

### Discovery
Discovery queries the Registry directly without calling GenServers:
```elixir
Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
```
Location: `lib/viche/agents.ex:191-193`

### Channel Events (Client → Server)
| Event | Handler | Location |
|-------|---------|----------|
| `"discover"` | `handle_in/3` | `lib/viche_web/channels/agent_channel.ex:36-44` |
| `"send_message"` | `handle_in/3` | `lib/viche_web/channels/agent_channel.ex:46-54` |
| `"inspect_inbox"` | `handle_in/3` | `lib/viche_web/channels/agent_channel.ex:56-61` |
| `"drain_inbox"` | `handle_in/3` | `lib/viche_web/channels/agent_channel.ex:63-68` |

## Configuration & Runtime

### Socket Configuration
```elixir
socket "/agent/websocket", VicheWeb.AgentSocket,
  websocket: true,
  longpoll: false
```
Location: `lib/viche_web/endpoint.ex:18-20`

### Supervisor Strategy
```elixir
{DynamicSupervisor, name: Viche.AgentSupervisor, strategy: :one_for_one}
```
Location: `lib/viche/application.ex:16`

## Gaps Identified — Cleanup & Deregistration

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| **No terminate callback in AgentServer** | "terminate", "handle_info", ":DOWN" | `lib/viche/` |
| **No terminate callback in AgentChannel** | "terminate", "handle_info" | `lib/viche_web/channels/` |
| **No deregister/unregister function** | "deregister", "unregister", "cleanup" | `lib/viche/`, `lib/viche_web/` |
| **No TTL or heartbeat mechanism** | "TTL", "heartbeat", "timeout" | `lib/viche/`, `lib/viche_web/` |
| **No disconnect handling** | "disconnect", "terminate" | `lib/viche_web/channels/` |
| **No last_seen tracking** | "last_seen", "last_activity" | `lib/viche/` |

### Current State: What Happens on Disconnect

**WebSocket disconnect**: The Phoenix Channel process terminates, but:
- No `terminate/2` callback is defined in `VicheWeb.AgentChannel`
- The agent's GenServer process (`Viche.AgentServer`) continues running
- The agent remains in the Registry
- The agent's inbox is preserved

**Long polling silence**: No mechanism exists to detect or handle:
- Agents that stop polling
- Stale agents that haven't been accessed
- Orphaned agent processes

**Manual cleanup only**: Tests use `DynamicSupervisor.terminate_child/2` directly:
```elixir
DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
```
Locations:
- `test/viche_web/channels/agent_channel_test.exs:11`
- `test/viche/agents_test.exs:10`
- `test/viche_web/controllers/registry_controller_test.exs:89`

### SPEC.md References to Cleanup

| Reference | Location | Status |
|-----------|----------|--------|
| "dead agent cleanup" | `SPEC.md:348` | Not implemented |
| "optionally deregister" on shutdown | `SPEC.md:274` | Not implemented |
| "heartbeat or hook" for registration | `SPEC.md:445` | Not implemented |
| "ping" message type for liveness | `lib/viche/message.ex:19` | Type exists, no auto-handling |

## Evidence Index

### Code Files
- `lib/viche/agent.ex:1-19` — Agent struct definition
- `lib/viche/agents.ex:1-244` — Context module with all public API
- `lib/viche/agent_server.ex:1-102` — GenServer implementation
- `lib/viche/message.ex:1-32` — Message struct and valid types
- `lib/viche/application.ex:1-34` — Application supervision tree
- `lib/viche_web/channels/agent_socket.ex:1-26` — WebSocket connection handler
- `lib/viche_web/channels/agent_channel.ex:1-85` — Phoenix Channel implementation
- `lib/viche_web/controllers/inbox_controller.ex:1-46` — Long polling endpoint
- `lib/viche_web/controllers/registry_controller.ex:1-70` — Registration endpoint
- `lib/viche_web/endpoint.ex:18-20` — Socket configuration
- `lib/viche_web/router.ex:1-64` — Route definitions

### Test Files
- `test/viche_web/channels/agent_channel_test.exs:7-21` — Manual cleanup helper
- `test/viche/agents_test.exs:10` — terminate_child usage
- `test/viche_web/controllers/registry_controller_test.exs:89` — terminate_child usage

### Documentation
- `SPEC.md:274` — "optionally deregister" mention
- `SPEC.md:348` — "dead agent cleanup" mention
- `SPEC.md:445` — "heartbeat or hook" mention
- `specs/07-websockets.md:1-226` — WebSocket spec (no cleanup defined)

## Related Research

- `thoughts/research/2026-03-24-e2e-message-passing-claude-code.md` — E2E message flow research

---

## Handoff Inputs

**If planning needed** (for @prometheus):
- Scope: `Viche.AgentServer`, `VicheWeb.AgentChannel`, `Viche.Agents`
- Entry points: `lib/viche/agent_server.ex`, `lib/viche_web/channels/agent_channel.ex`
- Constraints: Agent processes are supervised by DynamicSupervisor; Registry auto-cleans on process exit
- Open questions:
  - Should WebSocket disconnect trigger immediate deregistration?
  - What TTL for long-polling agents?
  - Should "ping" messages reset TTL?
  - How to handle agents with pending inbox messages on deregistration?

**If implementation needed** (for @vulkanus):
- Test location: `test/viche_web/channels/agent_channel_test.exs`, `test/viche/agents_test.exs`
- Pattern to follow: Tests use `DynamicSupervisor.terminate_child/2` for cleanup
- Entry point: `lib/viche/agent_server.ex` (add terminate callback), `lib/viche_web/channels/agent_channel.ex` (add terminate callback)
