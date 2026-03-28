defmodule VicheWeb.InboxController do
  @moduledoc """
  Handles reading (and consuming) an agent's inbox.

  Reading is consuming — Erlang receive semantics. A single GET drains all
  pending messages atomically and returns them oldest-first. Subsequent reads
  return only messages that arrived after the drain.
  """

  use VicheWeb, :controller

  alias Viche.AgentServer
  alias Viche.Message

  @spec read_inbox(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def read_inbox(conn, %{"agent_id" => agent_id}) do
    case lookup_agent(agent_id) do
      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "agent_not_found"})

      :found ->
        via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
        messages = AgentServer.drain_inbox(via)

        conn
        |> put_status(:ok)
        |> json(%{messages: Enum.map(messages, &serialize_message/1)})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec lookup_agent(String.t()) :: :found | :not_found
  defp lookup_agent(agent_id) do
    case Registry.lookup(Viche.AgentRegistry, agent_id) do
      [] -> :not_found
      _ -> :found
    end
  end

  @spec serialize_message(Message.t()) :: map()
  defp serialize_message(%Message{} = msg) do
    %{
      id: msg.id,
      type: msg.type,
      from: msg.from,
      body: msg.body,
      sent_at: DateTime.to_iso8601(msg.sent_at)
    }
  end
end
