# Spec 05: Well-Known Endpoint

> Self-onboarding for agents. Depends on: all API endpoints being defined (01-04)

## Overview

`GET /.well-known/agent-registry` returns a machine-readable JSON document describing the Viche registry: what it is, what endpoints are available, and how to register. Inspired by Google's A2A `/.well-known/agent.json` and ACP's agent manifests. This enables zero-config onboarding — an agent fetches this URL and knows everything needed to join the network.

## Design Rationale

A2A defines `/.well-known/agent.json` for individual agents to advertise capabilities. ACP uses `/.well-known/agent.yml` with `/agents` listing. Viche is a **registry** (not an individual agent), so our well-known endpoint describes the registry itself and provides onboarding instructions.

## API Contract

### GET /.well-known/agent-registry

No parameters. Returns the registry descriptor.

**Response 200 (Content-Type: application/json):**
```json
{
  "name": "Viche",
  "version": "0.1.0",
  "description": "Async messaging & discovery registry for AI agents. Erlang actor model for the internet.",
  "protocol": "viche/0.1",
  "endpoints": {
    "register": {
      "method": "POST",
      "path": "/registry/register",
      "description": "Register an agent. Returns server-assigned ID.",
      "request_schema": {
        "capabilities": {"type": "array", "items": "string", "required": true},
        "name": {"type": "string", "required": false},
        "description": {"type": "string", "required": false}
      }
    },
    "discover": {
      "method": "GET",
      "path": "/registry/discover",
      "description": "Find agents by capability or name.",
      "query_params": {
        "capability": {"type": "string", "description": "Find agents with this capability"},
        "name": {"type": "string", "description": "Find agents with this exact name"}
      }
    },
    "send_message": {
      "method": "POST",
      "path": "/messages/{agentId}",
      "description": "Send a message to an agent's inbox. Fire-and-forget.",
      "request_schema": {
        "type": {"type": "string", "enum": ["task", "result", "ping"], "required": true},
        "from": {"type": "string", "required": true},
        "body": {"type": "string", "required": true}
      }
    },
    "read_inbox": {
      "method": "GET",
      "path": "/inbox/{agentId}",
      "description": "Read and consume pending messages. Returns oldest-first. Messages are removed from inbox on read (Erlang receive semantics)."
    },
    "websocket": {
      "url": "/agent/websocket",
      "protocol": "Phoenix.Channel over WebSocket",
      "description": "Real-time message delivery and agent operations via WebSocket. Connect with agent_id parameter. Join topic 'agent:{agentId}' to receive push notifications.",
      "events": {
        "client_to_server": ["discover", "send_message", "inspect_inbox", "drain_inbox"],
        "server_to_client": ["new_message"]
      }
    }
  },
  "quickstart": {
    "steps": [
      "POST /registry/register with {\"capabilities\": [\"your-capability\"]}",
      "Save the returned 'id' — this is your agent identity",
      "Connect to ws://host/agent/websocket?agent_id={id} for real-time message delivery (optional — polling works too)",
      "Poll GET /inbox/{id} to receive messages (messages are consumed on read), OR listen for 'new_message' events via WebSocket",
      "POST /messages/{targetId} to send messages to other agents",
      "Read the 'from' field of received messages to know who to reply to"
    ],
    "example_registration": {
      "capabilities": ["coding"],
      "description": "My AI agent"
    }
  }
}
```

## Implementation Notes

This is a static JSON response. No database queries. Can be a simple controller action that returns a hardcoded map, or rendered from a compile-time constant.

The `version` field should track the application version from `mix.exs`.

## Acceptance Criteria

```bash
# Fetch registry descriptor
curl -s http://localhost:4000/.well-known/agent-registry | jq
# Expect: full JSON descriptor with name, version, endpoints, quickstart

# Content-Type must be application/json
curl -sI http://localhost:4000/.well-known/agent-registry | grep content-type
# Expect: application/json

# Descriptor has exactly 5 endpoints (register, discover, send_message, read_inbox, websocket)
curl -s http://localhost:4000/.well-known/agent-registry | jq '.endpoints | keys'
# Expect: ["discover", "read_inbox", "register", "send_message", "websocket"]

# An agent can self-onboard using only this info
REGISTER_PATH=$(curl -s http://localhost:4000/.well-known/agent-registry | jq -r '.endpoints.register.path')
curl -s -X POST "http://localhost:4000${REGISTER_PATH}" \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":["self-onboarding"]}' | jq
# Expect: 201 with agent card
```

## Test Plan

1. GET returns 200 with valid JSON
2. Response contains all required fields (name, version, endpoints, quickstart)
3. Exactly 5 endpoints listed (register, discover, send_message, read_inbox, websocket)
4. All endpoint paths in the response are correct and functional
5. WebSocket endpoint includes event documentation (client_to_server, server_to_client)

## Dependencies

- All API endpoints (01-04) must be defined (paths referenced in the descriptor)
- Can be implemented at any point since it's static
