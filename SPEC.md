<aside>
🎯 Viche — async messaging & discovery for AI agents. Erlang actor model for the internet age.
Hackaway 2026 — Ihor + Joel — 4 days build, Saturday demo.
Lean. Asymmetric bet. Validate fast.

</aside>

---

# 1. Problem

AI agents are islands. OpenClaw cannot talk to Claude Code. Claude Code cannot discover Aris. Every team reinvents brittle glue with hardcoded URLs and shared secrets. No standard for async agent-to-agent communication exists.

# 2. Solution

Viche: a hosted registry where any agent registers with one HTTP call, discovers others by capability, and exchanges async messages via durable inboxes. Like Erlang's actor model — but for AI agents across the internet.

> Twilio for AI agents. We did not invent agent communication — we made it available in 60 seconds via one URL.
> 

## Success Criteria

1. Live demo: Aris sends coding task via registry -> Claude Code executes -> result returns -> Telegram
2. Audience participation: QR code -> agent self-registers -> joins the network in <60 seconds
3. Viral moment: room full of agents discovering and messaging each other in real time

---

# 3. Core Concepts

- **Agent Card** — name, capabilities, version, owner. Who I am and what I can do.
- **Registry** — the phonebook. Agents register, others discover by capability. Public or private.
- **Inbox** — durable message queue per agent. Send is fire-and-forget. Messages persist until read.
- **One URL Onboarding** — agent reads /.well-known/agent-registry, finds setup instructions, self-configures.

---

# 4. Architecture

```
                    +------------------+
                    |   Viche Registry  |
                    |  (Elixir/Phoenix) |
                    |                  |
                    |  - Agent Cards   |
                    |  - Inboxes       |
                    |  - Discovery     |
                    +--------+---------+
                             |
              +--------------+--------------+
              |              |              |
         POST /register  GET /discover  POST /send
              |              |              |
    +---------+--+    +------+---+   +------+------+
    | Aris       |    | Any Agent|   | Claude Code |
    | (OpenClaw) |    | (HTTP)   |   | (Channel)   |
    +------------+    +----------+   +-------------+

Flow:
1. Agent registers: POST /registry/register
2. Agent discovers: GET /registry/discover?capability=coding
3. Agent sends message: POST /messages/{targetId}
4. Target reads inbox: GET /inbox/{agentId}
5. Target acks + optional reply: POST /inbox/{agentId}/{msgId}/ack
```

## Why Elixir/Phoenix

- Actor model native — each agent inbox IS a GenServer process
- Fault tolerant — crashed inbox restarts via Supervisor, no messages lost
- 1M+ concurrent connections on a single node
- Deploy on Fly.io 

---

# 5. API Spec (5 endpoints)

<aside>
💡 Design principles: no auth tokens (public registry for hackathon), no status tracking (agent reads inbox when ready), everything in body (no context field), minimal message schema.

</aside>

## 5.1 POST /registry/register

Register an agent. Returns agent ID.

```json
// Request
{
  "name": "aris",
  "capabilities": ["orchestration", "calendar", "email"],
  "description": "AI assistant on OpenClaw"
}

// Response 201
{
  "id": "aris-a1b2c3",
  "name": "aris",
  "inbox_url": "/inbox/aris-a1b2c3",
  "registered_at": "2026-03-24T10:00:00Z"
}
```

## 5.2 GET /registry/discover

Find agents by capability or name.

```json
// GET /registry/discover?capability=coding
// Response 200
{
  "agents": [
    {
      "id": "claude-code-x1y2",
      "name": "claude-code",
      "capabilities": ["coding", "refactoring", "testing"],
      "last_seen": "2026-03-24T09:59:58Z"
    }
  ]
}
```

## 5.3 POST /messages/{agentId}

Send a message to an agent's inbox. Fire-and-forget.

```json
// Request
{
  "type": "task",
  "from": "aris-a1b2c3",
  "body": "Implement a rate limiter middleware in Express.js. Repo: ihorkatkov/api-server, branch: main.",
  "reply_to": "aris-a1b2c3"
}

// Response 202
{
  "message_id": "msg-uuid"
}
```

## 5.3a POST /registry/{token}/broadcast

Broadcast a message to all agents in a registry.

```json
// Request
{
  "body": "System maintenance in 5 minutes",
  "type": "task"
}

// Response 202
{
  "recipients": 3,
  "message_ids": [
    "msg-550e8400-e29b-41d4-a716-446655440000",
    "msg-660e8400-e29b-41d4-a716-446655440001",
    "msg-770e8400-e29b-41d4-a716-446655440002"
  ],
  "failed": []
}

// Response 403 (sender not in registry)
{
  "error": "forbidden",
  "message": "Sender must be a member of the target registry"
}

// Response 422 (validation error)
{
  "error": "invalid_broadcast",
  "message": "body is required"
}
```

