# Dynamic Registry Management & Discovery Bug Fix

## TL;DR

> **Summary**: Fix the discovery bug where `handle_in("discover")` silently ignores the `registry` payload parameter, add `join_registry/2` and `list_registries/1` to Viche, and expose new tools (`viche_join_registry`, `viche_list_my_registries`) across all three plugin clients — with full E2E test coverage for each plugin.
> **Deliverables**: Discovery bug fix (BE + all plugins), domain functions, HTTP endpoints, channel events, plugin tools, E2E tests for all 3 plugins
> **Effort**: Medium (2–3 days)
> **Parallel Execution**: YES — 2 waves (Phases 0-3 sequential, Phases 4-6 parallel)

---

## Context

### Original Request
User wants agents to interactively manage registries at runtime and discovered that `viche_discover` doesn't work for cross-registry discovery. The root causes are:
1. BE `handle_in("discover")` ignores `registry` payload param
2. Plugins send discover on wrong channel (agent channel instead of registry channel)
3. No dynamic `join_registry` channel event exists
4. No `list_my_registries` tool exists
5. `viche_deregister` already covers "leave registry" — no separate tool needed

### Research Findings
| Source | Finding | Implication |
|--------|---------|-------------|
| `lib/viche_web/channels/agent_channel.ex:95-97` | `handle_in("discover")` only extracts `capability` — `registry` key silently dropped | Must fix to accept optional `registry` from payload |
| `lib/viche_web/channels/agent_channel.ex:212-217` | `build_discover_query` only uses `socket.assigns.registry_token` | Must also accept registry from query params |
| `lib/viche_web/channels/agent_channel.ex:255-263` | `ensure_registry_membership` gates discovery for non-members | Remove — discovery is read-only, not a security boundary |
| `channel/opencode-plugin-viche/tools.ts:245-252` | Discover pushes on `sessionState.channel` (agent:register) with `{capability, registry}` | Server ignores registry; fix is on BE side |
| `channel/openclaw-plugin-viche/tools.ts:190-192` | Discover sends `registry` in payload but server ignores it | Same fix needed |
| `channel/claude-code-plugin-viche/tools.ts:134-186` | Discover already uses registry channels correctly but falls back to agent channel | Will benefit from BE fix |
| `lib/viche/agent_server.ex:50-67` | Registry metadata set at `start_link` via `{:via, Registry, {name, key, meta}}` | Must use `Registry.update_value/3` from owning process |
| `lib/viche/agent_server.ex:99-131` | State shape: `{%Agent{registries: [...]}, %{grace_timer_ref: ref}}` | Both Agent struct AND Registry ETS metadata must stay in sync |
| `lib/viche/agents.ex:495-514` | `broadcast_agent_joined/1` iterates ALL registries | Dynamic join needs SCOPED broadcast helpers (single token) |
| `lib/viche/agents.ex:329-340` | `valid_token?/1`: 4-256 chars, `^[a-zA-Z0-9._-]+$` | Reuse for join validation |
| `channel/opencode-plugin-viche/__tests__/` | 9 test files including `e2e.test.ts`, `tools.test.ts` | Rich test infrastructure — bun:test, mock channels |
| `channel/openclaw-plugin-viche/e2e.test.ts` | Full E2E suite with live Phoenix server | Pattern: `createVicheService` + `registerVicheTools` + mock API |
| `channel/claude-code-plugin-viche/e2e.test.ts` | Full E2E suite with InMemoryTransport | Pattern: `createSession()` + MCP Client + `callTool` |
| Oracle review | Option A (accept registry in payload) is architecturally cleaner | Discovery is a pure query — no channel-context dependency |
| Oracle review | Remove `ensure_registry_membership` for discover | Registries are namespaces, not auth boundaries |
| Oracle review | `list_registries` should read from AgentServer state (source of truth) | Registry ETS metadata is derivative |
| Oracle review | Discovery fix should be Phase 0 (foundational bugfix) | Plugins depend on correct discover semantics |

### Interview Decisions
- **Discovery fix approach**: Accept `registry` in discover payload (Option A) — channel-independent semantics
- **Membership check**: Remove `ensure_registry_membership` for discover — registries are namespaces, not privacy boundaries
- **Leave registry**: `viche_deregister` covers this — no separate `viche_leave_registry` tool
- **Idempotency**: Strict errors (`:already_in_registry`, `:not_in_registry`) — not silent idempotent
- **Last registry policy**: Cannot leave last registry (`:cannot_leave_last_registry`) — "global" is NOT special-cased
- **Token normalization**: Preserve case (current behavior) — no forced lowercase
- **Channel eviction on leave**: NOT in scope — join-time-only auth (document as known limitation)

### Defaults (proceeding unless you object)
- Following existing `handle_call` pattern from `agent_server.ex:133-163`
- Following existing HTTP controller pattern from `registry_controller.ex`
- Following existing channel `handle_in` pattern from `agent_channel.ex:83-177`
- Following existing tool patterns in each plugin (TypeBox for OpenClaw, Zod for OpenCode, JSON Schema for Claude Code)
- TDD approach for Elixir phases; E2E tests for plugin phases
- No schema/migration changes (all in-memory)

---

## Objectives

### Core Objective
Fix the discovery bug where registry-scoped discovery silently falls back to global, add dynamic registry join and list capabilities, and expose them across all three plugin clients with full E2E test coverage.

