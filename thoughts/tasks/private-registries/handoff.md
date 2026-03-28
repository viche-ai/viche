# Private Registries — Implementation Handoff

**Date:** 2026-03-26  
**Status:** Implementation complete, verification passed, ready for commit  
**Spec:** `thoughts/tasks/private-registries/spec.md`

---

## Executive Summary

All 5 phases of the Private Registries spec have been implemented, plus an unplanned Phase 5b to fix the `opencode-plugin-viche` that was missed in the original spec. The implementation introduces token-based private namespaces for agent discovery while maintaining backwards compatibility for the global registry.

**Key Achievement:** Agents can now create private discovery namespaces using arbitrary tokens, enabling secure agent-to-agent collaboration without exposing capabilities to the public registry.

---

## What Was Done

### Phase 1: Agent Struct + UUID IDs (Foundation)

**Goal:** Migrate from 8-char hex IDs to UUIDs and add registry support to the Agent struct.

**Changes:**
- Agent IDs changed from 8-char hex → UUID v4 via `Ecto.UUID.generate()`
- New `registries: [String.t()]` field on Agent struct, default `["global"]`
- Token validation: min 4 chars, max 256, regex `[a-zA-Z0-9._-]+` only
- Registry meta in `Viche.AgentRegistry` now includes `registries` key
- Message IDs changed to `"msg-{UUID}"` format

**Files Modified:**
- `lib/viche/agent.ex`
- `lib/viche/agents.ex`
- `lib/viche/agent_server.ex`

**Why UUID?** 5.3×10³⁶ combinations vs 4 billion for 8-char hex. Effectively unguessable, enabling secure cross-namespace messaging.

---

### Phase 2: Scoped Discovery + Registration API

**Goal:** Allow agents to register with custom registries and discover agents within specific namespaces.

**Changes:**
- `Viche.Agents.discover/1` accepts optional `:registry` key, filters by it
- Discovery without token defaults to `"global"` namespace
- `RegistryController.register/2` accepts `registries` param in request body
- `RegistryController.discover/2` accepts `token` (or `registry`) query param
- Registration response includes `registries` field
- Invalid tokens return 422 with validation errors

**Files Modified:**
- `lib/viche/agents.ex`
- `lib/viche_web/controllers/registry_controller.ex`

**Design Decision:** Token IS the registry. No explicit "create" step, no ownership model. Know the token = can join the namespace.

---

### Phase 3: Registry Channels

**Goal:** Enable real-time discovery and presence notifications within private registries via WebSocket.

**Changes:**
- New `"registry:{token}"` Phoenix Channel topic
- Join validation: agent must have token in their `registries` list
- Scoped `"discover"` handler on registry channels (filters by registry)
- `"agent_joined"` and `"agent_left"` broadcasts (wired in `agents.ex`)
- Reuses `AgentChannel` module via clean `build_discover_query/2` helper
- `AgentSocket` routes `"registry:*"` to `AgentChannel`

**Files Modified:**
- `lib/viche_web/channels/agent_channel.ex`
- `lib/viche_web/channels/agent_socket.ex`
- `lib/viche/agents.ex` (broadcast hooks)

**Design Decision:** Discovery is scoped, messaging is cross-namespace. If you know an agent's UUID, you can message them regardless of registry membership.

---

### Phase 4: Well-Known Endpoint

**Goal:** Update the `/.well-known/agent-registry` descriptor to document the new registry features.

**Changes:**
- Version bumped to `"0.2.0"`, protocol to `"viche/0.2"`
- `registries` field documented in `request_schema`
- `token` field documented in `discover.query_params`
- `?token=` query param → dynamic `registry` section injected in response
- No token → no registry section (backwards-safe descriptor)

**Files Modified:**
- `lib/viche_web/controllers/well_known_controller.ex`

**Design Decision:** Descriptor is self-documenting. Clients can discover registry features by passing `?token=example` to see the full schema.

---

### Phase 5: MCP Channel + OpenClaw Plugin

**Goal:** Update client libraries to support private registries.

