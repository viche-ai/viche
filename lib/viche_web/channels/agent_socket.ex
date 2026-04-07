defmodule VicheWeb.AgentSocket do
  @moduledoc """
  Phoenix Socket for agent WebSocket connections.

  Agents connect to this socket and join their own topic `"agent:{agent_id}"`
  to receive real-time messages and interact with the system via WebSocket events.

  `agent_id` is optional in the connection params.

  - When `agent_id` is provided, the socket authenticates ownership for reconnect flow
    (`agent:{agent_id}` joins).
  - When `agent_id` is omitted, the socket may connect to support register-on-join flow
    (`agent:register` join), which assigns `:agent_id` after registration.

  When a `token` parameter is provided, it is validated as an API token and the
  owning user must match the agent's owner. Connections to agents owned by a
  different user are rejected. When no token is provided, the connection is
  allowed only if the agent is unclaimed (no owner).
  """

  use Phoenix.Socket

  alias Viche.Agents
  alias Viche.Auth

  channel "agent:*", VicheWeb.AgentChannel
  channel "registry:*", VicheWeb.AgentChannel

  @impl true
  def connect(%{"agent_id" => agent_id} = params, socket, _connect_info)
      when is_binary(agent_id) and agent_id != "" do
    token = params["token"]

    case authenticate_socket(token, agent_id) do
      :ok ->
        {:ok, assign(socket, :agent_id, agent_id)}

      :error ->
        :error
    end
  end

  def connect(%{"agent_id" => _invalid}, _socket, _connect_info), do: :error

  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(%{assigns: %{agent_id: agent_id}}) when is_binary(agent_id),
    do: "agent_socket:#{agent_id}"

  def id(_socket), do: nil

  defp authenticate_socket(nil, agent_id) do
    # No token — allow only if agent is unclaimed
    case Agents.get_agent_record(agent_id) do
      nil -> :ok
      %{user_id: nil} -> :ok
      _ -> :error
    end
  end

  defp authenticate_socket(token, agent_id) when is_binary(token) do
    case Auth.verify_api_token(token) do
      {:ok, auth_token} ->
        if Agents.user_owns_agent?(auth_token.user_id, agent_id), do: :ok, else: :error

      {:error, :invalid_token} ->
        :error
    end
  end
end