### Scope
| IN (Must Ship) | OUT (Explicit Exclusions) |
|----------------|---------------------------|
| Discovery bug fix (BE `handle_in("discover")` accepts `registry` from payload) | UI changes for registry management |
| Remove `ensure_registry_membership` gating on discover | Auth/permissions per registry |
| `Viche.Agents.join_registry/2` domain function | Channel eviction on leave |
| `Viche.Agents.list_agent_registries_for/1` domain function | Token normalization (lowercase) |
| HTTP POST endpoint for join | Bulk join/leave operations |
| WebSocket channel events: `join_registry`, `list_registries` | Separate `viche_leave_registry` tool |
| `viche_join_registry` tool in all 3 plugins | |
| `viche_list_my_registries` tool in all 3 plugins | |
| E2E tests for all 3 plugins covering new tools | |
| Scoped broadcasts (`agent_joined` per token on dynamic join) | |

### Definition of Done
- [ ] `handle_in("discover")` accepts optional `registry` from payload and scopes discovery correctly
- [ ] Discovery on `agent:{id}` channel with `{capability: "coding", registry: "team-a"}` returns team-a results
- [ ] `Viche.Agents.join_registry(agent_id, token)` works with all error cases
- [ ] `Viche.Agents.list_agent_registries_for(agent_id)` returns agent's registries
- [ ] HTTP endpoint for join returns correct status codes
- [ ] WebSocket channel events work for join_registry and list_registries
- [ ] All 3 plugins expose `viche_join_registry` and `viche_list_my_registries` tools
- [ ] E2E tests pass for all 3 plugins
- [ ] After dynamic join, agent appears in discovery for that registry
- [ ] All tests pass: `mix test`
- [ ] All quality gates pass: `mix precommit`

### Must NOT Have (Guardrails)
- No direct calls to `AgentServer` from web layer — always through `Viche.Agents`
- No `Process.sleep/1` in tests — use `Process.monitor/1` or `:sys.get_state/1`
- No hardcoded special treatment of `"global"` registry
- No channel eviction logic (out of scope)
- No separate `viche_leave_registry` tool — `viche_deregister` covers this
- No modifications to existing registration flow

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES
  - Elixir: `test/viche/agents_test.exs`, `test/viche_web/channels/agent_channel_test.exs`, `test/viche_web/controllers/registry_controller_test.exs`
  - OpenCode: `channel/opencode-plugin-viche/__tests__/e2e.test.ts`, `__tests__/tools.test.ts`
  - OpenClaw: `channel/openclaw-plugin-viche/e2e.test.ts`, `tools-websocket.test.ts`
  - Claude Code: `channel/claude-code-plugin-viche/e2e.test.ts`
- **Approach**: TDD for Elixir (RED → GREEN → VALIDATE); E2E tests for plugins
- **Framework**: ExUnit for Elixir; bun:test for all plugins

---

## Execution Phases

### Dependency Graph
```
Phase 0 (discovery bug fix — BE only, no deps)
    ↓
Phase 1 (domain: join_registry + list_registries_for)
    ↓
Phase 2 (HTTP: join endpoint)
    ↓
Phase 3 (WebSocket: join_registry + list_registries events)
    ↓
Phase 4 (Plugin: OpenCode tools + E2E)     ← uses WS (Phase 3)
Phase 5 (Plugin: OpenClaw tools + E2E)     ← uses WS (Phase 3)
Phase 6 (Plugin: Claude Code tools + E2E)  ← uses WS (Phase 3)
```
Note: Phases 4, 5, 6 can run in parallel — they all depend on Phases 0-3 but not on each other.

---

### Phase 0: Discovery Bug Fix — Accept `registry` from Discover Payload

**Goal**: Fix the core discovery bug where `handle_in("discover")` silently ignores the `registry` key in the payload. Make discovery a pure query operation independent of channel context. Remove the `ensure_registry_membership` gate on discover.

**Files** (CONFIRMED by research):
- `lib/viche_web/channels/agent_channel.ex` — Modify `handle_in("discover", ...)` at lines 95-101 to extract optional `registry` key; modify `handle_discover/2` to accept registry from query; remove `ensure_registry_membership` call from `handle_discover`; update `build_discover_query/2` to prefer query registry over socket assigns

**Tests** (`test/viche_web/channels/agent_channel_test.exs` — new `describe` block):

**Discovery with `registry` in payload behaviors:**
- Given agent A in registries `["global", "team-a"]` and agent B in registries `["global", "team-b"]`, when push `"discover"` with `%{"capability" => "*", "registry" => "team-a"}` on `agent:{A_id}` channel, then reply contains agent A but NOT agent B
- Given agent A in registries `["global"]`, when push `"discover"` with `%{"capability" => "*", "registry" => "team-a"}` on `agent:{A_id}` channel, then reply contains empty agents list (A is not in team-a, but query still works — no error)
- Given agent A in registries `["global"]`, when push `"discover"` with `%{"capability" => "*"}` on `agent:{A_id}` channel (no registry param), then reply contains agents from "global" registry (backward compatible)
- Given agent A on `registry:team-a` channel, when push `"discover"` with `%{"capability" => "*", "registry" => "team-b"}` on that channel, then reply contains agents from "team-b" (payload registry takes precedence over channel context)
- Given agent A NOT in registry "private-team", when push `"discover"` with `%{"capability" => "*", "registry" => "private-team"}`, then reply contains agents in "private-team" (no membership check — discovery is read-only)

