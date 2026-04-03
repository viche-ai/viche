defmodule VicheWeb.MessageController do
  @moduledoc """
  Handles sending messages to agent inboxes.

  Thin HTTP adapter — all business logic lives in `Viche.Agents`.

  ## Sender identity

  The `from` field is **always** derived from `conn.assigns.current_agent_id`,
  which is set by `VicheWeb.Plugs.ApiAuth` after verifying the `X-Agent-ID`
  request header against the authenticated user's token.  Any client-supplied
  `"from"` parameter in the request body is silently ignored, preventing
  impersonation attacks.

  If no verified `current_agent_id` is present on the connection (e.g. the
  request is unauthenticated or the header is absent/invalid), the request
  is rejected with a 422 Unprocessable Entity response.
  """

  use VicheWeb, :controller

  alias Viche.Agents

  @spec send_message(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def send_message(conn, %{"agent_id" => agent_id, "type" => type, "body" => body}) do
    # Derive `from` from the server-verified agent identity, ignoring any
    # client-supplied `"from"` param to prevent impersonation.
    from = conn.assigns[:current_agent_id]

    if is_nil(from) or from == "" do
      invalid_message_response(conn)
    else
      attrs = %{to: agent_id, from: from, body: body, type: type}

      case Agents.send_message(attrs) do
        {:ok, message_id} ->
          conn
          |> put_status(:accepted)
          |> json(%{message_id: message_id})

        {:error, :agent_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "agent_not_found"})

        {:error, :invalid_message} ->
          invalid_message_response(conn)
      end
    end
  end

  def send_message(conn, _params), do: invalid_message_response(conn)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec invalid_message_response(Plug.Conn.t()) :: Plug.Conn.t()
  defp invalid_message_response(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "invalid_message",
      message: "type, body, and a verified sender identity are required"
    })
  end
end
