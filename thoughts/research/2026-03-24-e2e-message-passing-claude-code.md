---
date: 2026-03-24T00:00:00+00:00
researcher: mnemosyne
git_commit: HEAD
branch: main
repository: viche
topic: "E2E tests for message passing between Claude Code instances"
scope: channel/, scripts/, lib/viche_web/channels/, specs/
query_type: explain
tags: [research, e2e, message-passing, claude-code, mcp, channels]
status: complete
confidence: high
sources_scanned:
  files: 15
  thoughts_docs: 0
---

# Research: E2E Tests for Message Passing Between Claude Code Instances

**Date**: 2026-03-24
**Commit**: HEAD
**Branch**: main
**Confidence**: High - Multiple code sources confirm; implementation is complete and documented

## Query
Research the current state of e2e tests related to message passing between Claude Code instances in this codebase. Understand how messages are sent and received.

## Summary
The codebase has a complete E2E test infrastructure for message passing via the Viche registry. Messages are sent to Claude Code instances through an MCP channel server (`viche-channel.ts`) that bridges the Phoenix backend with Claude Code's stdio-based channel system. The channel server uses two mechanisms: HTTP polling of the inbox endpoint and Phoenix WebSocket channels for real-time push. Messages are delivered to Claude Code via MCP `notifications/claude/channel` notifications.

## Key Entry Points

| File | Symbol | Purpose |
|------|--------|---------|
| `scripts/e2e-v2-channel-test.sh:1-234` | (shell script) | Main E2E test script for channel integration |
| `channel/viche-channel.ts:1-424` | `main()` | MCP server that bridges Viche with Claude Code |
| `lib/viche/agents.ex:109-139` | `send_message/1` | Core message sending logic with broadcast |
| `lib/viche_web/channels/agent_channel.ex:1-85` | `AgentChannel` | Phoenix channel for real-time agent communication |
| `.mcp.json:1-14` | (config) | MCP server configuration for Claude Code |

## Architecture & Flow

### Message Sending Flow
```
External Agent (curl/HTTP)
    │
    ▼
POST /messages/{agentId}
    │
    ▼
Viche.Agents.send_message/1 (lib/viche/agents.ex:109)
    │
    ├──► AgentServer.receive_message/2 (stores in inbox)
    │
    └──► VicheWeb.Endpoint.broadcast("agent:{id}", "new_message", payload)
              │
              ▼
         Phoenix Channel (WebSocket push to connected clients)
```

### Message Receiving Flow (Claude Code)
```
viche-channel.ts (MCP Server)
    │
    ├──► HTTP Polling: GET /inbox/{agentId} every N seconds
    │         │
    │         └──► fireMessageNotification() → notifications/claude/channel
    │
    └──► WebSocket: Phoenix Channel "agent:{agentId}"
              │
              └──► on("new_message") → fireMessageNotification()
                        │
                        ▼
                   Claude Code receives <channel> tag notification
```

### Key Interfaces

| Interface/Type | Location | Used By |
|----------------|----------|---------|
| `InboxMessage` | `channel/viche-channel.ts:45-49` | Poll loop, WebSocket handler |
| `Message.t()` | `lib/viche/message.ex` | AgentServer, Agents context |
| `notifications/claude/channel` | MCP SDK | Claude Code channel system |

## Message Delivery Mechanisms

### 1. HTTP Polling (Primary)
- **Location**: `channel/viche-channel.ts:144-169`
- **Interval**: Configurable via `VICHE_POLL_INTERVAL` env var (default 5 seconds)
- **Endpoint**: `GET /inbox/{agentId}` - auto-consumes messages (Erlang receive semantics)
- **Behavior**: Poll loop runs forever, fetches inbox, fires MCP notifications for each message

### 2. Phoenix WebSocket Channel (Real-time)
- **Location**: `channel/viche-channel.ts:189-216`
- **Topic**: `agent:{agentId}`
- **Event**: `new_message` pushed when message arrives
- **Behavior**: Immediate push notification when message is sent

### 3. MCP Notification to Claude Code
- **Location**: `channel/viche-channel.ts:122-140`
- **Method**: `notifications/claude/channel`
- **Format**: `[Task from {msg.from}] {msg.body}`
- **Meta**: `{ message_id, from }`

## E2E Test Script Details

**File**: `scripts/e2e-v2-channel-test.sh`

### Test Steps:
1. **Step 0** (line 100-119): Start Phoenix server in background
2. **Step 1** (line 121-138): Start channel server with env vars
3. **Step 2** (line 140-148): Verify channel server process is alive
4. **Step 3** (line 154-164): Verify `claude-code` registered via `/registry/discover`
5. **Step 4** (line 166-174): Register external `aris` agent
6. **Step 5** (line 176-184): Send task from aris → claude-code
7. **Step 6** (line 186-193): Wait for channel server to poll
8. **Step 7** (line 195-199): Verify inbox was consumed (should be empty)
9. **Step 8** (line 201-216): Test viche_reply - send result back to aris

