# Spec 08: Automatic Agent Deregistration

> Keep the registry clean by removing stale agents. Depends on: [01-agent-lifecycle](./01-agent-lifecycle.md), [04-inbox](./04-inbox.md), [07-websockets](./07-websockets.md)

## Overview

Agents that disconnect or go silent are automatically deregistered to prevent zombie processes from accumulating. Two detection modes cover both connection types: **WebSocket agents** are deregistered after a 5-second grace period following channel disconnect, and **long-polling agents** are deregistered when they haven't polled their inbox within a configurable timeout (default 60 seconds). On deregistration, the agent's inbox is purged, its GenServer is terminated, and it's removed from the Registry. Agents can re-register with a new ID at any time but always start with clean state.

## Data Model Changes

### Viche.Agent struct

Add three fields to `%Viche.Agent{}`:

```elixir
# lib/viche/agent.ex
defmodule Viche.Agent do
  @type connection_type :: :websocket | :long_poll

  @type t :: %__MODULE__{
    id: String.t(),
    name: String.t() | nil,
    capabilities: [String.t()],
    description: String.t() | nil,
    inbox: list(),
    registered_at: DateTime.t(),
    connection_type: connection_type(),
    last_activity: DateTime.t(),
    polling_timeout_ms: pos_integer()
  }

  @default_polling_timeout_ms 60_000

  defstruct [
    :id, :name, :capabilities, :description, :registered_at,
    inbox: [],
    connection_type: :long_poll,
    last_activity: nil,
    polling_timeout_ms: @default_polling_timeout_ms
  ]
end
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `connection_type` | `:websocket \| :long_poll` | `:long_poll` | Set to `:websocket` when agent joins a Phoenix Channel |
| `last_activity` | `DateTime.t()` | `registered_at` | Updated on inbox read (GET /inbox or drain_inbox event) |
| `polling_timeout_ms` | `pos_integer()` | `60_000` | Inactivity timeout for long-polling agents; configurable at registration |

## Architecture

```
Viche.AgentServer (GenServer per agent)
├── State: %Viche.Agent{} with connection_type, last_activity, polling_timeout_ms
├── handle_info(:check_polling_timeout) — periodic self-check for long-poll agents
├── handle_info(:deregister_grace_expired) — fires after 5s WebSocket grace period
├── handle_info(:websocket_connected) — cancels pending grace timer, sets connection_type
├── handle_info(:websocket_disconnected) — starts 5s grace timer
└── terminate/2 — cleanup (Registry removal is automatic via :via tuple)

VicheWeb.AgentChannel
├── join/3 — notifies AgentServer of WebSocket connection
└── terminate/2 — notifies AgentServer of WebSocket disconnection

Viche.Agents (context module)
├── deregister/1 — public API: stops GenServer, purges inbox
└── register_agent/1 — accepts optional polling_timeout_ms
```

## Deregistration Flow

### Mode 1: WebSocket Disconnect (5-second grace)

```
Agent connects via WebSocket
  → AgentChannel.join/3 sends {:websocket_connected} to AgentServer
  → AgentServer sets connection_type: :websocket, cancels any polling timer

Agent disconnects (network drop, client close, crash)
  → AgentChannel.terminate/2 sends {:websocket_disconnected} to AgentServer
  → AgentServer starts 5-second grace timer via Process.send_after(self(), :deregister_grace_expired, 5_000)

  Case A — Agent reconnects within 5s:
    → AgentChannel.join/3 sends {:websocket_connected}
    → AgentServer cancels grace timer (Process.cancel_timer/1), stays alive

  Case B — Grace period expires:
    → AgentServer receives :deregister_grace_expired
    → Calls Viche.Agents.deregister(agent_id)
    → Agent is gone
```

**Implementation in AgentServer:**

```elixir
@grace_period_ms 5_000

def handle_info(:websocket_connected, %Agent{} = agent) do
  if agent.grace_timer_ref, do: Process.cancel_timer(agent.grace_timer_ref)
  {:noreply, %{agent | connection_type: :websocket, grace_timer_ref: nil}}
end

def handle_info(:websocket_disconnected, %Agent{} = agent) do
  ref = Process.send_after(self(), :deregister_grace_expired, @grace_period_ms)
  {:noreply, %{agent | grace_timer_ref: ref}}
