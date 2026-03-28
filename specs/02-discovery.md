# Spec 02: Agent Discovery

> Find agents by capability or name. Depends on: [01-agent-lifecycle](./01-agent-lifecycle.md)

## Overview

Agents discover each other through the registry. Query by a single capability or by name. Returns matching agent cards (without inbox contents).

## API Contract

### GET /registry/discover

Query parameters (at least one required):
- `capability` — string, find agents that have this capability
- `name` — string, find agents with this exact name

**Example: by capability**
```
GET /registry/discover?capability=coding
```

**Response 200:**
```json
{
  "agents": [
    {
      "id": "a1b2c3d4",
      "name": "claude-code",
      "capabilities": ["coding"],
      "description": "AI coding assistant"
    }
  ]
}
```

**Example: by name**
```
GET /registry/discover?name=claude-code
```

**Response 200:**
```json
{
  "agents": [
    {
      "id": "a1b2c3d4",
      "name": "claude-code",
      "capabilities": ["coding"],
      "description": "AI coding assistant"
    }
  ]
}
```

**No query params → 400:**
```json
{
  "error": "query_required",
  "message": "Provide ?capability= or ?name= parameter"
}
```

**No matches → 200 with empty list:**
```json
{
  "agents": []
}
```

### Wildcard Discovery

Pass `"*"` as `capability` or `name` to list all registered agents.

**Example: list all agents**
```
GET /registry/discover?capability=*
```

**Response 200:**
```json
{
  "agents": [
    {
      "id": "a1b2c3d4",
      "name": "claude-code",
      "capabilities": ["coding"],
      "description": "AI coding assistant"
    },
    {
      "id": "e5f6g7h8",
      "name": "researcher",
      "capabilities": ["research"],
      "description": "Research agent"
    }
  ]
}
```

**Design note:** Wildcard returns ALL agents regardless of capabilities or name. This is intentional for the current stage (trusted networks, no multi-tenancy). When namespaces/multi-tenancy are added, wildcard will be scoped to the caller's namespace.

## Implementation Approach

Use Elixir Registry for discovery. Two strategies:

**Option A: Registry.select/2 with match specs** (preferred for capability search)
```elixir
# In Viche.AgentServer, register with metadata value:
Registry.register(Viche.AgentRegistry, agent_id, %{
  name: name,
  capabilities: capabilities,
  description: description
})

# Discovery: select all, filter in Elixir
Registry.select(Viche.AgentRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
|> Enum.filter(fn {_id, meta} -> capability in meta.capabilities end)
```

**Option B: Iterate via GenServer calls** (slower, avoids coupling to Registry internals)

Recommend Option A — it's idiomatic and efficient for hackathon scale.

## Acceptance Criteria

```bash
# Setup: register two agents
A=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"agent-a","capabilities":["testing"]}' | jq -r .id)

B=$(curl -s -X POST http://localhost:4000/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"agent-b","capabilities":["coding"]}' | jq -r .id)

# Discover by capability
curl -s "http://localhost:4000/registry/discover?capability=coding" | jq
# Expect: only agent-b

# Discover by name
curl -s "http://localhost:4000/registry/discover?name=agent-a" | jq
# Expect: only agent-a

# No matches
curl -s "http://localhost:4000/registry/discover?capability=nonexistent" | jq
# Expect: {"agents": []}

# No query params → 400
curl -s "http://localhost:4000/registry/discover" | jq
# Expect: 400 error

# Discover all agents (wildcard)
curl -s "http://localhost:4000/registry/discover?capability=*" | jq
# Expect: both agent-a and agent-b

curl -s "http://localhost:4000/registry/discover?name=*" | jq
# Expect: both agent-a and agent-b

# Wildcard with no agents registered → empty list
curl -s "http://localhost:4000/registry/discover?capability=*" | jq
# Expect: {"agents": []}
```

## Test Plan

1. Discover by capability — single match, multiple matches, no matches
2. Discover by name — exact match, no match
3. Missing query params — returns 400
4. Agent registered then discovered — integration test
5. Wildcard discovery — capability=* returns all agents
6. Wildcard discovery — name=* returns all agents
7. Wildcard with no agents — returns empty list
8. Non-string capability/name via WebSocket — returns error (not crash)

## Dependencies

- [01-agent-lifecycle](./01-agent-lifecycle.md) — agents must exist to be discovered
