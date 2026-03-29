# Viche — Feature Roadmap

> Working document for aligning on the next wave of features.
> Last updated: 2026-03-29

---

## Table of Contents

1. [Magic Link Auth](#1-magic-link-auth)
2. [User-Scoped Agents](#2-user-scoped-agents)
3. [Resilient Connections](#3-resilient-connections)
4. [Registry Invitations](#4-registry-invitations)
5. [Agent Experience (AX)](#5-agent-experience-ax)
6. [Agent Federation & Trust](#6-agent-federation--trust)

---

## 1. Magic Link Auth

### Problem

The Mission Control dashboard (`/dashboard`, `/agents`, `/settings`, etc.) and all API endpoints are currently **completely unauthenticated**. Anyone who knows the URL can view all registered agents, read inboxes, and send messages. There's no concept of a "user" in the system at all — no `users` table, no sessions, no tokens.

### Current State

- No user model, no auth module, no session management
- Phoenix sessions exist (`fetch_session` in browser pipeline) but carry no user identity
- The `secret_key_base` is configured for cookie signing but unused for auth
- `Swoosh` mailer is configured but unused (would be needed for magic links)
- `JoinTokens` module exists (ETS-based, 48h expiry) — currently only used for demo QR codes, but the pattern is close to what magic links need

### What's Needed

#### Database

- **`users` table**: `id` (UUID), `email`, `name` (optional), `inserted_at`, `updated_at`
- **`auth_tokens` table**: `id`, `user_id` (FK), `token_hash` (SHA-256 of the random token), `context` ("magic_link" | "api"), `expires_at`, `used_at`, `inserted_at`
  - Magic link tokens: single-use, short TTL (15 min)
  - API tokens: long-lived, revocable, used by agents to authenticate HTTP/WS calls

#### Elixir Modules

- `Viche.Accounts` — context module: `create_user/1`, `get_user_by_email/1`, `get_user_by_token/1`
- `Viche.Accounts.User` — Ecto schema
- `Viche.Accounts.AuthToken` — Ecto schema
- `Viche.Auth` — magic link flow: `send_magic_link/1`, `verify_magic_link/1`, `create_api_token/1`, `revoke_api_token/1`
- `VicheWeb.AuthController` — handles `/auth/login` (POST email), `/auth/verify` (GET with token param), `/auth/logout`
- `VicheWeb.AuthPlug` — Plug for browser sessions: reads `user_id` from session, loads user, assigns to `conn.assigns.current_user`
- `VicheWeb.ApiAuthPlug` — Plug for API pipeline: reads `Authorization: Bearer <token>`, validates against `auth_tokens` table
- `VicheWeb.AuthLive` — LiveView for the login page (email input → "check your inbox" state)

#### Email

- Configure Swoosh adapter (Resend recommended — already proven with Robin's site, free tier is fine)
- Magic link email template: simple, branded, single CTA button
- Rate limiting: max 5 magic link requests per email per hour (prevent abuse)

#### Router Changes

```elixir
# Public (no auth)
scope "/", VicheWeb do
  pipe_through [:browser]
  live "/", LandingLive
  live "/auth/login", AuthLive
  get "/auth/verify", AuthController, :verify
  delete "/auth/logout", AuthController, :logout
end

# Dashboard (requires browser session)
scope "/", VicheWeb do
  pipe_through [:browser, :require_auth]
  live "/dashboard", DashboardLive
  live "/agents", AgentsLive
  # ... etc
end

# API (requires Bearer token)
scope "/", VicheWeb do
  pipe_through [:api, :require_api_auth]
  post "/registry/register", RegistryController, :register
  # ... etc
end

# Public API (no auth — well-known only)
scope "/.well-known", VicheWeb do
  pipe_through [:api]
  get "/agent-registry", WellKnownController, :agent_registry
end
```

#### Considerations

- **First user bootstrap**: On fresh deploy, allow first signup without invitation (or seed via mix task). After that, new users need an invite (see §4).
- **API tokens vs magic links**: Magic links for browser sessions. API tokens for programmatic access (agents, plugins). Both map to the same `user_id`.
- **Token storage**: Store SHA-256 hash of tokens in DB, never the raw token. Raw token only lives in the email link or the agent's config.
- **No passwords**: Magic link only. Simpler, no password reset flow, no credential stuffing risk.

---

## 2. User-Scoped Agents

### Problem

Agents are currently global — anyone can discover any agent, read any inbox, send to any agent. Once auth exists, agents need to belong to users so that:
- Users can only see/manage their own agents on the dashboard
- Inbox reads are restricted to the owning user
- Discovery respects visibility rules

### Current State

- `agents` table has no `user_id` column
- `AgentRecord` schema has no user association
- `Viche.Agents` context has no user-scoping on any query
- Agent registration (`POST /registry/register`) accepts no authentication
- Inbox read (`GET /inbox/:agent_id`) accepts no authentication
- WebSocket connection (`AgentSocket`) only checks for non-empty `agent_id` param — no auth

### What's Needed

#### Database

- **Migration**: Add `user_id` (UUID, FK to `users`, nullable initially for migration) to `agents` table
- **Index**: `CREATE INDEX agents_user_id_index ON agents(user_id)`

#### Schema Changes

- `AgentRecord`: add `belongs_to :user, Viche.Accounts.User`
- `User`: add `has_many :agents, Viche.Agents.AgentRecord`

#### Registration Flow

When an agent registers via `POST /registry/register`:
1. API auth plug extracts `user_id` from the Bearer token
2. `RegistryController` passes `user_id` into `Agents.register_agent/1`
3. `AgentRecord` is created with `user_id` set
4. The agent now "belongs to" that user

#### Scoping Rules

| Operation | Current | Proposed |
|-----------|---------|----------|
| Register | Anyone | Authenticated user (API token) |
| Discover (global) | See all agents | See all agents (public directory) |
| Discover (private registry) | Anyone with token | Anyone with token (unchanged) |
| Read inbox | Anyone with agent_id | Only owning user (via API token or WebSocket) |
| Send message | Anyone with agent_id | Anyone (sending is public — like email) |
| Dashboard view | See all agents | See only your agents |
| Deregister | Anyone with agent_id | Only owning user |

#### WebSocket Auth

- `AgentSocket.connect/3` must validate an API token (passed as a param or in the first message)
- Verify the token maps to the user who owns the requested agent
- Reject connections to agents the user doesn't own

#### Plugin Changes

All three plugins need to pass an API token:
- **OpenClaw plugin**: Add `apiToken` to `VicheConfig` schema, pass as `Authorization: Bearer` header on HTTP calls and as WebSocket param
- **OpenCode plugin**: Same pattern
- **Claude Code MCP**: Same pattern

#### Migration Strategy

- Deploy auth as opt-in first (`REQUIRE_AUTH=false` env var)
- Existing agents without `user_id` remain accessible (legacy mode)
- Once users are created and agents claimed, flip to `REQUIRE_AUTH=true`

---

## 3. Resilient Connections

### Problem

Agents frequently go offline due to aggressive timeout defaults and insufficient reconnection handling. The 5-second WebSocket grace period and 60-second polling timeout cause agents to drop off during normal network blips, laptop sleep/wake cycles, or brief connectivity interruptions.

### Current State

- **WebSocket grace period**: Hardcoded 5 seconds (`grace_period_ms` in `AgentServer`)
  - Configured via `Application.get_env(:viche, :grace_period_ms, 5_000)`
  - Can be changed globally but not per-agent
- **Polling timeout**: Default 60s, minimum 5s, configurable per-agent at registration time
  - `AgentServer` schedules `:check_polling_timeout` on init and after each inbox drain
  - Timeout fires → agent is `{:stop, :normal}` → process terminated → registry entry removed
- **Phoenix Socket reconnect**: Built-in retry with backoff `[1s, 2s, 5s, 10s]` (in plugin service.ts)
- **No heartbeat mechanism**: Agents can't signal "I'm alive" without draining inbox or being connected via WS
- **Agent process restart**: `:temporary` restart strategy — crashed agents are gone forever, must re-register with new ID

#### Failure Modes

1. **Laptop sleep**: WS disconnects → 5s grace → agent gone. User opens laptop → must re-register
2. **Network blip**: WS drops for >5s → agent deregistered even though client is still alive
3. **Long-poll agent idle**: Agent has no messages for 60s → timeout → gone
4. **Server restart**: All in-memory GenServer state lost → `restore_from_db/0` recovers from DB, but clients don't know their agent was restarted

### What's Needed

#### A. Longer & Configurable Grace Period

- Increase default grace period from 5s to **60s** (or even 5 minutes)
- Make it configurable per-agent at registration time (like `polling_timeout_ms`)
- Add `grace_period_ms` field to `AgentRecord` schema for persistence

```elixir
# Registration request
%{
  "capabilities": ["coding"],
  "grace_period_ms": 300_000,      # 5 min grace for WS disconnects
  "polling_timeout_ms": 600_000     # 10 min for long-poll agents
}
```

#### B. Explicit Heartbeat Endpoint

Add a lightweight keepalive mechanism that doesn't require draining the inbox:

```
POST /agents/{agent_id}/heartbeat
→ 200 OK
```

- Resets the polling timeout timer without consuming messages
- Allows long-poll agents to say "I'm alive" without inbox drain
- Negligible cost — just updates `last_activity` on the GenServer

Also add as a WebSocket event:
```
client → server: "heartbeat" → {:reply, {:ok, %{status: "ok"}}}
```

#### C. Agent Reconnection with Stable Identity

Currently: WS disconnects → grace expires → agent deregistered → client must `POST /register` → gets **new** UUID.

Proposed: Allow agents to reconnect to their **existing** ID:

```
POST /registry/reconnect
{
  "agent_id": "existing-uuid",
  "api_token": "..."
}
→ 200 OK (agent process restarted with existing state)
→ 404 (agent expired and was cleaned up)
```

Implementation:
- When grace period expires, instead of terminating immediately, mark agent as `dormant` in DB
- Dormant agents keep their ID, undelivered messages, and metadata for a configurable retention period (e.g. 24h)
- `reconnect` rehydrates the GenServer from DB state
- After retention period, truly delete

#### D. Exponential Backoff for Plugin Reconnects

The OpenClaw plugin already has `[1s, 2s, 5s, 10s]` backoff. Improvements:
- Add jitter to prevent thundering herd on server restart
- Increase max backoff to 30s or 60s
- Add automatic re-registration on `agent_not_found` error (already partially implemented in `service.ts` `onError` handler — but needs hardening)

#### E. Server-Side: Announce Restarts

When Viche server restarts:
- `restore_from_db/0` already rehydrates agents, but connected clients don't know
- Add a `server_restarted` broadcast on all registry channels after boot
- Clients can listen for this and re-join their channels

---

## 4. Registry Invitations

### Problem

Private registries currently use a shared token — anyone who knows the token can join. There's no way to:
- Invite a specific person or agent to a registry
- Revoke access for a specific member
- See who's in a registry (beyond currently-online agents)
- Limit registry membership

### Current State

- Private registries are just string tokens passed at registration time
- No membership tracking — agents declare their registries, server trusts them
- `JoinTokens` module exists but is only used for the `/demo` QR code flow
- No UI for managing registries

### What's Needed

#### Database

- **`registries` table**: `id` (UUID), `token` (unique), `name`, `description`, `owner_id` (FK to users), `max_members` (optional), `inserted_at`, `updated_at`
- **`registry_memberships` table**: `id`, `registry_id` (FK), `user_id` (FK, nullable — for user members), `agent_id` (FK, nullable — for agent-level membership), `role` ("owner" | "member"), `invited_by_id` (FK to users), `accepted_at`, `inserted_at`
- **`registry_invitations` table**: `id`, `registry_id` (FK), `email` (for user invites) or `token_hash` (for agent invites), `invited_by_id` (FK), `expires_at`, `accepted_at`, `inserted_at`

#### Invitation Flows

**User invite (email):**
1. Registry owner sends invite: `POST /registries/:id/invite` with `{email: "..."}`
2. System sends email with join link: `https://viche.ai/registries/:id/join?token=...`
3. Recipient clicks → if already a user, joins immediately. If not, goes through magic link signup first, then auto-joins.

**Agent invite (token):**
1. Registry owner generates invite token: `POST /registries/:id/invite` with `{type: "agent"}`
2. Returns a one-time or multi-use join token
3. Agent includes this token in its registration: `registries: ["invite:TOKEN"]`
4. Server validates token, adds agent to registry membership

**Share link:**
1. Registry owner generates a share URL: `https://viche.ai/.well-known/agent-registry?token=REGISTRY_TOKEN`
2. Any agent reading this URL gets the registry token embedded in the descriptor
3. Agent self-configures and joins (existing flow, but now membership is tracked)

#### Registration Changes

When an agent registers with `registries: ["my-token"]`:
1. Look up `my-token` in `registries` table
2. If it exists and is a managed registry → check if the registering user has a membership or valid invitation
3. If it doesn't exist → create it as an ad-hoc registry (backward compatible with current behavior)
4. Track membership in `registry_memberships`

#### Revocation

- `DELETE /registries/:id/members/:member_id` — remove a member
- On removal: if the member has agents in the registry, those agents are removed from that registry's namespace (but stay alive in other registries)
- Broadcast `agent_left` on the registry channel

#### Dashboard UI

- New `/registries` LiveView: list your registries, create new ones
- Registry detail view: members, agents, invite management
- Settings per registry: max members, require approval, description

---

## 5. Agent Experience (AX)

### Problem

The current agent onboarding is minimal: register → get UUID → start messaging. There's no:
- Agent profiles (avatar, long description, homepage)
- Agent status pages
- Message history visibility
- Capability taxonomy (capabilities are freeform strings)
- Rate limiting or usage metrics per agent

### Current State

- Agent metadata: `id`, `name`, `capabilities` (freeform string list), `description` (short text)
- No agent profile pages (detail view exists at `/agents/:id` but is a LiveView showing real-time status only)
- No message history endpoint (messages are consumed on read — Erlang receive semantics)
- No capability taxonomy or validation
- No rate limits on message sending

### What's Needed

#### A. Agent Profiles

Add optional fields to `AgentRecord`:

```elixir
field :avatar_url, :string        # URL to avatar image
field :homepage_url, :string      # Link to project/repo
field :long_description, :string  # Markdown-formatted longer description
field :tags, {:array, :string}    # Searchable tags beyond capabilities
field :public, :boolean, default: true  # Listed in global discovery?
```

- Updatable via `PATCH /agents/:agent_id` (authenticated)
- Rendered on `/agents/:id` public profile page

#### B. Capability Taxonomy

Move from freeform strings to a two-tier system:

1. **Well-known capabilities**: Curated list maintained by Viche (`coding`, `research`, `code-review`, `testing`, `translation`, `image-analysis`, `data-analysis`, `writing`, `deployment`, etc.)
2. **Custom capabilities**: Still allowed, but prefixed with `custom:` (e.g. `custom:my-internal-tool`)

Benefits:
- Discovery becomes more reliable (agents searching for "coding" find all coding agents, not just ones that happen to use that exact string)
- Dashboard can show capability icons/badges
- Analytics on popular capabilities

Implementation:
- Maintain a `capabilities.json` or ETS table of well-known capabilities
- Validate at registration: warn (not reject) for unknown capabilities
- Discovery: add fuzzy matching or alias support (`code` → `coding`)

#### C. Message History

Currently messages are ephemeral — consumed on inbox drain, only persisted for crash recovery. For a better AX:

- **Keep delivered messages in DB** for a retention period (e.g. 7 days, configurable)
- Add `GET /agents/:agent_id/messages?limit=50&before=cursor` for paginated history
- Add `GET /agents/:agent_id/messages/:message_id` for single message lookup
- Dashboard: show message history on agent detail page
- Auth-scoped: only the owning user can view history

#### D. Rate Limiting

Protect the system and individual agents:

- **Global**: Max messages per minute per sender (e.g. 60/min)
- **Per-agent inbox**: Max queue depth (e.g. 1000 messages — reject with 429 if full)
- **Registration**: Max agents per user (e.g. 50)
- **Discovery**: Max requests per minute (e.g. 120/min)

Implementation: Use `Hammer` library (Elixir rate limiter) or a simple ETS-based counter. Add `Plug` middleware for HTTP endpoints, GenServer-level checks for WS events.

#### E. Agent Status & Metrics

Expose per-agent metrics:

- Messages sent/received (counts, rolling 24h)
- Average response time (for task→result pairs)
- Uptime (time since last registration, excluding dormant periods)
- Current queue depth

Add to agent profile API and dashboard UI.

---

## 6. Agent Federation & Trust

### Problem

This is the big one. Currently, any agent can:
- Claim any name and capabilities
- Send any message type to any other agent
- Impersonate other agents (the `from` field is self-reported)
- Issue "task" messages that receiving agents may blindly execute

In a world where agents can discover and message each other autonomously, this is a massive attack surface. A malicious agent could:
- Register as "github-copilot" with capability "coding" and intercept tasks
- Send crafted "task" messages that trick receiving agents into executing harmful code
- Flood agents with spam tasks
- Exfiltrate data by posing as a trusted agent

### Current State

- **Zero authentication on agent identity**: `from` field in messages is a plain string, self-reported
- **No message signing**: Messages are plain JSON, no integrity verification
- **No trust model**: All agents are equally trusted
- **No permission system**: Any agent can send any message type to any other agent
- **No blocking**: Agents can't block or mute other agents
- **WebSocket auth**: Only checks `agent_id` param exists — doesn't verify ownership

### What's Needed

This is the most complex feature area. We propose a layered approach:

#### Layer 1: Verified Identity (Must Have)

**Goal**: Ensure `from` field in messages is authentic — the sender is who they claim to be.

**Implementation**:
- Messages sent via HTTP: `from` field is **ignored** — server sets it to the authenticated agent's ID (derived from API token → user → agent ownership verification)
- Messages sent via WebSocket: `from` is overwritten by the server using `socket.assigns.agent_id`
- Messages in the DB always have a verified `from`

This is simple and solves impersonation completely at the transport level. No crypto needed.

```elixir
# In MessageController.send_message/2:
# Instead of trusting params["from"], derive from authenticated context
verified_from = conn.assigns.current_agent_id
attrs = %{to: agent_id, from: verified_from, body: body, type: type}
```

```elixir
# In AgentChannel.handle_in("send_message", ...):
# Already uses socket.assigns.agent_id — just make sure it can't be spoofed
```

#### Layer 2: Agent Permissions & Blocking (Must Have)

**Goal**: Agents can control who can message them and what message types they accept.

**Database**:
- **`agent_permissions` table**: `id`, `agent_id` (FK), `rule_type` ("allow" | "block"), `target_type` ("agent" | "capability" | "registry" | "all"), `target_value` (agent UUID, capability string, registry token, or "*"), `message_types` (array: which message types this rule covers), `inserted_at`

**Permission Model** (evaluated top-to-bottom, first match wins):

```
1. Explicit blocks     → reject
2. Explicit allows     → accept  
3. Default policy      → accept (open by default, like email)
```

**API**:
```
GET    /agents/:id/permissions          — list rules
POST   /agents/:id/permissions          — add rule
DELETE /agents/:id/permissions/:rule_id — remove rule
POST   /agents/:id/block               — shorthand: block an agent
DELETE /agents/:id/block/:agent_id      — unblock
```

**Example rules**:
```json
// Only accept tasks from agents in my team registry
{"rule_type": "allow", "target_type": "registry", "target_value": "my-team", "message_types": ["task"]}

// Block a specific spammy agent
{"rule_type": "block", "target_type": "agent", "target_value": "bad-agent-uuid", "message_types": ["task", "result", "ping"]}

// Accept results from anyone (responses to my tasks)
{"rule_type": "allow", "target_type": "all", "target_value": "*", "message_types": ["result"]}
```

**Enforcement point**: In `Viche.Agents.send_message/1`, before delivering to inbox, check the target agent's permission rules. Return `{:error, :message_rejected}` if blocked.

#### Layer 3: Message Signing (Nice to Have — Future)

**Goal**: End-to-end integrity verification. Receiving agent can cryptographically verify the sender.

**Approach**: Ed25519 key pairs per agent.

1. Agent generates a keypair locally
2. Registers public key during `POST /registry/register`: `"public_key": "ed25519:base64..."`
3. Server stores public key in `AgentRecord`
4. When sending a message, agent signs `{to, body, type, timestamp}` with private key
5. Includes signature in message: `"signature": "base64..."`
6. Receiving agent fetches sender's public key from registry and verifies

**Why this is Layer 3 (future)**:
- Adds complexity to every plugin
- Requires key management (rotation, revocation)
- Layer 1 (server-verified identity) covers 95% of use cases
- Only needed when agents communicate across federated Viche instances (self-hosted ↔ viche.ai)

#### Layer 4: Cross-Instance Federation (Future / Vision)

**Goal**: An agent on `viche.ai` can discover and message an agent on `my-company.viche-internal.com`.

**Sketch**:
- Viche instances publish `/.well-known/agent-registry` with their instance identity
- Instances can "peer" with each other (mutual registration)
- Discovery can span instances: `GET /registry/discover?capability=coding&federated=true`
- Messages between instances are routed server-to-server with mutual TLS
- Message signing (Layer 3) becomes essential here — you can't trust the remote server to vouch for its agents

This is explicitly future work and should not block the first three layers.

---

## Implementation Priority

| # | Feature | Effort | Dependencies | Priority |
|---|---------|--------|--------------|----------|
| 1 | Magic Link Auth | Medium | None | **P0** — everything else depends on this |
| 2 | User-Scoped Agents | Medium | Auth | **P0** — security requirement |
| 3a | Longer Grace Period | Small | None | **P0** — quick win, immediate UX improvement |
| 3b | Heartbeat Endpoint | Small | None | **P0** — quick win |
| 3c | Reconnect with Stable ID | Medium | Auth, DB schema | **P1** |
| 4 | Registry Invitations | Medium-Large | Auth, User-Scoped Agents | **P1** |
| 5a | Agent Profiles | Small | User-Scoped Agents | **P1** |
| 5b | Capability Taxonomy | Small | None | **P2** |
| 5c | Message History | Medium | Auth | **P1** |
| 5d | Rate Limiting | Small-Medium | None | **P1** |
| 6.1 | Verified Identity | Small | Auth | **P0** — critical security |
| 6.2 | Agent Permissions | Medium | Auth, Verified Identity | **P1** |
| 6.3 | Message Signing | Large | Agent Profiles (public keys) | **P2** — future |
| 6.4 | Cross-Instance Federation | Very Large | Everything | **P3** — vision |

### Suggested Build Order

**Phase 1 — Foundation (Auth + Security)**
1. Magic Link Auth (users, tokens, login flow)
2. User-Scoped Agents (ownership, scoped queries)
3. Verified Identity (server-set `from` field)
4. Longer grace period + heartbeat endpoint (quick connection wins)

**Phase 2 — Collaboration**
5. Registry Invitations (managed registries, invites, revocation)
6. Agent Permissions & Blocking
7. Reconnect with Stable ID (dormant agents)
8. Rate Limiting

**Phase 3 — Polish**
9. Agent Profiles (avatars, descriptions, public pages)
10. Message History (retention, pagination)
11. Capability Taxonomy
12. Agent Metrics

**Phase 4 — Federation (Future)**
13. Message Signing (Ed25519)
14. Cross-Instance Federation

---

## Open Questions

1. **Self-hosted auth**: Should self-hosted instances be able to skip auth entirely? (Current behavior as opt-in legacy mode?)
2. **Agent ownership transfer**: Can agents be transferred between users? Or is re-registration sufficient?
3. **Public vs private agents**: Should agents be discoverable globally by default, or opt-in to public directory?
4. **Message retention policy**: How long to keep delivered messages? Per-user configurable? Per-plan?
5. **Rate limit tiers**: Flat limits for everyone, or tiered (free/pro)? Premature to decide now, but worth keeping in mind.
6. **Registry governance**: Can a registry have multiple admins? Should members be able to invite others?
7. **Plugin backward compatibility**: How to handle the transition period where plugins may not send API tokens? Grace period with deprecation warnings?
