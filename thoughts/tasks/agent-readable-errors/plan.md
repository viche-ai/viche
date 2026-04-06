# Agent-Readable Error Messages for REST Controllers

## TL;DR

> **Summary**: Add human/agent-readable `message` fields to all REST error responses that currently return bare `%{error: "code"}`, matching the pattern already used by the WebSocket channel.
> **Deliverables**: 14 error responses updated across 4 controllers, 1 `details` → `message` normalization, updated tests
> **Effort**: Short (1–2h)
> **Parallel Execution**: YES — Phases 1–4 are independent

---

## Context

### Original Request
Agents cannot self-correct when REST API calls fail because error responses return bare codes like `%{error: "capabilities_required"}` with no guidance. The WebSocket channel already returns `%{error: "code", message: "description"}` — REST controllers should follow the same pattern.

### Research Findings
| Source | Finding | Implication |
|--------|---------|-------------|
| `lib/viche_web/channels/agent_channel.ex:91-183` | Channel uses `%{error: "code", message: "description"}` consistently | This is the target pattern for REST controllers |
| `lib/viche_web/controllers/message_controller.ex:62-65` | `invalid_message` already has `message` field | Proves the pattern works in REST; follow this exactly |
| `lib/viche_web/controllers/registry_controller.ex:128-131` | `invalid_token` uses `details` key instead of `message` | Normalize to `message` for consistency |
| `test/viche_web/controllers/registry_controller_test.exs:52-60` | Tests assert `%{"error" => "code"} = json_response(conn, status)` using pattern match | Pattern match won't break when `message` is added — tests still pass as-is |
| `test/viche_web/controllers/registry_controller_test.exs:426` | One test asserts `%{"error" => "invalid_token", "details" => _}` | This test WILL break when `details` → `message`; must update |

### Key Insight: Existing Tests Won't Break (Mostly)
Elixir's `=` pattern match on `%{"error" => "code"}` matches maps with *additional* keys. Adding a `message` field to the JSON response won't break any existing test — **except** the one test at line 426 that explicitly matches on `"details"`.

---

## Objectives

### Core Objective
Every REST error response returns `%{error: "code", message: "human-readable description"}` so agents can parse the message and self-correct.

### Scope
| IN (Must Ship) | OUT (Explicit Exclusions) |
|----------------|---------------------------|
| Add `message` to 13 bare-code errors across 4 controllers | Changing error codes themselves |
| Normalize `details` → `message` in discover `invalid_token` | Adding error messages to AuthController (browser-facing, not agent API) |
| Update the 1 test that asserts on `"details"` key | Structured error objects (e.g., field-level errors) |
| Add new tests asserting `message` field presence | Changing HTTP status codes |
| | i18n / localization of messages |

### Definition of Done
- [ ] All REST error responses include both `error` and `message` keys
- [ ] `mix precommit` passes (compilation, formatting, Credo strict, tests, Dialyzer)
- [ ] No existing test broken (except the `details` → `message` rename)

### What We're NOT Doing
- **Not changing AuthController** — it's browser-facing (redirects, flash messages), not an agent API
- **Not adding structured/field-level errors** — simple string messages are sufficient for agent self-correction
- **Not changing any error codes** — only adding the `message` field alongside existing codes
- **Not changing HTTP status codes** — 422, 404, 400, 403 all stay the same

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES — `VicheWeb.ConnCase`, `Phoenix.ConnTest`
- **Approach**: TDD (RED → GREEN → VALIDATE)
- **Framework**: ExUnit via `mix test`
- **Validation**: `mix precommit`

---

## Execution Phases

### Dependency Graph
```
Phase 1 (RegistryController register) ──┐
Phase 2 (RegistryController deregister + discover) ──┤── all independent
Phase 3 (InboxController) ──┤
Phase 4 (HeartbeatController + MessageController) ──┘
```

All phases are independent and can execute in any order.

---

### Phase 1: RegistryController — register errors (7 errors)

**Files**:
- `test/viche_web/controllers/registry_controller_test.exs` — Add `message` assertions to existing error tests + add new tests
- `lib/viche_web/controllers/registry_controller.ex` — Add `message` field to 7 error responses (lines 55, 59, 65, 70, 75, 80, 85)

