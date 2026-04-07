---
date: 2026-04-07T12:30:00+02:00
researcher: mnemosyne
git_commit: HEAD
branch: main
repository: viche
topic: "Why viche_discover doesn't find agents in a specific registry token"
scope: opencode-plugin-viche, lib/viche_web/channels/agent_channel.ex, lib/viche/agents.ex
query_type: explain
tags: [research, discovery, registry, opencode-plugin]
status: complete
confidence: high
sources_scanned:
  files: 12
  thoughts_docs: 2
---

# Research: Registry-Scoped Discovery Failure in OpenCode Plugin

**Date**: 2026-04-07T12:30:00+02:00
**Commit**: HEAD (post-PR #66 merge)
**Branch**: main
**Confidence**: High — root cause identified with file:line citations

## Query
Why doesn't the `viche_discover` tool in the OpenCode plugin find other agents in a specific registry token, and why doesn't the agent calling discover see itself in that registry?

## Summary

The discovery failure has **two root causes**:

1. **Channel mismatch**: The OpenCode plugin pushes `"discover"` on the `agent:register` channel (line 246 of tools.ts), but the server's `handle_discover` function only scopes discovery to a registry when the socket has a `registry_token` assign — which is only set when joined to a `registry:{token}` channel (agent_channel.ex:76). Pushing discover on `agent:register` with a `registry` payload is **silently ignored** — the server falls back to global discovery.

2. **Registry membership guard**: Even if the discover were pushed on the correct `registry:{token}` channel, the server's `ensure_registry_membership` function (agent_channel.ex:255-263) checks if the agent is a member of that registry. If the agent is NOT in the registry (i.e., the token is not in the agent's `registries` list), it returns `{:error, :not_in_registry}` which causes `handle_discover` to return an **empty agents list** (line 247).

**PR #66 did NOT break this flow** — it actually introduced the registry membership guard as a security improvement. The underlying issue is that there is **no way to dynamically join a registry after registration**.

## Key Entry Points

| File | Symbol | Purpose |
|------|--------|---------|
| `channel/opencode-plugin-viche/tools.ts:245-252` | `viche_discover.execute` | Pushes discover on `sessionState.channel` (which is `agent:register`) |
| `lib/viche_web/channels/agent_channel.ex:95-97` | `handle_in("discover", ...)` | Routes to `handle_discover` |
| `lib/viche_web/channels/agent_channel.ex:231-253` | `handle_discover/2` | Calls `ensure_registry_membership` then `build_discover_query` |
| `lib/viche_web/channels/agent_channel.ex:255-263` | `ensure_registry_membership/1` | Returns `:ok` if no registry_token, or checks membership |
| `lib/viche_web/channels/agent_channel.ex:212-217` | `build_discover_query/2` | Only adds registry to query if `socket.assigns.registry_token` exists |
| `lib/viche/agents.ex:397-406` | `discover/1` | Core discovery logic, defaults to `"global"` registry |

## Architecture & Flow

### Data Flow: viche_discover Tool Invocation

```
OpenCode Plugin                          Server (AgentChannel)                    Server (Agents)
─────────────────                        ────────────────────                     ───────────────
tools.ts:245-252                         agent_channel.ex:95-97                   agents.ex:397-406
                                         
1. User calls viche_discover             
   with token="ff271694-..."             
                                         
2. pushWithAck(                          
     sessionState.channel,  ← agent:register channel
     "discover",                         
     { capability, registry }            
   )                                     
                                         
                                         3. handle_in("discover", %{"capability" => cap}, socket)
                                            → handle_discover(%{capability: cap}, socket)
                                         
                                         4. ensure_registry_membership(socket)
                                            socket.assigns.registry_token = nil  ← NOT SET!
                                            → returns :ok (no membership check)
                                         
                                         5. build_discover_query(%{capability: cap}, socket)
                                            socket.assigns.registry_token = nil
                                            → returns %{capability: cap}  ← registry IGNORED!
                                         
                                                                                  6. Agents.discover(%{capability: cap})
                                                                                     registry = "global" (default)
                                                                                     → returns agents in "global"
                                         
7. Receives agents from "global"         
   (not the requested registry)          
```

### The Registry Parameter Is Ignored

The server's `handle_in("discover", ...)` at line 95-97 only extracts `capability` from the payload:

```elixir
# agent_channel.ex:95-97
def handle_in("discover", %{"capability" => cap}, socket) do
  handle_discover(%{capability: cap}, socket)
end
```

The `registry` key in the payload is **never extracted**. The registry is only determined by `socket.assigns.registry_token`, which is set during `join("registry:" <> token, ...)` at line 76.

### Why the Agent Doesn't See Itself

If the agent is registered with `registries: ["5e1bb7df-cd22-4f2b-99a6-db7781c2e360"]` but tries to discover in `"ff271694-202f-4600-be93-746b8a60a4af"`:

1. The agent is NOT a member of `ff271694-...`
2. If the agent tried to join `registry:ff271694-...` channel, `authorize_registry_join` would return `{:error, :not_in_registry}` (agents.ex:236-248)
3. Even if the channel join succeeded (bug), `ensure_registry_membership` would return `{:error, :not_in_registry}` and discovery would return empty list

## Related Components

### What Tools Exist vs What's Needed