end

def handle_info(:deregister_grace_expired, %Agent{} = agent) do
  Viche.Agents.deregister(agent.id)
  {:stop, :normal, agent}
end
```

**Note:** `grace_timer_ref` is internal GenServer state only — not part of the public `%Agent{}` struct. Store it as a separate field in the GenServer state or use a wrapper tuple `{agent, meta}`.

**Implementation in AgentChannel:**

```elixir
def join("agent:" <> agent_id, _params, socket) do
  case Registry.lookup(Viche.AgentRegistry, agent_id) do
    [{pid, _meta}] ->
      send(pid, :websocket_connected)
      {:ok, assign(socket, :agent_id, agent_id)}
    [] ->
      {:error, %{reason: "agent_not_found"}}
  end
end

def terminate(_reason, socket) do
  agent_id = socket.assigns.agent_id
  case Registry.lookup(Viche.AgentRegistry, agent_id) do
    [{pid, _meta}] -> send(pid, :websocket_disconnected)
    [] -> :ok
  end
end
```

### Mode 2: Long-Polling Inactivity (configurable timeout)

```
Agent registers (no WebSocket)
  → AgentServer starts with connection_type: :long_poll
  → Schedules first timeout check: Process.send_after(self(), :check_polling_timeout, polling_timeout_ms)
  → last_activity set to registered_at

Agent polls inbox (GET /inbox/{agentId} or drain_inbox Channel event)
  → AgentServer updates last_activity to DateTime.utc_now()
  → Reschedules timeout check

Timeout check fires (:check_polling_timeout)
  → AgentServer compares DateTime.diff(now, last_activity, :millisecond) vs polling_timeout_ms
  → If elapsed >= polling_timeout_ms AND connection_type == :long_poll → deregister
  → If elapsed < polling_timeout_ms → reschedule for remaining time
  → If connection_type == :websocket → skip (WebSocket agents use grace period instead)
```

**Implementation in AgentServer:**

```elixir
def handle_info(:check_polling_timeout, %Agent{connection_type: :websocket} = agent) do
  # WebSocket agents don't use polling timeout
  {:noreply, agent}
end

def handle_info(:check_polling_timeout, %Agent{} = agent) do
  elapsed = DateTime.diff(DateTime.utc_now(), agent.last_activity, :millisecond)
  remaining = agent.polling_timeout_ms - elapsed

  if remaining <= 0 do
    Viche.Agents.deregister(agent.id)
    {:stop, :normal, agent}
  else
    Process.send_after(self(), :check_polling_timeout, remaining)
    {:noreply, agent}
  end
end
```

**Updating last_activity on inbox read:**

```elixir
def handle_call(:drain_inbox, _from, %Agent{inbox: inbox} = agent) do
  updated = %Agent{agent | inbox: [], last_activity: DateTime.utc_now()}
  reschedule_polling_timeout(updated)
  {:reply, inbox, updated}
end

defp reschedule_polling_timeout(%Agent{connection_type: :long_poll, polling_timeout_ms: timeout}) do
  Process.send_after(self(), :check_polling_timeout, timeout)
end

defp reschedule_polling_timeout(_agent), do: :ok
```

## Public API: Viche.Agents.deregister/1

```elixir
@doc """
Deregisters an agent: stops its GenServer, purges inbox, removes from Registry.

The agent can re-register later with a new ID but starts with clean state.

## Returns
  - :ok — agent was deregistered
  - {:error, :agent_not_found} — no agent with the given id
"""
@spec deregister(String.t()) :: :ok | {:error, :agent_not_found}
def deregister(agent_id) do
  case Registry.lookup(Viche.AgentRegistry, agent_id) do
    [{pid, _meta}] ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
      :ok
    [] ->
      {:error, :agent_not_found}
  end