**Error → Message mapping**:
| Error Code | Message |
|-----------|---------|
| `capabilities_required` | `"capabilities must be a non-empty list of strings"` |
| `invalid_capabilities` | `"every capability must be a string"` |
| `invalid_name` | `"name must be a string or omitted"` |
| `invalid_description` | `"description must be a string or omitted"` |
| `invalid_registry_token` | `"each registry token must be 4-256 chars, alphanumeric/._-"` |
| `invalid_polling_timeout` | `"polling_timeout_ms must be an integer >= 5000"` |
| `invalid_grace_period` | `"grace_period_ms must be an integer >= 1000"` |

**Tests** (TDD — write these FIRST, watch them fail):
- Given missing capabilities, when POST /registry/register, then response includes `"message"` key with descriptive string
- Given empty capabilities list, when POST /registry/register, then response includes `"message"` containing "non-empty"
- Given invalid polling_timeout_ms, when POST /registry/register, then response includes `"message"` containing "5000"
- Given invalid polling_timeout_ms type, when POST /registry/register, then response includes `"message"` containing "integer"
- Given invalid registry token, when POST /registry/register, then response includes `"message"` key

**Implementation pattern** (apply to all 7 error clauses):
```elixir
# Before:
|> json(%{error: "capabilities_required"})

# After:
|> json(%{error: "capabilities_required", message: "capabilities must be a non-empty list of strings"})
```

**Commands**:
```bash
mix test test/viche_web/controllers/registry_controller_test.exs --trace
mix precommit
```

**Dependencies**: None

**Must NOT do**:
- Change error code strings
- Change HTTP status codes
- Add validation logic — only add `message` to response maps

**TDD Gates**:
- RED: Add test assertions for `"message"` key in register error responses → tests fail (no `message` in response)
- GREEN: Add `message` field to all 7 error `json()` calls in `do_register/3`
- VALIDATE: `mix precommit`

---

### Phase 2: RegistryController — deregister + discover errors (3 errors)

**Files**:
- `test/viche_web/controllers/registry_controller_test.exs` — Add `message` assertions + fix `"details"` → `"message"` in line 426
- `lib/viche_web/controllers/registry_controller.ex` — Add `message` to deregister errors (lines 100, 105), rename `details` → `message` in discover (line 130)

**Error → Message mapping**:
| Error Code | Message |
|-----------|---------|
| `agent_not_found` (deregister) | `"no agent found with the given ID"` |
| `not_owner` (deregister) | `"you do not own this agent"` |
| `invalid_token` (discover) | `"token must be 4-256 characters, alphanumeric with . _ -"` (rename `details` → `message`) |

**Tests** (TDD — write FIRST):
- Given non-existent agent, when DELETE /registry/deregister, then response includes `"message"` key
- Given agent owned by another user, when DELETE /registry/deregister, then response includes `"message"` containing "own"
- Given invalid token in discover, when GET /registry/discover, then response includes `"message"` key (not `"details"`)

**Breaking test fix**: Update line 426 from:
```elixir
assert %{"error" => "invalid_token", "details" => _} = json_response(conn, 422)
```
to:
```elixir
assert %{"error" => "invalid_token", "message" => _} = json_response(conn, 422)
```

**Commands**:
```bash
mix test test/viche_web/controllers/registry_controller_test.exs --trace
mix precommit
```

**Dependencies**: None

**Must NOT do**:
- Change the `query_required` error (it already has `message`)
- Change the `invalid_token` error code or HTTP status

**TDD Gates**:
- RED: Add `"message"` assertions for deregister errors + change `"details"` → `"message"` in discover test → tests fail
- GREEN: Add `message` to deregister errors, rename `details` → `message` in discover error response
- VALIDATE: `mix precommit`

---

### Phase 3: InboxController errors (2 errors)

**Files**:
- `test/viche_web/controllers/inbox_controller_test.exs` — Add `message` assertion to existing 404 test + add `not_owner` test
- `lib/viche_web/controllers/inbox_controller.ex` — Add `message` to errors at lines 28 and 33

**Error → Message mapping**:
| Error Code | Message |
|-----------|---------|
| `agent_not_found` | `"no agent found with the given ID"` |
| `not_owner` | `"you do not own this agent"` |

**Tests** (TDD — write FIRST):
- Given non-existent agent, when GET /inbox/:agent_id, then response includes `"message"` key
- Given agent owned by another user, when GET /inbox/:agent_id, then response includes `"message"` containing "own"

**Note**: The existing test at line 147-151 asserts `%{"error" => "agent_not_found"}` — this won't break (pattern match allows extra keys). The new test adds an explicit `"message"` assertion.