**Commands**:
```bash
mix test test/viche_web/channels/agent_channel_test.exs --trace
mix precommit
```

**Dependencies**: None (can start immediately — this is a bug fix)

**Must NOT do**:
- Break existing discover behavior (no registry param → global)
- Add any business logic in the channel handler beyond routing
- Modify the `Viche.Agents.discover/1` function (it already accepts `registry` key)

**Pattern Reference**: Follow existing `handle_in("discover", ...)` at `agent_channel.ex:95-101`

**Implementation Notes**:

1. **Modify `handle_in("discover", ...)` clauses** (in `agent_channel.ex`):
   ```elixir
   # Replace lines 95-101 with:
   def handle_in("discover", %{"capability" => cap} = params, socket) do
     base_query = %{capability: cap}
     base_query = maybe_add_registry(base_query, params, socket)
     handle_discover(base_query, socket)
   end

   def handle_in("discover", %{"name" => name} = params, socket) do
     base_query = %{name: name}
     base_query = maybe_add_registry(base_query, params, socket)
     handle_discover(base_query, socket)
   end
   ```

2. **Add `maybe_add_registry/3` private helper**:
   ```elixir
   # Priority: payload "registry" > socket.assigns.registry_token > omit (defaults to "global" in Agents.discover)
   defp maybe_add_registry(query, params, socket) do
     case Map.get(params, "registry") do
       nil ->
         case Map.get(socket.assigns, :registry_token) do
           nil -> query
           token -> Map.put(query, :registry, token)
         end
       registry when is_binary(registry) ->
         Map.put(query, :registry, registry)
     end
   end
   ```

3. **Simplify `handle_discover/2`** — remove `ensure_registry_membership` call:
   ```elixir
   defp handle_discover(query, socket) do
     case Viche.Agents.discover(query) do
       {:ok, agents} ->
         {:reply, {:ok, %{agents: agents}}, socket}
       {:error, reason} ->
         {:reply, {:error, %{error: to_string(reason), message: "discovery failed: #{reason}"}}, socket}
     end
   end
   ```

4. **Remove `ensure_registry_membership/1`** — no longer needed (or keep as dead code for future auth if preferred; Oracle recommends removing).

5. **Remove `build_discover_query/2`** — replaced by `maybe_add_registry/3` which is called before `handle_discover`.

**TDD Gates**:
- RED: Write all test cases above — they should fail (registry param ignored, membership check blocks)
- GREEN: Implement the changes
- VALIDATE: `mix precommit`

---

### Phase 1: Domain Layer — `join_registry/2` and `list_agent_registries_for/1`

**Goal**: Add atomic join operation and registry listing to the domain layer with proper state sync, validation, and broadcasts.

**Files** (CONFIRMED by research):
- `lib/viche/agent_server.ex` — Add `handle_call` clause: `{:join_registry, token}`
- `lib/viche/agents.ex` — Add public functions `join_registry/2` and `list_agent_registries_for/1`; add scoped broadcast helper `broadcast_registry_joined/2`

**Tests** (`test/viche/agents_test.exs` — new `describe` blocks):

**`join_registry/2` behaviors:**
- Given a registered agent and a valid token NOT in its registries, when `join_registry(agent_id, token)`, then returns `{:ok, %Agent{}}` with token added to registries
- Given a registered agent and a valid token NOT in its registries, when `join_registry(agent_id, token)`, then Registry ETS metadata includes the new token (verify via `Registry.lookup/2`)
- Given a registered agent and a valid token NOT in its registries, when `join_registry(agent_id, token)`, then `agent_joined` broadcast is sent to `registry:{token}` PubSub topic
- Given a registered agent and a token ALREADY in its registries, when `join_registry(agent_id, token)`, then returns `{:error, :already_in_registry}`
- Given a non-existent agent_id, when `join_registry(agent_id, token)`, then returns `{:error, :agent_not_found}`
- Given an invalid token (too short, special chars), when `join_registry(agent_id, token)`, then returns `{:error, :invalid_token}`
- Given a registered agent that joins a new registry, when `discover(%{capability: cap, registry: new_token})`, then the agent appears in results

**`list_agent_registries_for/1` behaviors:**
- Given a registered agent with registries `["global", "team-a"]`, when `list_agent_registries_for(agent_id)`, then returns `{:ok, ["global", "team-a"]}`
- Given a non-existent agent_id, when `list_agent_registries_for(agent_id)`, then returns `{:error, :agent_not_found}`

**Commands**:
```bash
mix test test/viche/agents_test.exs --trace
mix precommit
```

**Dependencies**: Phase 0 (discovery must work correctly for join verification tests)

**Must NOT do**:
- Modify existing `register_agent/1` flow
- Call `Registry.update_value/3` from outside the GenServer process
- Add any web layer code

**Pattern Reference**: Follow `lib/viche/agent_server.ex:133-163` for handle_call pattern; follow `lib/viche/agents.ex:150-159` for context function pattern with `with` pipeline validation

**Implementation Notes**:

