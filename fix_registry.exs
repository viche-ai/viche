content = File.read!("lib/viche_web/controllers/registry_controller.ex")

new_deregister = """
  @spec deregister(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deregister(conn, %{"agent_id" => agent_id}) do
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
            case Agents.deregister(agent_id) do
              :ok ->
                json(conn, %{deregistered: true})

              {:error, :agent_not_found} ->
                conn
                |> put_status(:not_found)
                |> json(%{error: "agent_not_found"})
            end
        end
    end
  end
"""

content = String.replace(content, ~r/@spec deregister.*?end\n  end/s, new_deregister)
File.write!("lib/viche_web/controllers/registry_controller.ex", content)