**Changes:**

**viche-channel.ts:**
- `VICHE_REGISTRY_TOKEN` env var support
- `registries` field in registration body
- Registry channel join after connect
- `token` param on `viche_discover` tool

**openclaw-plugin-viche:**
- `registryToken` on `VicheConfig`
- `registries` in registration
- Registry channel join
- `token` param on discover tool

**.mcp.json.example:**
- `VICHE_REGISTRY_TOKEN` documented

**Files Modified:**
- `channel/viche-channel.ts`
- `channel/.mcp.json.example`
- `channel/openclaw-plugin-viche/types.ts`
- `channel/openclaw-plugin-viche/service.ts`
- `channel/openclaw-plugin-viche/tools.ts`

---

### Phase 5b: OpenCode Plugin (Unplanned Fix)

**Goal:** Fix the `opencode-plugin-viche` that was missed in the original spec.

**Why This Was Needed:** The original spec only covered `viche-channel.ts` and `openclaw-plugin-viche`, but `opencode-plugin-viche` is the primary client used by Claude Code instances. Without this fix, OpenCode agents couldn't use private registries.

**Changes:**

**types.ts:**
- Added `registryToken?: string` to `VicheConfig`
- Updated SessionState comment to reflect UUID format

**config.ts:**
- Auto-generate UUID token on first run
- Persist token to `.opencode/viche.json`
- Precedence: env var → file → auto-generate+persist

**service.ts:**
- Pass `registries` in registration
- Join `registry:{token}` channel

**tools.ts:**
- `token` param on discover
- **CRITICAL BUG FIX:** `viche_reply` regex changed from `/^[0-9a-f]{8}$/` to UUID regex

**package.json:**
- Added `test`, `test:e2e`, `test:all` scripts

**Test Fixtures:**
- All test files updated from 8-char hex to UUID format

**Files Modified:**
- `channel/opencode-plugin-viche/types.ts`
- `channel/opencode-plugin-viche/config.ts`
- `channel/opencode-plugin-viche/service.ts`
- `channel/opencode-plugin-viche/tools.ts`
- `channel/opencode-plugin-viche/package.json`
- `channel/opencode-plugin-viche/__tests__/tools.test.ts`
- `channel/opencode-plugin-viche/__tests__/service.test.ts`
- `channel/opencode-plugin-viche/__tests__/index.test.ts`
- `channel/opencode-plugin-viche/__tests__/e2e.test.ts`

**Design Decision:** Auto-generate token for convenience. OpenCode agents get a persistent private registry by default, overridable via `VICHE_REGISTRY_TOKEN` env var for shared namespaces.

---

## Execution Method

**Phases 1-2:** Sequential implementation via @vulkanus (foundation dependencies required sequential execution)

**Phases 3-5:** Parallel implementation via 3 OpenCode instances coordinated over Viche network using cmux:
- Agent 1: Registry Channels (Phase 3)
- Agent 2: Well-Known Endpoint (Phase 4)
- Agent 3: MCP Channel + OpenClaw Plugin (Phase 5)

**Phase 5b:** Sequential implementation via @vulkanus (unplanned fix discovered during verification)

---

## Verification Status

| Check | Result |
|-------|--------|
| `mix precommit` | ✅ 189 tests, 0 failures, 0 Credo issues, 0 Dialyzer errors |
| `bun run test` (opencode plugin) | ✅ 48 tests, 0 failures |
| `bun build viche-channel.ts` | ✅ 217 modules, 0 errors |
| TypeScript compile (opencode plugin) | ✅ Clean |

**All automated checks passed.** Code is ready for commit.

---

## Files Changed

**30 files changed, +1108 / -144 lines**

### Elixir Core (3 files)
- `lib/viche/agent.ex` — registries field, UUID type
- `lib/viche/agents.ex` — UUID generation, scoped discovery, token validation, registry broadcasts
- `lib/viche/agent_server.ex` — registries in init + meta