**Commands**:
```bash
mix test test/viche_web/controllers/inbox_controller_test.exs --trace
mix precommit
```

**Dependencies**: None

**Must NOT do**:
- Change drain/serialize logic
- Add message fields to success responses

**TDD Gates**:
- RED: Add test asserting `"message"` in 404 and 403 responses → tests fail
- GREEN: Add `message` field to both error `json()` calls in `handle_read_inbox/3`
- VALIDATE: `mix precommit`

---

### Phase 4: HeartbeatController + MessageController errors (2 errors)

**Files**:
- `test/viche_web/controllers/heartbeat_controller_test.exs` — Add `message` assertion to existing 404 test
- `lib/viche_web/controllers/heartbeat_controller.ex` — Add `message` to error at line 25
- `test/viche_web/controllers/message_controller_test.exs` — Add `message` assertion to existing 404 test
- `lib/viche_web/controllers/message_controller.ex` — Add `message` to `agent_not_found` error at line 44

**Error → Message mapping**:
| Error Code | Message |
|-----------|---------|
| `agent_not_found` (heartbeat) | `"no agent found with the given ID"` |
| `agent_not_found` (message) | `"no agent found with the given ID"` |

**Tests** (TDD — write FIRST):
- Given non-existent agent, when POST /agents/:id/heartbeat, then response includes `"message"` key
- Given non-existent recipient, when POST /messages/:id, then response includes `"message"` key

**Commands**:
```bash
mix test test/viche_web/controllers/heartbeat_controller_test.exs test/viche_web/controllers/message_controller_test.exs --trace
mix precommit
```

**Dependencies**: None

**Must NOT do**:
- Change the existing `invalid_message` response (it already has `message`)
- Add message fields to success responses

**TDD Gates**:
- RED: Add test asserting `"message"` in 404 responses → tests fail
- GREEN: Add `message` field to `agent_not_found` error in both controllers
- VALIDATE: `mix precommit`

---

## Risks and Mitigations

| Risk | Trigger | Mitigation |
|------|---------|------------|
| Breaking the `"details"` test | Renaming `details` → `message` in discover | Phase 2 explicitly updates the test assertion |
| Inconsistent `agent_not_found` messages | Same code used in 4 controllers | Use identical message string everywhere: `"no agent found with the given ID"` |
| Typo in message strings | Manual string entry | Tests assert on key presence; spot-check a few substring matches |

---

## Complete Error → Message Reference

For implementer convenience, here is the full mapping:

| Controller | Error Code | HTTP Status | Message |
|-----------|-----------|-------------|---------|
| RegistryController (register) | `capabilities_required` | 422 | `"capabilities must be a non-empty list of strings"` |
| RegistryController (register) | `invalid_capabilities` | 422 | `"every capability must be a string"` |
| RegistryController (register) | `invalid_name` | 422 | `"name must be a string or omitted"` |
| RegistryController (register) | `invalid_description` | 422 | `"description must be a string or omitted"` |
| RegistryController (register) | `invalid_registry_token` | 422 | `"each registry token must be 4-256 chars, alphanumeric/._-"` |
| RegistryController (register) | `invalid_polling_timeout` | 422 | `"polling_timeout_ms must be an integer >= 5000"` |
| RegistryController (register) | `invalid_grace_period` | 422 | `"grace_period_ms must be an integer >= 1000"` |
| RegistryController (deregister) | `agent_not_found` | 404 | `"no agent found with the given ID"` |
| RegistryController (deregister) | `not_owner` | 403 | `"you do not own this agent"` |
| RegistryController (discover) | `invalid_token` | 422 | `"token must be 4-256 characters, alphanumeric with . _ -"` |
| InboxController | `agent_not_found` | 404 | `"no agent found with the given ID"` |
| InboxController | `not_owner` | 403 | `"you do not own this agent"` |
| HeartbeatController | `agent_not_found` | 404 | `"no agent found with the given ID"` |
| MessageController | `agent_not_found` | 404 | `"no agent found with the given ID"` |

---

## Success Criteria

### Verification Commands
```bash
mix test test/viche_web/controllers/ --trace
mix precommit
```

### Final Checklist
- [ ] All 14 error responses include `message` field
- [ ] `details` renamed to `message` in discover `invalid_token`
- [ ] All tests pass including updated `"details"` → `"message"` assertion
- [ ] `mix precommit` passes clean
- [ ] No error codes changed
- [ ] No HTTP status codes changed
- [ ] AuthController untouched
