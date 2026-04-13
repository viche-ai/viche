defmodule VicheWeb.BroadcastController do
  @moduledoc """
  Handles broadcasting messages to all agents in a registry namespace.

  Thin HTTP adapter — all business logic lives in `Viche.Agents`.

  Sender identity is always derived from `conn.assigns.current_agent_id`.
  Any client-supplied `"from"` value is ignored.
  """

  use VicheWeb, :controller

  alias Viche.Agents

  @spec broadcast(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def broadcast(conn, %{"token" => token, "body" => body} = params) do
    from = conn.assigns[:current_agent_id]

    if is_nil(from) do
      invalid_message_response(conn)
    else
      attrs = %{
        from: from,
        registry: token,
        body: body,
        type: Map.get(params, "type", "task")
      }

      case Agents.broadcast_message(attrs) do
        {:ok, %{recipients: recipients, message_ids: message_ids, failed: failed}} ->
          conn
          |> put_status(:accepted)
          |> json(%{
            recipients: recipients,
            message_ids: message_ids,
            failed: failed
          })

        {:error, :not_in_registry} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "not_in_registry", message: "sender is not in the target registry"})

        {:error, :invalid_token} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_token", message: "registry token is invalid"})

        {:error, reason} when reason in [:sender_not_found, :invalid_message] ->
          invalid_message_response(conn)
      end
    end
  end

  def broadcast(conn, _params), do: invalid_message_response(conn)

  @spec invalid_message_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp invalid_message_response(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_message",
      message: "body and a verified sender identity are required"
    })
  end
end
