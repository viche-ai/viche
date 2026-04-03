defmodule VicheWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug that optionally extracts the current user and agent from a Bearer API token.

  If a valid `Authorization: Bearer <token>` header is present, the plug
  assigns `:current_user_id` on the connection. If the header is absent or
  the token is invalid, `:current_user_id` is set to `nil`.

  Additionally, if an `X-Agent-ID` header is present and the named agent exists
  in the registry, `:current_agent_id` is set to that value. This allows
  server-side verification of the sender identity for message delivery — the
  `from` field is derived from `:current_agent_id` rather than trusting the
  client-supplied request body, preventing impersonation attacks.

  If the header is absent or the agent is not found in the registry,
  `:current_agent_id` is set to `nil`.

  This plug never halts the connection — downstream controllers decide
  whether authentication is required based on `REQUIRE_AUTH` and the
  specific endpoint's scoping rules.
  """

  import Plug.Conn

  alias Viche.Auth

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_bearer_token(conn) do
      nil ->
        conn
        |> assign(:current_user_id, nil)
        |> assign(:current_agent_id, nil)

      raw_token ->
        case Auth.verify_api_token(raw_token) do
          {:ok, auth_token} ->
            conn
            |> assign(:current_user_id, auth_token.user_id)
            |> assign_agent_id()

          {:error, :invalid_token} ->
            conn
            |> assign(:current_user_id, nil)
            |> assign(:current_agent_id, nil)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  # If the client provides an `X-Agent-ID` header, verify that the agent
  # actually exists in the registry and only then surface it as
  # `current_agent_id`.  This prevents a client from claiming to be an
  # arbitrary agent that does not exist, and — when combined with the
  # MessageController overwriting the client-supplied `from` field —
  # prevents full impersonation of any registered sender identity.
  defp assign_agent_id(conn) do
    case get_req_header(conn, "x-agent-id") do
      [agent_id] ->
        verified_id =
          case Registry.lookup(Viche.AgentRegistry, agent_id) do
            [{_pid, _meta}] -> agent_id
            [] -> nil
          end

        assign(conn, :current_agent_id, verified_id)

      _ ->
        assign(conn, :current_agent_id, nil)
    end
  end
end
