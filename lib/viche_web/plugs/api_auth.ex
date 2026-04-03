defmodule VicheWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug that optionally extracts the current user and agent from a Bearer API token.

  If a valid `Authorization: Bearer <token>` header is present, the plug
  assigns `:current_user_id` on the connection. If the header is absent or
  the token is invalid, `:current_user_id` is set to `nil`.

  Additionally, if an `X-Agent-ID` header is present, the named agent is
  looked up in the registry **and** verified to be owned by the authenticated
  user (`current_user_id`). Only when both checks pass is `:current_agent_id`
  set to the agent ID. This two-step verification prevents any authenticated
  user from impersonating an agent they do not own by supplying an arbitrary
  `X-Agent-ID` header.

  If the header is absent, the agent is unknown, or the agent belongs to a
  different user, `:current_agent_id` is set to `nil`.

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
    # Allow test helpers to bypass this plug by pre-assigning `:current_agent_id`
    # directly on the conn. In production no conn arrives with these assigns
    # pre-set, so this branch is effectively test-only.
    if Map.has_key?(conn.assigns, :current_agent_id) do
      conn
    else
      with [raw_token] <- get_req_header(conn, "authorization"),
           "Bearer " <> token <- raw_token,
           {:ok, auth_token} <- Auth.verify_api_token(String.trim(token)) do
        conn
        |> assign(:current_user_id, auth_token.user_id)
        |> assign_agent_id(auth_token.user_id)
      else
        _ ->
          conn
          |> assign(:current_user_id, nil)
          |> assign(:current_agent_id, nil)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # If the client provides an `X-Agent-ID` header, verify that:
  #   1. The agent actually exists in the registry.
  #   2. The agent is owned by the authenticated user (`user_id`).
  #
  # Both checks must pass before the agent ID is surfaced as `current_agent_id`.
  # This prevents a user with a valid Bearer token from impersonating an agent
  # that belongs to a different user by supplying an arbitrary `X-Agent-ID`.
  #
  # When `user_id` is `nil` (unauthenticated request), `current_agent_id` is
  # always set to `nil` regardless of the header.
  defp assign_agent_id(conn, nil), do: assign(conn, :current_agent_id, nil)

  defp assign_agent_id(conn, user_id) do
    case get_req_header(conn, "x-agent-id") do
      [agent_id] ->
        verified_id =
          case Registry.lookup(Viche.AgentRegistry, agent_id) do
            [{_pid, %{owner_id: ^user_id}}] -> agent_id
            _ -> nil
          end

        assign(conn, :current_agent_id, verified_id)

      _ ->
        assign(conn, :current_agent_id, nil)
    end
  end
end