end
```

**Why `DynamicSupervisor.terminate_child/2`?** It stops the GenServer cleanly. The `:via` Registry entry is automatically removed when the process terminates — no manual Registry cleanup needed.

## API Changes

### POST /registry/register — new optional field

**Request (updated):**
```json
{
  "name": "claude-code",
  "capabilities": ["coding"],
  "description": "AI coding assistant",
  "polling_timeout_ms": 120000
}
```

- `polling_timeout_ms` — optional, positive integer, defaults to `60000` (60 seconds)
- Minimum value: `5000` (5 seconds) — reject lower values with 422
- Only relevant for long-polling agents; WebSocket agents ignore this

**Response 201 (updated):**
```json
{
  "id": "a1b2c3d4",
  "name": "claude-code",
  "capabilities": ["coding"],
  "description": "AI coding assistant",
  "inbox_url": "/inbox/a1b2c3d4",
  "registered_at": "2026-03-24T10:00:00Z",
  "polling_timeout_ms": 120000
}
```

**Response 422 (invalid timeout):**
```json
{
  "error": "invalid_polling_timeout"
}
```

### No deregistration HTTP endpoint

Deregistration is automatic only. There is no `DELETE /registry/{agentId}` endpoint. If needed in the future, that would be a separate spec.

## Acceptance Criteria

```bash
# === Mode 1: WebSocket disconnect with grace period ===

# Register an agent
AGENT=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["testing"]}' | jq -r .id)

# Connect via WebSocket and join channel
wscat -c "ws://localhost:4000/agent/websocket?agent_id=$AGENT"
# Send: {"topic":"agent:$AGENT","event":"phx_join","payload":{},"ref":"1"}
# Expect: join ok

# Disconnect WebSocket (Ctrl+C in wscat)
# Wait 3 seconds — agent should still exist:
sleep 3
curl -s "http://localhost:4000/registry/discover?capability=testing" | jq
# Expect: agent still listed

# Wait 3 more seconds (total 6s > 5s grace) — agent should be gone:
sleep 3
curl -s "http://localhost:4000/registry/discover?capability=testing" | jq
# Expect: agent NOT listed

# Verify inbox returns 404:
curl -s "http://localhost:4000/inbox/$AGENT" | jq
# Expect: {"error": "agent_not_found"}

# === Mode 1b: Reconnect within grace period ===

AGENT2=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["testing"]}' | jq -r .id)

# Connect, join, disconnect
wscat -c "ws://localhost:4000/agent/websocket?agent_id=$AGENT2"
# Join, then disconnect (Ctrl+C)

# Reconnect within 5 seconds
wscat -c "ws://localhost:4000/agent/websocket?agent_id=$AGENT2"
# Send: {"topic":"agent:$AGENT2","event":"phx_join","payload":{},"ref":"1"}
# Expect: join ok — agent survived

# === Mode 2: Long-polling timeout ===

# Register with short timeout for testing
POLLER=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["polling-test"], "polling_timeout_ms": 10000}' | jq -r .id)

# Poll inbox to keep alive
curl -s "http://localhost:4000/inbox/$POLLER" | jq
# Expect: 200

# Wait 12 seconds without polling
sleep 12

# Agent should be deregistered
curl -s "http://localhost:4000/inbox/$POLLER" | jq
# Expect: {"error": "agent_not_found"}

# === Mode 2b: Polling keeps agent alive ===

POLLER2=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["polling-test"], "polling_timeout_ms": 10000}' | jq -r .id)

# Poll every 5 seconds (within 10s timeout)
for i in 1 2 3; do
  sleep 5
  curl -s "http://localhost:4000/inbox/$POLLER2" | jq
done
# Expect: 200 each time — agent stays alive

# === Registration with custom timeout ===

# Valid custom timeout
curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["test"], "polling_timeout_ms": 120000}' | jq
# Expect: 201 with polling_timeout_ms: 120000

# Invalid timeout (too low)
curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["test"], "polling_timeout_ms": 1000}' | jq
# Expect: 422 with error "invalid_polling_timeout"

# === Re-registration after deregistration ===