### Environment Variables Used:
- `VICHE_REGISTRY_URL`: http://localhost:4000
- `VICHE_AGENT_NAME`: claude-code
- `VICHE_CAPABILITIES`: coding,refactoring,testing
- `VICHE_DESCRIPTION`: Claude Code AI coding assistant
- `VICHE_POLL_INTERVAL`: 2 (seconds)

## Configuration

### .mcp.json (Claude Code MCP Config)
```json
{
  "mcpServers": {
    "viche": {
      "command": "bun",
      "args": ["run", "./channel/viche-channel.ts"],
      "env": {
        "VICHE_REGISTRY_URL": "http://localhost:4000",
        "VICHE_CAPABILITIES": "coding,refactoring,testing",
        "VICHE_AGENT_NAME": "claude-code",
        "VICHE_DESCRIPTION": "Claude Code AI coding assistant"
      }
    }
  }
}
```

## Related Components

### Phoenix Backend
- `lib/viche/agents.ex:126-132` - Broadcasts `new_message` event after storing message
- `lib/viche_web/channels/agent_channel.ex:46-54` - Handles `send_message` channel event
- `lib/viche_web/channels/agent_socket.ex:17-19` - Requires `agent_id` param for connection

### MCP Tools Exposed
- `viche_discover` - Find agents by capability
- `viche_send` - Send message to another agent
- `viche_reply` - Reply to a task (sends `result` type message)

## Gaps Identified

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| No automated test for Claude Code actually reading notifications | "auto.*read", "notification.*read", "claude.*read" | `channel/`, `scripts/`, `test/` |
| No test verifying MCP notification format is correct | "notifications/claude/channel", "test" | `channel/`, `test/` |
| No documentation on Claude Code's channel notification handling | "channel notification", "claude code" | `specs/`, `SPEC.md` |
| No unit tests for viche-channel.ts | "test", "spec", "jest", "vitest" | `channel/` |
| thoughts/ directory did not exist | N/A | project root |

### Critical Gap: Auto-Reading Messages

The user reports that "when messages are sent, the Claude Code instance doesn't read them automatically." Based on the code analysis:

1. **The channel server correctly sends MCP notifications** (`channel/viche-channel.ts:127-139`)
2. **The notification format follows Claude Code's channel spec** (`notifications/claude/channel`)
3. **However**: There is no evidence in the codebase of how Claude Code processes these notifications

The gap is likely in Claude Code's behavior, not the Viche implementation. The MCP notification is sent, but:
- Claude Code may require user interaction to process channel notifications
- The `--dangerously-load-development-channels` flag may affect behavior
- Channel notifications may appear as `<channel>` tags but not trigger automatic action

**Reference**: `specs/06-channel-server.md:9-10` states:
> Channels are MCP servers over stdio that push events via `notifications/claude/channel`. Claude sees them as `<channel>` tags.

This suggests Claude Code displays the notification but does not automatically act on it.

## Evidence Index

### Code Files
- `channel/viche-channel.ts:122-140` - MCP notification firing logic
- `channel/viche-channel.ts:144-169` - HTTP polling implementation
- `channel/viche-channel.ts:189-216` - WebSocket connection and handler
- `channel/viche-channel.ts:238-252` - MCP server setup with channel capability
- `lib/viche/agents.ex:109-139` - Message sending with broadcast
- `lib/viche_web/channels/agent_channel.ex:46-54` - Channel send_message handler
- `scripts/e2e-v2-channel-test.sh:1-234` - Full E2E test script

### Documentation
- `specs/06-channel-server.md` - Channel server specification
- `specs/04-inbox.md` - Inbox read/consume semantics
- `SPEC.md:258-323` - Claude Code integration overview
- `.mcp.json` - MCP server configuration

### External
- Claude Code Channels reference: https://code.claude.com/docs/en/channels-reference

## Related Research

No prior research documents found in `thoughts/` directory (directory did not exist).

---

## Handoff Inputs

**If planning needed** (for @prometheus):
- Scope: MCP channel server, Claude Code notification handling
- Entry points: `channel/viche-channel.ts`, `.mcp.json`
- Constraints: Claude Code's channel notification behavior is external/undocumented
- Open questions: Does Claude Code require explicit user action to process channel notifications? Is there a way to make notifications trigger automatic action?

**If implementation needed** (for @vulkanus):
- Test location: `scripts/e2e-v2-channel-test.sh` (shell-based E2E)
- Pattern to follow: Existing E2E script structure
- Entry point: `channel/viche-channel.ts:122-140` (notification logic)
