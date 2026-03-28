defmodule VicheWeb.AgentSocket do
  @moduledoc """
  Phoenix Socket for agent WebSocket connections.

  Agents connect to this socket and join their own topic `"agent:{agent_id}"`
  to receive real-time messages and interact with the system via WebSocket events.

  An `agent_id` parameter must be provided in the connection params; connections
  without a valid agent_id are rejected.
  """

  use Phoenix.Socket

  channel "agent:*", VicheWeb.AgentChannel

  @impl true
  def connect(%{"agent_id" => agent_id}, socket, _connect_info)
      when is_binary(agent_id) and agent_id != "" do
    {:ok, assign(socket, :agent_id, agent_id)}
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "agent_socket:#{socket.assigns.agent_id}"
end
