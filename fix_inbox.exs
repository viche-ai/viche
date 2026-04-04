content = File.read!("lib/viche_web/controllers/inbox_controller.ex")

new_read_inbox = """
  @spec read_inbox(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def read_inbox(conn, %{"agent_id" => agent_id}) do
    user_id = conn.assigns[:current_user_id]

    cond do
      Agents.require_auth?() and is_nil(user_id) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "authentication_required"})

      true ->
        case Agents.user_owns_agent?(user_id, agent_id) do
          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "agent_not_found"})

          false ->
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
  end
"""

content = String.replace(content, ~r/@spec read_inbox.*?end\n  end/s, new_read_inbox)
File.write!("lib/viche_web/controllers/inbox_controller.ex", content)
