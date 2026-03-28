---
date: 2026-03-24T12:00:00+02:00
researcher: mnemosyne
git_commit: HEAD
branch: main
repository: viche
topic: "Research Viche codebase for spec 08 (automatic agent deregistration)"
scope: Core domain modules, OTP layer, web layer, tests
query_type: map
tags: [research, agent, deregistration, spec-08, genserver, channel]
status: complete
confidence: high
sources_scanned:
  files: 15
  thoughts_docs: 2
---

# Research: Viche Codebase for Spec 08 (Automatic Agent Deregistration)

**Date**: 2026-03-24
**Commit**: HEAD
**Branch**: main
**Confidence**: high - All key modules read in full, comprehensive test coverage exists

## Query
Research the current Viche codebase to understand the existing implementation of: Agent struct, AgentServer, AgentChannel, Agents context module, RegistryController, InboxController, and any existing tests — in preparation for implementing spec 08 (automatic agent deregistration).

## Summary
The Viche codebase has a clean OTP-based architecture with agents managed by DynamicSupervisor, registered in Elixir Registry, and served via GenServer processes. The Agent struct has 6 fields (id, name, capabilities, description, inbox, registered_at). AgentServer holds the Agent struct as state with no additional meta-state. AgentChannel has join/3 but no terminate/2 callback. There is NO existing deregister functionality — agents persist until the application restarts.

## Key Entry Points

| File | Symbol | Purpose |
|------|--------|---------|
| `lib/viche/agent.ex:1-19` | `Viche.Agent` | Agent struct definition (6 fields) |
| `lib/viche/agent_server.ex:1-102` | `Viche.AgentServer` | GenServer per agent, state = `%Agent{}` |
| `lib/viche/agents.ex:1-244` | `Viche.Agents` | Context module (public API) |
| `lib/viche_web/channels/agent_channel.ex:1-85` | `VicheWeb.AgentChannel` | Phoenix Channel for real-time messaging |
| `lib/viche_web/controllers/registry_controller.ex:1-70` | `VicheWeb.RegistryController` | Registration + discovery endpoints |
| `lib/viche_web/controllers/inbox_controller.ex:1-46` | `VicheWeb.InboxController` | Inbox read (drain) endpoint |
| `lib/viche/application.ex:10-18` | `Viche.Application.start/2` | Supervision tree setup |

## Architecture & Flow

### Process Tree (from application.ex:10-18)
```
Application
├── VicheWeb.Telemetry
├── Viche.Repo
├── DNSCluster
├── Phoenix.PubSub (name: Viche.PubSub)
├── Registry (keys: :unique, name: Viche.AgentRegistry)
├── DynamicSupervisor (name: Viche.AgentSupervisor, strategy: :one_for_one)
└── VicheWeb.Endpoint
```

### Agent Registration Flow
```
POST /registry/register
    → RegistryController.register/2 (registry_controller.ex:13-38)
    → Agents.register_agent/1 (agents.ex:55-69)
    → DynamicSupervisor.start_child(Viche.AgentSupervisor, child_spec)
    → AgentServer.start_link/1 (agent_server.ex:27-37)
    → Registry.register via {:via, Registry, {Viche.AgentRegistry, agent_id, meta}}
    → AgentServer.init/1 creates %Agent{} state (agent_server.ex:64-79)
```

### WebSocket Connection Flow
```
WebSocket connect
    → AgentSocket.connect/3 (agent_socket.ex:17-22)
    → Assigns agent_id to socket
    
Channel join "agent:{agent_id}"
    → AgentChannel.join/3 (agent_channel.ex:26-34)
    → Registry.lookup to verify agent exists
    → {:ok, socket} with agent_id assigned
```

### Inbox Read Flow
```
GET /inbox/:agent_id
    → InboxController.read_inbox/2 (inbox_controller.ex:18-29)
    → Agents.drain_inbox/1 (agents.ex:175-184)
    → AgentServer.drain_inbox/1 (agent_server.ex:50-52)
    → GenServer.call(:drain_inbox) (agent_server.ex:94-96)
    → Returns messages, clears inbox atomically
```

## Current Struct Definitions

### %Viche.Agent{} (agent.ex:9-18)
```elixir
@type t :: %__MODULE__{
  id: String.t(),
  name: String.t() | nil,
  capabilities: [String.t()],
  description: String.t() | nil,
  inbox: list(),
  registered_at: DateTime.t()
}

defstruct [:id, :name, :capabilities, :description, :registered_at, inbox: []]
```

