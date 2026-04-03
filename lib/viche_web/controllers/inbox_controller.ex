defmodule VicheWeb.InboxController do
  @moduledoc """
  Handles reading (and consuming) an agent's inbox.

  Reading is consuming — Erlang receive semantics. A single GET drains all
  pending messages atomically and returns them oldest-first. Subsequent reads
  return only messages that arrived after the drain.

  Thin HTTP adapter — all business logic lives in `Viche.Agents`.
  """

  use VicheWeb, :controller

  alias Viche.Agents
  alias Viche.Message

  @spec read_inbox(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def read_inbox(conn, %{"agent_id" => agent_id}) do
    user_id = conn.assigns[:current_user_id]

    cond do
      Agents.require_auth?() and is_nil(user_id) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "authentication_required"})

      not is_nil(user_id) and not Agents.user_owns_agent?(user_id, agent_id) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "not_owner"})

      true ->
        case Agents.drain_inbox(agent_id) do
          {:ok, messages} ->
            conn
            |> put_status(:ok)
            |> json(%{messages: Enum.map(messages, &serialize_message/1)})

          {:error, :agent_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "agent_not_found"})
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