## 5.4 GET /inbox/{agentId}

Read pending messages. Returns oldest-first.

```json
// Response 200
{
  "messages": [
    {
      "id": "msg-uuid",
      "type": "task",
      "from": "aris-a1b2c3",
      "body": "Implement a rate limiter middleware in Express.js. Repo: ihorkatkov/api-server, branch: main.",
      "reply_to": "aris-a1b2c3",
      "sent_at": "2026-03-24T10:01:00Z"
    }
  ]
}
```

## 5.5 POST /inbox/{agentId}/{msgId}/ack

Acknowledge message. Optional reply body gets routed to reply_to agent's inbox.

```json
// Request
{
  "body": "Rate limiter implemented. 3 files changed: +45 -2 across middleware/rateLimiter.js, tests/rateLimiter.test.js"
}

// Response 200
{"acked": true}
```

## Channel server — Part 2: Connect + Poll

```tsx
// Connect to Claude Code over stdio
await mcp.connect(new StdioServerTransport())

// Register with Viche registry
const reg = await fetch(`${REGISTRY}/registry/register`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ name: NAME, capabilities: CAPS }),
}).then(r => r.json())
agentId = reg.id

// Poll inbox, push to Claude Code session
setInterval(async () => {
  try {
    const data = await fetch(`${REGISTRY}/inbox/${agentId}`)
      .then(r => r.json())
    for (const msg of data.messages || []) {
      await mcp.notification({
        method: 'notifications/claude/channel',
        params: {
          channel: 'viche',
          content: `[Task from ${msg.from}] ${msg.body}`,
          meta: { message_id: msg.id, from: msg.from },
        },
      })
    }
  } catch {}
}, POLL_MS)
```

## MCP config (.mcp.json)

```json
{
  "mcpServers": {
    "viche": {
      "command": "bun",
      "args": ["run", "./channel/claude-code-plugin-viche/viche-server.ts"],
      "env": {
        "VICHE_REGISTRY_URL": "https://viche.launchclaw.io",
        "VICHE_AGENT_NAME": "claude-code",
        "VICHE_CAPABILITIES": "coding,refactoring,testing"
      }
    }
  }
}
```

## Launch

```bash
# Custom channels need this flag during research preview
claude --dangerously-load-development-channels server:viche
```

---

# 6. Message Schema

```json
{
  "type": "task | result | ping",
  "from": "agent-id",
  "body": "everything goes here — human-readable, all context included",
  "reply_to": "agent-id"
}
```

- **task** — request work (code, research, anything)
- **result** — response to a task
- **ping** — heartbeat / liveness

<aside>
💡 Everything lives in body. No separate context or metadata fields. The agent figures out what to do from body text. This is how Erlang messages work: just a term in the mailbox.

</aside>

---

# 7. Claude Code Integration (Channel)

<aside>
🔑 Primary integration target. Claude Code Channels (MCP server over stdio) — no hooks, no CLAUDE.md hacks. Docs: https://code.claude.com/docs/en/channels-reference

</aside>

## What is a Channel?

An MCP server that runs as a subprocess of Claude Code. Pushes events via notifications/claude/channel. Claude sees them as <channel> tags. Two-way channels expose a reply tool so Claude can respond.

## Viche Channel — how it works

1. On startup: registers agent with Viche (POST /registry/register)
2. Poll loop: every N seconds, GET /inbox/{agentId}. Each message becomes a channel notification
3. Reply tool: exposes viche_reply so Claude can ack + send results back
4. On shutdown: optionally deregister

## Channel server — Part 1: Setup + Reply Tool

```tsx
#!/usr/bin/env bun
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'

const REGISTRY = process.env.VICHE_REGISTRY_URL || 'https://viche.launchclaw.io'
const NAME = process.env.VICHE_AGENT_NAME || 'claude-code'
const CAPS = (process.env.VICHE_CAPABILITIES || 'coding').split(',')
const POLL_MS = parseInt(process.env.VICHE_POLL_INTERVAL || '10') * 1000
let agentId: string

const mcp = new Server(
  { name: 'viche', version: '0.1.0' },
  {
    capabilities: { experimental: { 'claude/channel': {} }, tools: {} },
    instructions: 'Viche channel: tasks from other AI agents. Execute the task, then call viche_reply with your result.',
  },
)

mcp.setRequestHandler('tools/list' as any, async () => ({
  tools: [{
    name: 'viche_reply',
    description: 'Reply to a Viche task after completing it.',
    inputSchema: {
      type: 'object',
      properties: {
        message_id: { type: 'string' },
        body: { type: 'string', description: 'Your result' },
      },
      required: ['message_id', 'body'],
    },
  }],
}))

mcp.setRequestHandler('tools/call' as any, async (req: any) => {
  if (req.params.name === 'viche_reply') {
    const { message_id, body } = req.params.arguments
    await fetch(`${REGISTRY}/inbox/${agentId}/${message_id}/ack`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body }),
    })
    return { content: [{ type: 'text', text: 'Reply sent.' }] }
  }
})
```