### AgentServer State (agent_server.ex:70-77)
The GenServer state is exactly `%Viche.Agent{}` — no wrapper, no additional meta-state:
```elixir
def init(opts) do
  agent = %Agent{
    id: agent_id,
    name: name,
    capabilities: capabilities,
    description: description,
    inbox: [],
    registered_at: DateTime.utc_now()
  }
  {:ok, agent}
end
```

### Registry Metadata (agent_server.ex:33-34)
Stored as Registry value for efficient discovery:
```elixir
meta = %{name: name, capabilities: capabilities, description: description}
via = {:via, Registry, {Viche.AgentRegistry, agent_id, meta}}
```

## AgentChannel Implementation Details

### join/3 (agent_channel.ex:26-34)
```elixir
def join("agent:" <> agent_id, _params, socket) do
  case Registry.lookup(Viche.AgentRegistry, agent_id) do
    [{_pid, _meta}] ->
      {:ok, assign(socket, :agent_id, agent_id)}
    [] ->
      {:error, %{reason: "agent_not_found"}}
  end
end
```
- Verifies agent exists via Registry lookup
- Assigns agent_id to socket
- Does NOT notify AgentServer of connection

### terminate/2 — NOT IMPLEMENTED
- No terminate/2 callback exists in AgentChannel
- Channel disconnection is not tracked

## Agents Context API (agents.ex)

| Function | Signature | Location |
|----------|-----------|----------|
| `list_agents/0` | `() -> [agent_info()]` | agents.ex:35-39 |
| `register_agent/1` | `(map()) -> {:ok, Agent.t()} \| {:error, :capabilities_required}` | agents.ex:55-71 |
| `discover/1` | `(map()) -> {:ok, [agent_info()]} \| {:error, :query_required}` | agents.ex:85-93 |
| `send_message/1` | `(map()) -> {:ok, String.t()} \| {:error, atom()}` | agents.ex:109-141 |
| `inspect_inbox/1` | `(String.t()) -> {:ok, [Message.t()]} \| {:error, :agent_not_found}` | agents.ex:154-163 |
| `drain_inbox/1` | `(String.t()) -> {:ok, [Message.t()]} \| {:error, :agent_not_found}` | agents.ex:175-184 |

**Missing**: No `deregister/1` function exists.

## RegistryController Implementation (registry_controller.ex)

### register/2 (lines 13-38)
- Accepts: `capabilities` (required), `name` (optional), `description` (optional)
- Does NOT accept: `polling_timeout_ms` or `connection_type`
- Returns: `{id, name, capabilities, description, inbox_url, registered_at}`

### discover/2 (lines 40-56)
- Query by `?capability=` or `?name=`
- Returns lightweight agent info (no inbox, no registered_at)

## InboxController Implementation (inbox_controller.ex)

### read_inbox/2 (lines 18-29)
- Calls `Agents.drain_inbox/1` — consumes messages
- Does NOT update any `last_activity` timestamp
- Returns serialized messages with `{id, type, from, body, sent_at}`

## Router Configuration (router.ex)

| Method | Path | Controller | Action |
|--------|------|------------|--------|
| POST | `/registry/register` | RegistryController | :register |
| GET | `/registry/discover` | RegistryController | :discover |
| POST | `/messages/:agent_id` | MessageController | :send_message |
| GET | `/inbox/:agent_id` | InboxController | :read_inbox |
| GET | `/.well-known/agent-registry` | WellKnownController | :agent_registry |

## Test Coverage

| Test File | Coverage |
|-----------|----------|
| `test/viche/agents_test.exs` (297 lines) | list_agents, register_agent, discover, send_message, inspect_inbox, drain_inbox |
| `test/viche/agent_server_test.exs` (96 lines) | start_link, registry registration, metadata storage, get_state |
| `test/viche_web/channels/agent_channel_test.exs` (197 lines) | join, discover, send_message, inspect_inbox, drain_inbox, real-time push |
| `test/viche_web/controllers/registry_controller_test.exs` (187 lines) | register, discover |
| `test/viche_web/controllers/inbox_controller_test.exs` (159 lines) | read_inbox, consume semantics, round-trip |

### Test Patterns to Follow
- Tests use `clear_all_agents/0` helper that terminates all children and syncs with Registry (agents_test.exs:6-20, agent_channel_test.exs:7-21)
- AgentServer tests use `unique_id/0` helper (agent_server_test.exs:6-8)
- Channel tests use `VicheWeb.ChannelCase` with `subscribe_and_join/3`
- Controller tests use `VicheWeb.ConnCase`