| Tool | Exists? | Location | Notes |
|------|---------|----------|-------|
| `viche_discover` | ✅ | tools.ts:209-268 | Works for global, broken for private registries |
| `viche_send` | ✅ | tools.ts:272-316 | Cross-registry messaging works |
| `viche_reply` | ✅ | tools.ts:320-360 | Works |
| `viche_deregister` | ✅ | tools.ts:364-414 | Can leave registries, but cannot join new ones |
| `viche_join_registry` | ❌ | N/A | **MISSING** — planned in thoughts/tasks/registry-management/plan.md |
| `viche_leave_registry` | ❌ | N/A | **MISSING** — planned (same plan) |
| `viche_list_my_registries` | ❌ | N/A | **MISSING** — no plan exists |

### Server-Side Missing Functionality

| Function | Exists? | Location | Notes |
|----------|---------|----------|-------|
| `Agents.join_registry/2` | ❌ | N/A | Planned but not implemented |
| `Agents.leave_registry/2` | ❌ | N/A | Planned but not implemented |
| `handle_in("join_registry", ...)` | ❌ | N/A | Planned but not implemented |
| `handle_in("leave_registry", ...)` | ❌ | N/A | Planned but not implemented |

## Configuration & Runtime

### OpenCode Plugin Config (`.opencode/viche.json`)

```json
{
  "registries": ["5e1bb7df-cd22-4f2b-99a6-db7781c2e360"]
}
```

This sets the agent's registry membership at registration time. The agent can only discover within registries it belongs to.

### Service Layer Registry Channel Joins

The OpenCode plugin DOES join registry channels after registration (service.ts:165-175):

```typescript
for (const token of config.registries ?? []) {
  const registryChannel = socket.channel(`registry:${token}`, {});
  registryChannels.push(registryChannel);
  registryChannel.join()...
}
```

But these channels are stored in `sessionState.registryChannels` and **never used for discovery**. The `viche_discover` tool always pushes on `sessionState.channel` (the `agent:register` channel).

## Historical Context

| Source | Date | Key Insight |
|--------|------|-------------|
| `thoughts/tasks/registry-management/plan.md` | Recent | Full plan for `join_registry/2` and `leave_registry/2` exists but is NOT implemented |
| PR #66 (merged 2026-04-07) | 2026-04-07 | Added `ensure_registry_membership` guard — intentional security improvement, not a regression |

**PR #66 Review Item (from joeldevelops)**:
> "viche_discover in opencode pushes discover on the agent:register channel and passes a registry payload, but the server ignores registry unless the channel is a registry:* channel. This can return global discovery results even when a private registry token is supplied, weakening registry scoping expectations."

This was flagged as a **minor** issue in the PR review but was merged anyway.

## Gaps Identified

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| No `join_registry` tool | "join_registry", "viche_join" | `channel/opencode-plugin-viche/`, `lib/viche/` |
| No `leave_registry` tool | "leave_registry", "viche_leave" | `channel/opencode-plugin-viche/`, `lib/viche/` |
| No "list my registries" tool | "list.*registries", "my.*registries" | `channel/opencode-plugin-viche/` |
| Discover tool doesn't use registry channels | "registryChannel", "registry.*channel" | `channel/opencode-plugin-viche/tools.ts` |
| Server ignores registry param in discover payload | "registry" in handle_in | `lib/viche_web/channels/agent_channel.ex` |

## Evidence Index

### Code Files
- `channel/opencode-plugin-viche/tools.ts:207` — `defaultRegistry = config.registries?.[0] ?? "global"`
- `channel/opencode-plugin-viche/tools.ts:243-252` — discover pushes on `sessionState.channel` with `{capability, registry}`
- `channel/opencode-plugin-viche/service.ts:117-120` — `sessionState.channel` is `agent:register`
- `channel/opencode-plugin-viche/service.ts:165-176` — registry channels joined but stored separately
- `lib/viche_web/channels/agent_channel.ex:95-97` — `handle_in("discover")` only extracts `capability`
- `lib/viche_web/channels/agent_channel.ex:212-217` — `build_discover_query` only uses `socket.assigns.registry_token`
- `lib/viche_web/channels/agent_channel.ex:255-263` — `ensure_registry_membership` checks membership
- `lib/viche_web/channels/agent_channel.ex:246-247` — returns empty list on `:not_in_registry`
- `lib/viche/agents.ex:236-248` — `authorize_registry_join` checks membership
- `lib/viche/agents.ex:397-406` — `discover/1` defaults to `"global"` registry

### Documentation
- `thoughts/tasks/registry-management/plan.md` — full implementation plan for dynamic registry join/leave
- PR #66 description and review comments — documents the registry membership guard as intentional

## Related Research

- `thoughts/tasks/registry-management/plan.md` — implementation plan for missing functionality

---

## Handoff Inputs

**If planning needed** (for @prometheus):
- Scope: OpenCode plugin tools.ts, AgentChannel, Agents context
- Entry points: `viche_discover` tool, `handle_in("discover")`, `ensure_registry_membership`
- Constraints: Must maintain backward compatibility with existing global discovery
- Open questions: Should discover accept registry param directly, or require joining registry channel first?

**If implementation needed** (for @vulkanus):
- Test location: `test/viche_web/channels/agent_channel_test.exs`
- Pattern to follow: `thoughts/tasks/registry-management/plan.md` (detailed TDD plan exists)
- Entry point: Phase 1 of the plan (domain layer `join_registry/2`)