### Elixir Web (4 files)
- `lib/viche_web/channels/agent_channel.ex` — registry channel join/discover/events
- `lib/viche_web/channels/agent_socket.ex` — `"registry:*"` route
- `lib/viche_web/controllers/registry_controller.ex` — registries param, token discovery
- `lib/viche_web/controllers/well_known_controller.ex` — v0.2.0 descriptor, ?token= support

### Elixir Tests (6 files)
- `test/viche/agents_test.exs` — scoped discovery + token validation tests
- `test/viche/agent_server_test.exs` — registries meta tests
- `test/viche_web/channels/agent_channel_test.exs` — registry channel tests
- `test/viche_web/controllers/registry_controller_test.exs` — scoped discovery HTTP tests
- `test/viche_web/controllers/well_known_controller_test.exs` — descriptor + token tests
- `test/viche_web/controllers/message_controller_test.exs` — UUID format updates
- `test/viche_web/integration/openclaw_plugin_flow_test.exs` — UUID format updates

### TypeScript — MCP Channel (2 files)
- `channel/viche-channel.ts` — REGISTRY_TOKEN, registries, discover token
- `channel/.mcp.json.example` — VICHE_REGISTRY_TOKEN

### TypeScript — OpenClaw Plugin (3 files)
- `channel/openclaw-plugin-viche/types.ts` — registry support
- `channel/openclaw-plugin-viche/service.ts` — registry support
- `channel/openclaw-plugin-viche/tools.ts` — registry support

### TypeScript — OpenCode Plugin (9 files)
- `channel/opencode-plugin-viche/types.ts` — registry support + UUID comment
- `channel/opencode-plugin-viche/config.ts` — auto-generate token
- `channel/opencode-plugin-viche/service.ts` — registry support
- `channel/opencode-plugin-viche/tools.ts` — registry support + UUID regex fix
- `channel/opencode-plugin-viche/package.json` — test scripts
- `channel/opencode-plugin-viche/__tests__/tools.test.ts` — UUID fixtures
- `channel/opencode-plugin-viche/__tests__/service.test.ts` — UUID fixtures
- `channel/opencode-plugin-viche/__tests__/index.test.ts` — UUID fixtures
- `channel/opencode-plugin-viche/__tests__/e2e.test.ts` — UUID fixtures

---

## Key Design Decisions

### 1. Token IS the Registry
No explicit "create" step, no ownership model. Any agent can join any registry by knowing the token. This is intentional — registries are ephemeral collaboration spaces, not persistent resources.

### 2. Discovery Scoped, Messaging Cross-Namespace
Agents can only discover other agents within their shared registries, but if you know an agent's UUID, you can message them regardless of registry membership. This enables:
- Private discovery (agents can't be found unless you're in their registry)
- Cross-namespace collaboration (agents can share their UUID out-of-band)

### 3. UUID IDs for Security
8-char hex IDs have 4 billion combinations (easily brute-forceable). UUID v4 has 5.3×10³⁶ combinations (effectively unguessable). This makes cross-namespace messaging secure — you can't discover UUIDs by guessing.

### 4. `"global"` is Default Namespace
Agents without tokens go to the global registry. This maintains backwards compatibility and provides a public discovery space.

### 5. OpenCode Plugin Auto-Generates Token
For convenience, the OpenCode plugin auto-generates a UUID token on first run and persists it to `.opencode/viche.json`. This gives each OpenCode agent a persistent private registry by default, while still allowing shared namespaces via `VICHE_REGISTRY_TOKEN` env var.

### 6. Clean Break from Old ID Format
No backwards compatibility with 8-char hex IDs. This is a breaking change, but the protocol is pre-1.0 and the security/scalability benefits justify it.

### 7. No Persistence
All registry state is in-memory (GenServer). Registries are ephemeral by design. If the server restarts, all agents must re-register. This is acceptable for the current use case and keeps the implementation simple.

---

## What's NOT Done / Next Steps

### 1. E2E Tests Not Run
`bun run test:e2e` requires a running Viche server. Only unit tests were verified. **Next agent should:**
- Start Phoenix server (`iex -S mix phx.server`)
- Run `cd channel/opencode-plugin-viche && bun run test:e2e`
- Verify all E2E tests pass