## Gaps Identified

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| No `deregister/1` function | "deregister", "unregister", "terminate" | `lib/` |
| No `connection_type` field on Agent | "connection_type", "websocket", "polling" | `lib/viche/agent.ex` |
| No `last_activity` field on Agent | "last_activity", "activity", "timestamp" | `lib/viche/agent.ex` |
| No `polling_timeout_ms` field on Agent | "polling_timeout", "timeout" | `lib/viche/agent.ex` |
| No `grace_timer_ref` in AgentServer state | "grace", "timer", "ref" | `lib/viche/agent_server.ex` |
| No `terminate/2` in AgentChannel | "terminate" | `lib/viche_web/channels/agent_channel.ex` |
| No AgentServer notification on channel join/leave | "notify", "connected", "disconnected" | `lib/viche_web/channels/` |
| InboxController does not update last_activity | "last_activity", "touch" | `lib/viche_web/controllers/inbox_controller.ex` |
| RegistryController does not accept polling_timeout_ms | "polling_timeout" | `lib/viche_web/controllers/registry_controller.ex` |

## Evidence Index

### Code Files
- `lib/viche/agent.ex:1-19` — Agent struct definition
- `lib/viche/agent_server.ex:1-102` — GenServer implementation
- `lib/viche/agents.ex:1-244` — Context module with public API
- `lib/viche_web/channels/agent_channel.ex:1-85` — Phoenix Channel
- `lib/viche_web/channels/agent_socket.ex:1-26` — Phoenix Socket
- `lib/viche_web/controllers/registry_controller.ex:1-70` — Registration controller
- `lib/viche_web/controllers/inbox_controller.ex:1-46` — Inbox controller
- `lib/viche_web/router.ex:1-64` — Router configuration
- `lib/viche/application.ex:1-34` — Application supervision tree
- `lib/viche/message.ex:1-32` — Message struct

### Test Files
- `test/viche/agents_test.exs:1-297` — Agents context tests
- `test/viche/agent_server_test.exs:1-96` — AgentServer tests
- `test/viche_web/channels/agent_channel_test.exs:1-197` — Channel tests
- `test/viche_web/controllers/registry_controller_test.exs:1-187` — Registry controller tests
- `test/viche_web/controllers/inbox_controller_test.exs:1-159` — Inbox controller tests

## Related Research
- `thoughts/research/2026-03-24-agent-lifecycle.md` — May contain related lifecycle information

---

## Handoff Inputs

**If implementation needed** (for @vulkanus):

**Scope**: Agent struct, AgentServer, AgentChannel, Agents context, RegistryController, InboxController

**Entry points**:
- `lib/viche/agent.ex:18` — Add 3 new fields to defstruct
- `lib/viche/agent_server.ex:64-79` — Modify init/1 to accept new fields, add grace_timer_ref to state
- `lib/viche/agent_server.ex` — Add handle_info for :grace_timeout, handle_cast for :ws_connected/:ws_disconnected
- `lib/viche/agents.ex` — Add deregister/1 function, add notify_ws_connected/1, notify_ws_disconnected/1
- `lib/viche_web/channels/agent_channel.ex:26-34` — Modify join/3 to notify AgentServer
- `lib/viche_web/channels/agent_channel.ex` — Add terminate/2 callback to notify AgentServer
- `lib/viche_web/controllers/registry_controller.ex:13-38` — Accept polling_timeout_ms param
- `lib/viche_web/controllers/inbox_controller.ex:18-29` — Update last_activity on read

**Test locations**:
- `test/viche/agents_test.exs` — Add deregister tests
- `test/viche/agent_server_test.exs` — Add grace timer tests, ws notification tests
- `test/viche_web/channels/agent_channel_test.exs` — Add terminate tests
- `test/viche_web/controllers/registry_controller_test.exs` — Add polling_timeout_ms tests
- `test/viche_web/controllers/inbox_controller_test.exs` — Add last_activity update tests

**Patterns to follow**:
- Test cleanup: Use `clear_all_agents/0` pattern from agents_test.exs:6-20
- GenServer state: Keep %Agent{} as primary state, wrap with tuple for meta-state `{%Agent{}, grace_timer_ref}`
- Registry via-tuple: `{:via, Registry, {Viche.AgentRegistry, agent_id}}`
- Channel test setup: Use `subscribe_and_join/3` pattern from agent_channel_test.exs:31-34

**Constraints found**:
- Agent IDs are 8-character hex strings (agents.ex:231)
- Message IDs use "msg-" prefix (agents.ex:241-242)
- Registry stores metadata as value for efficient discovery (agent_server.ex:33-34)
- DynamicSupervisor uses :one_for_one strategy (application.ex:16)

**Open questions**:
- Should deregister/1 be synchronous (GenServer.call) or async (GenServer.cast)?
- Should grace_timer_ref be part of Agent struct or separate tuple state?
- How to handle messages sent to agent during grace period?