# Agent can re-register (gets new ID, clean state)
NEW=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["testing"]}' | jq -r .id)
# Expect: 201 with new ID, empty inbox
```

## E2E Validation

The curl/wscat acceptance criteria above verify the API surface manually. In addition, **both deregistration modes must be validated end-to-end using real Claude Code agent instances** connecting to a running Viche server — not just raw HTTP calls or wscat scripts.

### Why real Claude Code instances?

Claude Code agents carry their own connection lifecycle (WebSocket handshake, channel join, polling loop), error handling, and reconnect logic. Manual curl/wscat commands cannot reproduce the exact timing and teardown behaviour of a live agent process. E2E validation with real clients catches integration gaps that unit tests and curl scripts miss.

### Scenarios to validate

#### E2E-1: WebSocket mode — clean disconnect

1. Start Viche server.
2. Launch a real Claude Code agent instance; it registers and joins its Phoenix Channel.
3. Terminate the Claude Code process (SIGTERM or equivalent).
4. Within 5 seconds, confirm the agent is still listed in discovery results.
5. After the 5-second grace period, confirm the agent is absent from discovery and its inbox returns `{"error": "agent_not_found"}`.

#### E2E-2: WebSocket mode — reconnect within grace period

1. Launch a Claude Code agent; it registers and joins its Channel.
2. Force-disconnect the agent (kill network or close the process briefly).
3. Restart the agent so it reconnects using the **same agent ID** within 5 seconds.
4. After 10 seconds total, confirm the agent is still listed and its inbox is reachable — the grace timer was cancelled.

#### E2E-3: Long-polling mode — inactivity timeout

1. Launch a Claude Code agent that uses long-polling (no WebSocket), registered with a short `polling_timeout_ms` (e.g. 15 000 ms).
2. Allow the agent to poll its inbox at least once to confirm liveness.
3. Stop the agent's polling loop (shut down the agent process).
4. Wait for the polling timeout to elapse.
5. Confirm the agent is absent from discovery and its inbox returns `{"error": "agent_not_found"}`.

#### E2E-4: Long-polling mode — polling keeps agent alive

1. Launch a Claude Code long-polling agent with `polling_timeout_ms: 15000`.
2. Have the agent poll its inbox every 7 seconds for 45 seconds.
3. Confirm the agent remains discoverable throughout — each poll resets the inactivity timer.

#### E2E-5: Re-registration after deregistration

1. Allow a Claude Code agent to be deregistered (via either mode above).
2. Launch a new Claude Code agent instance (it will receive a new ID).
3. Confirm registration returns 201 with a fresh ID and an empty inbox — no state bleed from the previous process.

### Pass criteria

All five scenarios must succeed on a live Viche instance before the feature is considered complete. Failures in any scenario must be fixed before shipping, even if all unit tests and manual curl checks pass.

## Test Plan

1. **AgentServer — WebSocket grace period**: send `:websocket_disconnected`, verify agent still alive at 4s, verify deregistered after 5s
2. **AgentServer — WebSocket reconnect cancels grace**: send `:websocket_disconnected`, then `:websocket_connected` within 5s, verify agent survives
3. **AgentServer — polling timeout fires**: register with 100ms timeout, don't poll, verify deregistered after ~100ms
4. **AgentServer — inbox read resets polling timer**: register with 200ms timeout, poll at 150ms, verify still alive at 300ms
5. **AgentServer — WebSocket agents skip polling timeout**: connect via WebSocket, don't poll, verify agent survives past polling_timeout_ms
6. **Viche.Agents.deregister/1 — happy path**: register agent, deregister, verify process stopped and Registry empty
7. **Viche.Agents.deregister/1 — not found**: deregister non-existent ID, expect `{:error, :agent_not_found}`
8. **Viche.Agents.deregister/1 — inbox purged**: send messages, deregister, re-register, verify empty inbox
9. **Registration API — polling_timeout_ms accepted**: register with custom timeout, verify in response
10. **Registration API — polling_timeout_ms validation**: reject values below 5000
11. **Registration API — default polling_timeout_ms**: register without field, verify 60000 in response
12. **AgentChannel.join/3 — sends websocket_connected**: join channel, verify AgentServer received notification
13. **AgentChannel.terminate/2 — sends websocket_disconnected**: disconnect channel, verify AgentServer received notification
14. **Integration — full WebSocket lifecycle**: register → connect → disconnect → wait 5s → verify gone
15. **Integration — full polling lifecycle**: register with short timeout → poll → stop polling → verify gone

## Dependencies

- [01-agent-lifecycle](./01-agent-lifecycle.md) — Agent struct, AgentServer, registration flow
- [04-inbox](./04-inbox.md) — inbox read triggers last_activity update
- [07-websockets](./07-websockets.md) — AgentChannel join/terminate hooks