### 2. No Commit/Push Yet
Changes are staged but uncommitted at time of handoff. **Next agent should:**
- Review changes with `git diff --staged`
- Commit with message: `feat: implement private registries (v0.2.0)`
- Push to remote

### 3. Spec Checklist Items Still Open
From `spec.md`, these items are not verified:
- [ ] End-to-end demo scenario (manual verification)
- [ ] Agent-to-agent token sharing (manual verification)

**Next agent should:**
- Run manual demo: 2 OpenCode agents with shared `VICHE_REGISTRY_TOKEN`, verify they can discover each other but not agents in global registry
- Document demo results in spec.md

### 4. Future Considerations (Explicitly Out of Scope)
These were intentionally deferred per spec:
- Token hashing/encryption (plaintext is acceptable for now)
- Rate limiting
- Persistence (DB/migrations)
- Registry metadata (name, description)
- Admin UI

**Do not implement these unless explicitly requested.**

---

## Critical Context for Next Agent

### Testing Private Registries

To manually test private registries:

```bash
# Terminal 1: Start Phoenix server
iex -S mix phx.server

# Terminal 2: Start OpenCode agent with custom registry
VICHE_REGISTRY_TOKEN=my-secret-token claude --dangerously-load-development-channels server:viche --dangerously-skip-permissions

# Terminal 3: Start another OpenCode agent with same registry
VICHE_REGISTRY_TOKEN=my-secret-token claude --dangerously-load-development-channels server:viche --dangerously-skip-permissions

# Terminal 4: Start OpenCode agent in global registry (no token)
claude --dangerously-load-development-channels server:viche --dangerously-skip-permissions
```

**Expected behavior:**
- Agents in `my-secret-token` registry can discover each other
- Agent in global registry cannot discover agents in `my-secret-token`
- Agents in `my-secret-token` cannot discover agent in global registry
- All agents can message each other if they know the UUID (cross-namespace messaging)

### Token Validation Rules

Tokens must:
- Be 4-256 characters long
- Match regex: `[a-zA-Z0-9._-]+`
- Be passed in registration body as `registries: ["token1", "token2"]`
- Be passed in discovery query as `?token=token1`

Invalid tokens return 422 with validation errors.

### Registry Channel Topics

- Global registry: `"agent:{uuid}"` (unchanged)
- Private registry: `"registry:{token}"`

Agents join both their agent channel AND all registry channels for their tokens.

### Auto-Generated Token Location

OpenCode plugin stores auto-generated token at:
```
.opencode/viche.json
```

Format:
```json
{
  "registryToken": "550e8400-e29b-41d4-a716-446655440000"
}
```

This file is gitignored and persists across sessions.

---

## Handoff Checklist

**Before continuing work, the next agent should:**

- [ ] Read this handoff document completely
- [ ] Read `thoughts/tasks/private-registries/spec.md`
- [ ] Review staged changes with `git diff --staged`
- [ ] Run `mix precommit` to verify all checks pass
- [ ] Run `cd channel/opencode-plugin-viche && bun run test` to verify TypeScript tests
- [ ] Start Phoenix server and run E2E tests
- [ ] Run manual demo scenario (2 agents with shared token)
- [ ] Commit and push changes
- [ ] Update spec.md checklist with verification results

**Questions to ask if unclear:**
- What is the expected behavior for [specific scenario]?
- Should [feature] be implemented now or deferred?
- How should [edge case] be handled?

---

## Contact / Context

**Original Spec Author:** @vulkanus  
**Implementation Team:** @vulkanus (Phases 1-2, 5b) + 3 OpenCode agents (Phases 3-5)  
**Spec Location:** `thoughts/tasks/private-registries/spec.md`  
**Related Docs:** `AGENTS.md` (Viche architecture overview)

**This implementation is complete and verified. The next agent should focus on E2E testing, manual verification, and landing the changes (commit + push).**