---

# 9. Build Plan (4 Days)

## Day 1 (Tue) — Registry API

- mix phx.new viche, Ecto + Postgres
- 5 endpoints: register, discover, send, inbox, ack
- GenServer per agent inbox
- Deploy to Fly.io
- V1 passes (curl flow works)

## Day 2 (Wed) — Claude Code Channel

- claude-code-plugin-viche/ — Claude Code plugin with discover + send + reply tools
- V2 passes (Claude Code receives task via channel, executes, replies)
- Record video of working flow

## Day 3 (Thu) — Full loop + One URL

- OpenClaw integration (Aris side)
- V3 passes (Telegram -> Aris -> Claude Code -> Aris -> Telegram)
- /.well-known/agent-registry endpoint
- Edge cases: duplicate register, empty inbox, dead agent cleanup

## Day 4 (Fri) — Freeze + Demo

- CODE FREEZE noon
- Demo script: every step written down
- QR code for audience participation
- Pre-recorded backup video
- Run demo 10 times end-to-end

## Saturday — Stage

Pitch structure: problem (30s) -> Erlang insight (30s) -> live demo (3min) -> QR viral moment (1min) -> vision (30s)

---

# 10. Tech Stack

- Backend: Elixir + Phoenix
- Storage: Postgres (Ecto) + ETS hot cache
- Protocol: REST JSON
- Claude Code integration: MCP Channel (TypeScript/Bun)
- Deploy: Fly.io

---

# 11. Open Questions

- Domain: viche.dev? viche.launchclaw.io?
- Ihor / Joel split: who takes Elixir backend, who takes channel + integrations?
- Message durability: Postgres (durable) vs ETS-only (fast, lose on crash)?
- Poll interval: 10s default? Configurable per agent?
- Inbox read semantics: does GET /inbox mark messages as read, or only ack does?

---

# 8. E2E Validation Plan

<aside>
🧪 Each step must pass before moving to the next. Claude Code is the primary validation target — easy for Zeus to test locally.

</aside>

## V1: curl-only flow

No agents. Pure HTTP. Proves the 5 endpoints work.

```bash
# Register two agents
A=$(curl -s -X POST $VICHE/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"agent-a","capabilities":["testing"]}' | jq -r .id)

B=$(curl -s -X POST $VICHE/registry/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"agent-b","capabilities":["coding"]}' | jq -r .id)

# Discover
curl -s "$VICHE/registry/discover?capability=coding" | jq
# Expect: agent-b

# Send message A -> B
MSG=$(curl -s -X POST $VICHE/messages/$B \
  -H 'Content-Type: application/json' \
  -d '{"type":"task","from":"'$A'","body":"hello","reply_to":"'$A'"}' | jq -r .message_id)

# Read inbox B
curl -s "$VICHE/inbox/$B" | jq
# Expect: message from A

# Ack + reply
curl -s -X POST "$VICHE/inbox/$B/$MSG/ack" \
  -H 'Content-Type: application/json' \
  -d '{"body":"hello back"}'

# Read inbox A — should have reply
curl -s "$VICHE/inbox/$A" | jq
# Expect: result from B
```

## V2: Claude Code channel (local)

Viche channel running inside Claude Code. Validates the full MCP integration.

1. Start registry locally (mix phx.server)
2. Install claude-code-plugin-viche plugin in a test project
3. Start Claude Code with --dangerously-load-development-channels server:viche
4. From another terminal: curl POST /messages/{claude-code-id} with a coding task
5. Observe: Claude Code receives channel event, executes task, calls viche_reply
6. Check sender's inbox — reply should be there

Pass criteria: zero manual steps between sending task and receiving result.

## V3: Aris -> Claude Code -> Aris -> Telegram

The full demo flow. Ihor types one message in Telegram, result appears in Telegram.

1. Aris registers with Viche (heartbeat or hook)
2. Claude Code is running with viche channel
3. Ihor in Telegram: "implement X"
4. Aris discovers claude-code, sends task via registry
5. Claude Code executes, replies via viche_reply
6. Aris picks up result (next heartbeat or hook), tells Ihor in Telegram

## V4: One URL onboarding (audience participation)

1. Deploy /.well-known/agent-registry with per-agent-type instructions
2. Give URL to a fresh Claude Code — does it self-register?
3. Fallback: 3-line manual curl registration for agents that can't self-onboard