1. **AgentServer handle_call `{:join_registry, token}`** (in `agent_server.ex`):
   - Check `token in agent.registries` → if yes, reply `{:error, :already_in_registry}`
   - Update `agent = %{agent | registries: agent.registries ++ [token]}`
   - Call `Registry.update_value(Viche.AgentRegistry, agent.id, fn meta -> %{meta | registries: agent.registries} end)` — this works because we're inside the owning process
   - Reply `{:reply, {:ok, agent}, {agent, meta}}`

2. **Agents context `join_registry/2`** (in `agents.ex`):
   ```elixir
   def join_registry(agent_id, token) do
     with true <- valid_token?(token) || {:error, :invalid_token},
          {:ok, agent} <- call_agent(agent_id, {:join_registry, token}) do
       broadcast_registry_joined(agent, token)
       {:ok, agent}
     end
   end
   ```

3. **Agents context `list_agent_registries_for/1`** (in `agents.ex`):
   ```elixir
   def list_agent_registries_for(agent_id) do
     case Registry.lookup(Viche.AgentRegistry, agent_id) do
       [{_pid, meta}] -> {:ok, meta.registries || ["global"]}
       [] -> {:error, :agent_not_found}
     end
   end
   ```
   Note: Reads from Registry ETS metadata for efficiency (no GenServer call needed for a read). This is acceptable because join/leave always update both sources atomically within the GenServer.

4. **Scoped broadcast helper** (in `agents.ex`):
   - `broadcast_registry_joined(agent, token)` — broadcasts `agent_joined` to `registry:{token}` only

5. **Note on `call_agent/2`**: Check if a private helper already exists for GenServer.call with agent lookup. If not, extract one from existing patterns (e.g., `send_message/1` at line 230 does `Registry.lookup` + `AgentServer.receive_message`). The helper should handle `:agent_not_found` consistently.

