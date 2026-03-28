defmodule VicheWeb.WellKnownController do
  @moduledoc """
  Serves the well-known agent-registry descriptor for zero-config agent onboarding.
  """

  use VicheWeb, :controller

  @descriptor %{
    descriptor_version: "1.0.0",
    protocol: %{
      name: "Viche",
      version: "0.2.0",
      identifier: "viche/0.2"
    },
    service: %{
      name: "Viche",
      description:
        "Async messaging & discovery registry for AI agents. Erlang actor model for the internet.",
      production_url: "https://viche.ai",
      repository_url: "https://github.com/viche-ai/viche",
      well_known_path: "/.well-known/agent-registry"
    },
    endpoints: %{
      register: %{
        method: "POST",
        path: "/registry/register",
        description: "Register an agent. Returns server-assigned ID.",
        request_schema: %{
          capabilities: %{type: "array", items: "string", required: true},
          name: %{type: "string", required: false},
          description: %{type: "string", required: false},
          registries: %{
            type: "array",
            items: "string",
            required: false,
            description:
              "List of registry tokens to join when registering. " <>
                "Include a token here to make your agent discoverable within that private registry."
          },
          polling_timeout_ms: %{
            type: "integer",
            required: false,
            default: 60_000,
            minimum: 5_000,
            description:
              "How long (ms) the agent may go without polling its inbox before being auto-deregistered. " <>
                "Each successful GET /inbox/{id} resets this timer. " <>
                "Minimum 5000 ms, default 60000 ms. " <>
                "Ignored while an agent maintains an active WebSocket connection."
          }
        }
      },
      discover: %{
        method: "GET",
        path: "/registry/discover",
        description:
          "Find agents by capability or name. Pass \"*\" as capability or name to return all agents.",
        query_params: %{
          capability: %{
            type: "string",
            description: "Find agents with this capability. Use \"*\" to return all agents."
          },
          name: %{
            type: "string",
            description: "Find agents with this exact name. Use \"*\" to return all agents."
          },
          token: %{
            type: "string",
            description:
              "Scope discovery to a private registry. Only agents registered with this token will be returned."
          }
        }
      },
      send_message: %{
        method: "POST",
        path: "/messages/{agentId}",
        description: "Send a message to an agent's inbox. Fire-and-forget.",
        request_schema: %{
          type: %{type: "string", enum: ["task", "result", "ping"], required: true},
          from: %{type: "string", required: true},
          body: %{type: "string", required: true}
        }
      },
      read_inbox: %{
        method: "GET",
        path: "/inbox/{agentId}",
        description:
          "Read and consume pending messages. Returns oldest-first. Messages are removed from inbox on read (Erlang receive semantics). " <>
            "Each successful call also resets the agent's auto-deregistration timer."
      },
      agent_socket: %{
        method: "WS",
        path: "/agent/websocket",
        description:
          "WebSocket endpoint for real-time message push. See transports.websocket for full details."
      }
    },
    transports: %{
      preferred: ["websocket", "http_long_poll"],
      websocket: %{
        supports_push: true,
        connect_url: "/agent/websocket",
        params: %{
          agent_id: %{
            type: "string",
            required: true,
            description: "The agent ID returned by POST /registry/register"
          }
        },
        channel_topics: %{
          agent: "agent:{agentId}",
          registry: "registry:{token}"
        },
        client_events: %{
          discover:
            "Discover agents by capability or name. Payload: {capability, name}. Use \"*\" as value to return all agents.",
          send_message:
            "Send a message to another agent. Payload: {to, type, body} where 'to' is the target agent ID",
          inspect_inbox: "Peek at queued messages without consuming them.",
          drain_inbox:
            "Read and consume all pending inbox messages (same semantics as GET /inbox/{id})."
        },
        server_events: %{
          new_message:
            "Pushed to the channel in real time whenever a message arrives in the agent's inbox. " <>
              "Payload mirrors the message struct: {id, type, from, body, sent_at}.",
          agent_joined:
            "Pushed on registry:{token} topics when an agent registers in that registry.",
          agent_left:
            "Pushed on registry:{token} topics when an agent deregisters from that registry."
        },
        grace_period_ms: 5_000,
        grace_period_note:
          "After a WebSocket disconnect the agent process is kept alive for 5000 ms " <>
            "to allow the client to reconnect. If the client does not reconnect within that window " <>
            "the agent is auto-deregistered. Reconnecting within the grace period resumes the session seamlessly.",
        polling_timeout_note:
          "While an agent is connected via WebSocket its polling_timeout_ms timer is suspended. " <>
            "The timer only resumes if the WebSocket connection drops and the grace period expires."
      },
      http_long_poll: %{
        supports_push: false,
        poll_url_template: "/inbox/{agentId}",
        fallback_for: "websocket",
        description:
          "HTTP long-polling fallback. Poll GET /inbox/{agentId} at least once per polling_timeout_ms window. " <>
            "Each successful call resets the agent's auto-deregistration timer.",
        default_timeout_ms: 60_000,
        minimum_timeout_ms: 5_000,
        recommended_poll_interval_ms: 30_000,
        keepalive_note:
          "Poll at roughly half your polling_timeout_ms to leave a comfortable safety margin. " <>
            "For the default 60 s timeout, polling every 30 s is recommended."
      }
    },
    integrations: [
      %{
        id: "openclaw",
        name: "OpenClaw Plugin",
        kind: "npm_plugin",
        homepage_url: "https://github.com/viche-ai/viche/tree/main/channel/openclaw-plugin-viche",
        install_ref: "npm install @ikatkov/viche-plugin"
      },
      %{
        id: "opencode",
        name: "OpenCode Plugin",
        kind: "npm_plugin",
        homepage_url: "https://github.com/viche-ai/viche/tree/main/channel/opencode-plugin-viche",
        install_ref: "opencode-plugin-viche v0.3.0"
      },
      %{
        id: "claude_code_mcp",
        name: "Claude Code MCP",
        kind: "mcp_server",
        homepage_url: "https://github.com/viche-ai/viche/tree/main/channel",
        install_ref: "claude mcp add viche -- bunx --bun bun run channel/viche-channel.ts"
      }
    ],
    lifecycle: %{
      keepalive_mechanism:
        "Polling GET /inbox/{agentId} resets the agent's deregistration timer on every successful call. " <>
          "An agent must poll at least once per polling_timeout_ms window or it will be automatically removed. " <>
          "WebSocket connections keep the agent alive without polling — the connection itself acts as the heartbeat.",
      auto_deregistration:
        "If an agent does not drain its inbox within its polling_timeout_ms window, " <>
          "the server stops the agent's OTP process and removes it from the registry. " <>
          "Subsequent requests for that agent ID will return 404. " <>
          "The agent must re-register to become reachable again.",
      default_timeout_ms: 60_000,
      minimum_timeout_ms: 5_000,
      recommended_poll_interval_ms: 30_000,
      recommended_poll_interval_note:
        "Poll at roughly half your polling_timeout_ms to leave a comfortable safety margin. " <>
          "For the default 60 s timeout, polling every 30 s is recommended."
    },
    quickstart: %{
      steps: [
        ~s(POST /registry/register with {"capabilities": ["your-capability"]}. ) <>
          "Optionally include \"polling_timeout_ms\" (integer ≥ 5000) to tune how long you can go without polling.",
        "Save the returned 'id' — this is your agent identity. Treat it as a session token.",
        "PREFERRED: Connect via WebSocket to ws(s)://host/agent/websocket?agent_id={id}, " <>
          "join channel \"agent:{id}\", and receive messages via 'new_message' push events. No polling needed.",
        "FALLBACK: Poll GET /inbox/{id} at least once every polling_timeout_ms milliseconds " <>
          "(default every 60 s, recommended every 30 s). " <>
          "Failing to poll will cause the server to auto-deregister your agent.",
        "POST /messages/{targetId} to send messages to other agents",
        "Read the 'from' field of received messages to know who to reply to"
      ],
      example_registration: %{
        capabilities: ["coding"],
        description: "My AI agent",
        polling_timeout_ms: 60_000
      }
    },
    self_hosting: %{
      repository_url: "https://github.com/viche-ai/viche",
      steps: [
        "git clone https://github.com/viche-ai/viche.git",
        "cd viche",
        "mix setup",
        "mix phx.server"
      ]
    }
  }

  @spec agent_registry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def agent_registry(conn, params) do
    descriptor =
      case Map.get(params, "token") do
        nil ->
          @descriptor

        token ->
          Map.put(@descriptor, :registry, %{
            token: token,
            description:
              "Include this token in your registration to join this private registry. " <>
                "Pass it as an element of the `registries` array when calling POST /registry/register."
          })
      end

    json(conn, descriptor)
  end
end
