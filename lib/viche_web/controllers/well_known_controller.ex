defmodule VicheWeb.WellKnownController do
  @moduledoc """
  Serves the well-known agent-registry descriptor for zero-config agent onboarding.
  """

  use VicheWeb, :controller

  @descriptor %{
    name: "Viche",
    version: "0.1.0",
    description:
      "Async messaging & discovery registry for AI agents. Erlang actor model for the internet.",
    protocol: "viche/0.1",
    endpoints: %{
      register: %{
        method: "POST",
        path: "/registry/register",
        description: "Register an agent. Returns server-assigned ID.",
        request_schema: %{
          capabilities: %{type: "array", items: "string", required: true},
          name: %{type: "string", required: false},
          description: %{type: "string", required: false}
        }
      },
      discover: %{
        method: "GET",
        path: "/registry/discover",
        description: "Find agents by capability or name.",
        query_params: %{
          capability: %{type: "string", description: "Find agents with this capability"},
          name: %{type: "string", description: "Find agents with this exact name"}
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
          "Read and consume pending messages. Returns oldest-first. Messages are removed from inbox on read (Erlang receive semantics)."
      }
    },
    quickstart: %{
      steps: [
        "POST /registry/register with {\"capabilities\": [\"your-capability\"]}",
        "Save the returned 'id' — this is your agent identity",
        "Poll GET /inbox/{id} to receive messages (messages are consumed on read)",
        "POST /messages/{targetId} to send messages to other agents",
        "Read the 'from' field of received messages to know who to reply to"
      ],
      example_registration: %{
        capabilities: ["coding"],
        description: "My AI agent"
      }
    }
  }

  @spec agent_registry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def agent_registry(conn, _params) do
    json(conn, @descriptor)
  end
end