**TDD Gates**:
- RED: Write all test cases above — they should all fail (functions don't exist)
- GREEN: Implement `AgentServer` handle_call clause, then `Agents` context functions
- VALIDATE: `mix precommit`

---

### Phase 2: HTTP Layer — REST Endpoint for Join

**Goal**: Expose join as HTTP POST endpoint following existing controller patterns.

**Files** (CONFIRMED by research):
- `lib/viche_web/controllers/registry_controller.ex` — Add `join/2` action function
- `lib/viche_web/router.ex` — Add route under existing `/registry` scope

**Tests** (`test/viche_web/controllers/registry_controller_test.exs` — new `describe` block):

**`POST /registry/:agent_id/join` behaviors:**
- Given a registered agent and valid token, when POST with `{"token": "new-team"}`, then returns 200 with `{"registries": ["global", "new-team"]}`
- Given a registered agent and token already in registries, when POST, then returns 409 with `{"error": "already_in_registry"}`
- Given a non-existent agent_id, when POST, then returns 404 with `{"error": "agent_not_found"}`
- Given an invalid token (too short), when POST, then returns 422 with `{"error": "invalid_token"}`
- Given missing `token` field in body, when POST, then returns 422 with `{"error": "missing_token"}`

**Commands**:
```bash
mix test test/viche_web/controllers/registry_controller_test.exs --trace
mix precommit
```

**Dependencies**: Phase 1 (domain functions must exist)

**Must NOT do**:
- Call `AgentServer` directly — only call `Viche.Agents.join_registry/2`
- Add any business logic in the controller
- Modify existing register/discover endpoints

**Pattern Reference**: Follow `lib/viche_web/controllers/registry_controller.ex` for controller pattern; follow `lib/viche_web/router.ex` for route scope

**Implementation Notes**:

1. **Route** (in `router.ex`, inside existing `/registry` scope):
   ```elixir
   post "/:agent_id/join", RegistryController, :join
   ```

2. **Controller action** (in `registry_controller.ex`):
   ```elixir
   def join(conn, %{"agent_id" => agent_id, "token" => token}) do
     case Agents.join_registry(agent_id, token) do
       {:ok, agent} -> json(conn, %{registries: agent.registries})
       {:error, :agent_not_found} -> conn |> put_status(404) |> json(%{error: "agent_not_found"})
       {:error, :invalid_token} -> conn |> put_status(422) |> json(%{error: "invalid_token"})
       {:error, :already_in_registry} -> conn |> put_status(409) |> json(%{error: "already_in_registry"})
     end
   end

   def join(conn, %{"agent_id" => _}) do
     conn |> put_status(422) |> json(%{error: "missing_token"})
   end
   ```

**Error → HTTP Status Mapping**:
| Domain Error | HTTP Status | Response Body |
|---|---|---|
| `:agent_not_found` | 404 | `{"error": "agent_not_found"}` |
| `:invalid_token` | 422 | `{"error": "invalid_token"}` |
| `:already_in_registry` | 409 | `{"error": "already_in_registry"}` |

**TDD Gates**:
- RED: Write all controller test cases — they should fail (routes/actions don't exist)
- GREEN: Add routes and controller actions
- VALIDATE: `mix precommit`

---

### Phase 3: WebSocket Layer — Channel Events for Join and List Registries

**Goal**: Add `"join_registry"` and `"list_registries"` handle_in clauses to AgentChannel so WebSocket-connected agents can manage registries in real-time.

**Files** (CONFIRMED by research):
- `lib/viche_web/channels/agent_channel.ex` — Add two `handle_in/3` clauses

**Tests** (`test/viche_web/channels/agent_channel_test.exs` — new `describe` blocks):

**`"join_registry"` event behaviors:**
- Given a connected agent on `agent:{id}` channel, when push `"join_registry"` with `%{"token" => "new-team"}`, then reply is `{:ok, %{"registries" => [...]}}` with new token included
- Given a connected agent, when push `"join_registry"` with token already in registries, then reply is `{:error, %{"error" => "already_in_registry"}}`
- Given a connected agent, when push `"join_registry"` with invalid token, then reply is `{:error, %{"error" => "invalid_token"}}`
- Given a connected agent, when push `"join_registry"` without `"token"` key, then reply is `{:error, %{"error" => "missing_field", "field" => "token"}}`

**`"list_registries"` event behaviors:**
- Given a connected agent with registries `["global", "team-a"]`, when push `"list_registries"` with `%{}`, then reply is `{:ok, %{"registries" => ["global", "team-a"]}}`
- Given a connected agent with only `["global"]`, when push `"list_registries"`, then reply is `{:ok, %{"registries" => ["global"]}}`

**Commands**:
```bash
mix test test/viche_web/channels/agent_channel_test.exs --trace
mix precommit
```

**Dependencies**: Phase 1 (domain functions must exist)

**Must NOT do**:
- Call `AgentServer` directly — only call `Viche.Agents` context functions
- Add business logic in the channel handler
- Modify existing channel events

**Pattern Reference**: Follow `lib/viche_web/channels/agent_channel.ex:83-177` for handle_in pattern

**Implementation Notes**:

1. **handle_in `"join_registry"`** (in `agent_channel.ex`):
   ```elixir
   def handle_in("join_registry", %{"token" => token}, socket) do
     agent_id = socket.assigns.agent_id

     case Agents.join_registry(agent_id, token) do
       {:ok, agent} ->
         {:reply, {:ok, %{registries: agent.registries}}, socket}
       {:error, reason} ->
         {:reply, {:error, %{error: to_string(reason)}}, socket}
     end
   end

   def handle_in("join_registry", _params, socket) do
     {:reply, {:error, %{error: "missing_field", field: "token"}}, socket}
   end
   ```

2. **handle_in `"list_registries"`** (in `agent_channel.ex`):
   ```elixir
   def handle_in("list_registries", _params, socket) do
     agent_id = socket.assigns.agent_id

     case Agents.list_agent_registries_for(agent_id) do
       {:ok, registries} ->
         {:reply, {:ok, %{registries: registries}}, socket}
       {:error, reason} ->
         {:reply, {:error, %{error: to_string(reason)}}, socket}
     end
   end
   ```

3. **Placement**: Insert BEFORE the catch-all `handle_in(_event, _params, socket)` at line 197.

**TDD Gates**:
- RED: Write all channel test cases — they should fail (events not handled)
- GREEN: Add handle_in clauses
- VALIDATE: `mix precommit`

---

### Phase 4: Plugin Layer — OpenCode Tools + E2E Tests

**Goal**: Add `viche_join_registry` and `viche_list_my_registries` tools to the OpenCode plugin, with E2E tests.

**Files** (CONFIRMED by research):
- `channel/opencode-plugin-viche/tools.ts` — Add two new tool definitions in `createVicheTools` return object (after `viche_deregister` at line 414)
- `channel/opencode-plugin-viche/__tests__/tools.test.ts` — Add unit tests for new tools
- `channel/opencode-plugin-viche/__tests__/e2e.test.ts` — Add E2E tests for new tools

**Unit Tests** (`__tests__/tools.test.ts` — new test cases):

**`viche_join_registry` unit behaviors:**
- Given a connected session, when `viche_join_registry` with `{token: "new-team"}`, then pushes `"join_registry"` event with `{token: "new-team"}` on channel
- Given channel returns `{:ok, {registries: ["global", "new-team"]}}`, then tool returns "Joined registry 'new-team'. Current registries: global, new-team"
- Given channel returns error `"already_in_registry"`, then tool returns "Failed to join registry: already_in_registry"
- Given channel timeout, then tool returns "Failed to join registry: Channel timeout during join_registry"

**`viche_list_my_registries` unit behaviors:**
- Given a connected session, when `viche_list_my_registries`, then pushes `"list_registries"` event on channel
- Given channel returns `{:ok, {registries: ["global", "team-a"]}}`, then tool returns "Your registries: global, team-a"
- Given channel returns error, then tool returns "Failed to list registries: ..."

**E2E Tests** (`__tests__/e2e.test.ts` — new test cases, requires live Phoenix server):

**`viche_join_registry` E2E behaviors:**
- Given a registered agent in `["global"]`, when call `viche_join_registry` with a new token, then tool returns success AND agent appears in HTTP discovery for that token (`GET /registry/discover?capability=*&registry={token}`)
- Given a registered agent already in `"global"`, when call `viche_join_registry` with `"global"`, then tool returns error containing "already_in_registry"

**`viche_list_my_registries` E2E behaviors:**
- Given a registered agent in `["global"]` that joined `"new-team"`, when call `viche_list_my_registries`, then tool returns both "global" and "new-team"

**Commands**:
```bash
cd channel/opencode-plugin-viche && bun test __tests__/tools.test.ts && cd ../..
cd channel/opencode-plugin-viche && bun test __tests__/e2e.test.ts && cd ../..
```

**Dependencies**: Phase 3 (WebSocket channel events must exist)

**Must NOT do**:
- Modify existing tools
- Change the `ensureSessionReady` contract
- Use HTTP REST for new tools (all tools use WebSocket channel push)

**Pattern Reference**: Follow `channel/opencode-plugin-viche/tools.ts:362-414` (viche_deregister tool) for tool structure with `ensureSessionReady` guard and `pushWithAck`

**Implementation Notes**:

1. **Tool: `viche_join_registry`** (in `tools.ts`):
   - **Parameters** (Zod): `token: z.string().min(4).max(256).regex(/^[a-zA-Z0-9._-]+$/).describe("Registry token to join (4-256 chars, alphanumeric + . _ -)")`
   - **Execute**:
     1. `ensureSessionReady(context.sessionID)` guard
     2. `pushWithAck(sessionState.channel, "join_registry", { token: args.token })`
     3. On ok: return `"Joined registry '{token}'. Current registries: [...]"`
     4. On error: return `"Failed to join registry: {error}"`

2. **Tool: `viche_list_my_registries`** (in `tools.ts`):
   - **Parameters** (Zod): none (empty args)
   - **Execute**:
     1. `ensureSessionReady(context.sessionID)` guard
     2. `pushWithAck(sessionState.channel, "list_registries", {})`
     3. On ok: return `"Your registries: [...]"`
     4. On error: return `"Failed to list registries: {error}"`

3. **Return object**: Update to: `return { viche_discover, viche_send, viche_reply, viche_deregister, viche_join_registry, viche_list_my_registries };`

**TDD Gates**:
- RED: Write unit tests and E2E tests — they should fail (tools don't exist)
- GREEN: Implement tools
- VALIDATE: `bun test` in plugin directory

---

### Phase 5: Plugin Layer — OpenClaw Tools + E2E Tests

**Goal**: Add `viche_join_registry` and `viche_list_my_registries` tools to the OpenClaw plugin, with E2E tests.

**Files** (CONFIRMED by research):
- `channel/openclaw-plugin-viche/tools.ts` — Add two new tool registrations in `registerVicheTools` function (after `viche_deregister` at line 423)
- `channel/openclaw-plugin-viche/tools-websocket.test.ts` — Add unit tests for new tools
- `channel/openclaw-plugin-viche/e2e.test.ts` — Add E2E tests for new tools

**Unit Tests** (`tools-websocket.test.ts` — new test cases):

**`viche_join_registry` unit behaviors:**
- Given a connected state, when `viche_join_registry` with `{token: "new-team"}`, then pushes `"join_registry"` event with `{token: "new-team"}` on channel
- Given channel returns ok with registries, then tool returns text containing "Joined registry"
- Given not connected, then tool returns "Viche service is not yet connected" error

**`viche_list_my_registries` unit behaviors:**
- Given a connected state, when `viche_list_my_registries`, then pushes `"list_registries"` event on channel
- Given channel returns ok with registries, then tool returns text containing registries

**E2E Tests** (`e2e.test.ts` — new test cases in existing describe block):

**`viche_join_registry` E2E behaviors:**
- Given a registered agent, when call `viche_join_registry` with a new token, then tool returns success AND agent appears in HTTP discovery for that token
- Given a registered agent already in a registry, when call `viche_join_registry` with that token, then tool returns error containing "already_in_registry"

**`viche_list_my_registries` E2E behaviors:**
- Given a registered agent that joined a new registry, when call `viche_list_my_registries`, then tool returns the updated registries list

**Commands**:
```bash
cd channel/openclaw-plugin-viche && bun test tools-websocket.test.ts && cd ../..
cd channel/openclaw-plugin-viche && bun test e2e.test.ts && cd ../..
```

**Dependencies**: Phase 3 (WebSocket channel events must exist)

**Must NOT do**:
- Modify existing tools
- Change the `requireConnected` contract
- Use HTTP REST for new tools (all tools use WebSocket channel push via `pushChannel`)

**Pattern Reference**: Follow `channel/openclaw-plugin-viche/tools.ts:362-423` (viche_deregister tool) for tool structure with `requireConnected` guard, TypeBox parameters, and `pushChannel`

**Implementation Notes**:

1. **Tool: `viche_join_registry`** (in `tools.ts`):
   - **Parameters** (TypeBox): `token: Type.String({ description: "Registry token to join", minLength: 4, maxLength: 256, pattern: "^[a-zA-Z0-9._-]+$" })`
   - **Execute**:
     1. `requireConnected(state)` guard
     2. `pushChannel(state.channel!, "join_registry", { token: params.token })`
     3. On ok: parse response, return `textResult("Joined registry '{token}'. Current registries: [...]")`
     4. On error: return `textResult("Failed to join registry: {error}")`

2. **Tool: `viche_list_my_registries`** (in `tools.ts`):
   - **Parameters** (TypeBox): `Type.Object({})` (empty)
   - **Execute**:
     1. `requireConnected(state)` guard
     2. `pushChannel(state.channel!, "list_registries", {})`
     3. On ok: return `textResult("Your registries: [...]")`
     4. On error: return `textResult("Failed to list registries: {error}")`

3. **Registration**: Add `api.registerTool(...)` calls inside `registerVicheTools` function, after the existing 4 tools.

**Key Differences from Phase 4 (OpenCode)**:
| Aspect | OpenCode (Phase 4) | OpenClaw (Phase 5) |
|--------|-------------------|-------------------|
| Schema library | Zod (`z.string()...`) | TypeBox (`Type.String(...)`) |
| Guard | `ensureSessionReady(context.sessionID)` | `requireConnected(state)` |
| Agent ID source | `sessionState.agentId` (from ensureSessionReady) | `state.agentId` |
| Registration pattern | Return `Record<string, ToolDefinition>` from `createVicheTools` | `api.registerTool((ctx) => tool)` factory |
| Channel push | `pushWithAck(sessionState.channel, ...)` | `pushChannel(state.channel!, ...)` |

**TDD Gates**:
- RED: Write unit tests and E2E tests — they should fail (tools don't exist)
- GREEN: Implement tools
- VALIDATE: `bun test` in plugin directory

---

### Phase 6: Plugin Layer — Claude Code MCP Tools + E2E Tests

**Goal**: Add `viche_join_registry` and `viche_list_my_registries` tools to the Claude Code MCP plugin, with E2E tests.

**Files** (CONFIRMED by research):
- `channel/claude-code-plugin-viche/tools.ts` — Add two new entries to `TOOL_DEFINITIONS` array and two new `if (toolName === ...)` blocks in `CallToolRequestSchema` handler
- `channel/claude-code-plugin-viche/e2e.test.ts` — Add E2E tests for new tools

**E2E Tests** (`e2e.test.ts` — new test cases in existing describe block):

**`viche_join_registry` E2E behaviors:**
- Given a registered agent, when `callTool({ name: "viche_join_registry", arguments: { token: "new-team" } })`, then result text contains "Joined registry" AND agent appears in HTTP discovery for that token
- Given a registered agent already in a registry, when `callTool` with that token, then result text contains "Failed to join registry"

**`viche_list_my_registries` E2E behaviors:**
- Given a registered agent that joined a new registry, when `callTool({ name: "viche_list_my_registries", arguments: {} })`, then result text contains both registries

**`listTools` update:**
- Update existing test "1) listTools returns all four tools" to expect 6 tools (add `viche_join_registry` and `viche_list_my_registries`)

**Commands**:
```bash
cd channel/claude-code-plugin-viche && bun test e2e.test.ts && cd ../..
```

**Dependencies**: Phase 3 (WebSocket channel events must exist)

**Must NOT do**:
- Modify existing tools
- Change the MCP server contract
- Use HTTP REST (this plugin uses WebSocket channel push via `channelPush` for all operations)

**Pattern Reference**: Follow `channel/claude-code-plugin-viche/tools.ts:84-100` (viche_deregister TOOL_DEFINITIONS entry) for ListTools schema pattern; follow `channel/claude-code-plugin-viche/tools.ts:246-291` (viche_deregister CallTool handler) for handler with `channelPush`

**Implementation Notes**:

1. **TOOL_DEFINITIONS** — add two entries:
   ```typescript
   {
     name: "viche_join_registry",
     description:
       "Join a registry on the Viche network. Adds your agent to the specified registry for scoped discovery.",
     inputSchema: {
       type: "object" as const,
       properties: {
         token: {
           type: "string",
           description: "Registry token to join (4-256 chars, alphanumeric + . _ -)",
           minLength: 4,
           maxLength: 256,
           pattern: "^[a-zA-Z0-9._-]+$",
         },
       },
       required: ["token"],
     },
   },
   {
     name: "viche_list_my_registries",
     description:
       "List the registries your agent is currently a member of on the Viche network.",
     inputSchema: {
       type: "object" as const,
       properties: {},
       required: [],
     },
   },
   ```

2. **CallToolRequestSchema handler** — add two blocks:
   ```typescript
   if (toolName === "viche_join_registry") {
     const args = request.params.arguments as { token: string };
     try {
       const channel = getChannel();
       if (!channel) return notConnectedResponse();

       const resp = await channelPush<{ registries: string[] }>(
         channel,
         "join_registry",
         { token: args.token }
       );
       return {
         content: [{
           type: "text",
           text: `Joined registry '${args.token}'. Current registries: ${resp.registries.join(", ")}`,
         }],
       };
     } catch (err) {
       const message = err instanceof Error ? err.message : String(err);
       return {
         content: [{ type: "text", text: `Failed to join registry: ${message}` }],
       };
     }
   }

   if (toolName === "viche_list_my_registries") {
     try {
       const channel = getChannel();
       if (!channel) return notConnectedResponse();

       const resp = await channelPush<{ registries: string[] }>(
         channel,
         "list_registries",
         {}
       );
       return {
         content: [{
           type: "text",
           text: `Your registries: ${resp.registries.join(", ")}`,
         }],
       };
     } catch (err) {
       const message = err instanceof Error ? err.message : String(err);
       return {
         content: [{ type: "text", text: `Failed to list registries: ${message}` }],
       };
     }
   }
   ```

**Key Differences from Phase 4/5**:
| Aspect | OpenCode/OpenClaw (Phase 4/5) | Claude Code MCP (Phase 6) |
|--------|------------------------------|----------------------|
| Transport | WebSocket (`pushWithAck`/`pushChannel`) | WebSocket (`channelPush`) |
| Schema library | Zod / TypeBox | JSON Schema literal |
| Guard | `ensureSessionReady` / `requireConnected` | `!channel` null check via `getChannel()` |
| Agent ID source | `sessionState.agentId` / `state.agentId` | Implicit (channel is already authenticated) |
| Registration | Return object / tool factory | `TOOL_DEFINITIONS` + `CallToolRequestSchema` handler |

**TDD Gates**:
- RED: Write E2E tests — they should fail (tools don't exist)
- GREEN: Implement tools
- VALIDATE: `bun test` in plugin directory

---

## What We're NOT Doing

| Excluded Item | Reason | Future Ticket? |
|---|---|---|
| `viche_leave_registry` tool | `viche_deregister` already covers this (leave single registry or all) | No |
| `leave_registry` domain function | `deregister_from_registries` already handles this | No |
| `POST /registry/:agent_id/leave` HTTP endpoint | `viche_deregister` uses channel push; HTTP leave not needed | No |
| `"leave_registry"` channel event | `"deregister"` channel event already handles this | No |
| Channel eviction on leave | Complex; join-time-only auth is sufficient for now | Yes — if users report confusion |
| Auth/permissions per registry | No auth model exists yet | Yes — when multi-tenant |
| UI for registry management | Dashboard is read-only currently | Yes — when dashboard gets write capabilities |
| Token normalization (lowercase) | Current behavior preserves case; changing would be breaking | No |
| Bulk join/leave | YAGNI; single operations are sufficient | No |
| Persistent registry membership | All state is in-memory by design | No |

---

## Known Limitations (Document in Code)

1. **Join-time-only channel authorization**: If an agent leaves a registry while connected to its `registry:{token}` channel, the channel subscription remains active until disconnect. The agent will continue receiving broadcasts on that topic. This is acceptable because:
   - Channel reconnection will fail (join check reads updated metadata)
   - The agent won't appear in discovery for that registry
   - No security risk (registries are for organization, not access control)

2. **No automatic channel join on registry join**: When an agent dynamically joins a registry via channel event, they don't automatically subscribe to the `registry:{token}` channel. The client must explicitly join the channel topic after the join_registry call succeeds.

3. **Discovery is open**: Any agent can discover agents in any registry, even if not a member. This is by design — registries are namespaces for organization, not privacy boundaries. If privacy is needed in the future, add per-registry ACLs.

---

## Risks and Mitigations

| Risk | Trigger | Mitigation |
|------|---------|------------|
| Registry ETS metadata out of sync with GenServer state | Bug in handle_call implementation | Test both state sources independently (GenServer.call :get_state AND Registry.lookup) |
| Broadcast storm on rapid join | Agent rapidly toggling registries | GenServer serialization naturally rate-limits; no additional mitigation needed |
| Plugin error messages diverge from server | Channel error format changes | Define error mapping in Phase 3 and reference it in Phase 4/5/6 |
| `Registry.update_value/3` called from wrong process | Refactor moves logic outside GenServer | Test verifies metadata update; compile-time can't catch this |
| E2E tests flaky due to timing | WebSocket message delivery latency | Use polling with timeout (existing pattern in all 3 plugin E2E suites) |
| Discovery fix breaks existing behavior | Removing membership check changes semantics | Phase 0 tests verify backward compatibility (no registry param → global) |

---

## Success Criteria

### Verification Commands
```bash
# Run all Elixir tests
mix test

# Run specific Elixir test files for this feature
mix test test/viche/agents_test.exs test/viche_web/controllers/registry_controller_test.exs test/viche_web/channels/agent_channel_test.exs --trace

# Run full Elixir quality gates
mix precommit

# Run OpenCode plugin tests
cd channel/opencode-plugin-viche && bun test && cd ../..

# Run OpenClaw plugin tests
cd channel/openclaw-plugin-viche && bun test && cd ../..

# Run Claude Code plugin tests
cd channel/claude-code-plugin-viche && bun test && cd ../..

# Check TypeScript compilation for all plugins
cd channel/openclaw-plugin-viche && npx tsc --noEmit && cd ../..
cd channel/opencode-plugin-viche && npx tsc --noEmit && cd ../..
cd channel/claude-code-plugin-viche && npx tsc --noEmit && cd ../..
```

### Final Checklist
- [ ] Discovery bug fixed: `handle_in("discover")` accepts `registry` from payload
- [ ] `ensure_registry_membership` removed from discover flow
- [ ] Discovery on `agent:{id}` channel with registry param returns correct results
- [ ] Backward compatible: discover without registry param returns global results
- [ ] `join_registry/2` domain function works with all error cases
- [ ] `list_agent_registries_for/1` domain function works
- [ ] HTTP join endpoint returns correct status codes
- [ ] WebSocket `join_registry` and `list_registries` events work
- [ ] OpenCode plugin: `viche_join_registry` and `viche_list_my_registries` tools work
- [ ] OpenClaw plugin: `viche_join_registry` and `viche_list_my_registries` tools work
- [ ] Claude Code plugin: `viche_join_registry` and `viche_list_my_registries` tools work
- [ ] E2E tests pass for all 3 plugins
- [ ] Broadcasts verified for dynamic join (scoped to affected token only)
- [ ] Discovery works for dynamically-joined registries
- [ ] `mix precommit` passes (compilation, formatting, Credo, tests, Dialyzer)
- [ ] No `Process.sleep` in tests
- [ ] All processes started with `start_supervised!/1` in tests
- [ ] `viche_deregister` confirmed as leave_registry — no duplicate tool created
