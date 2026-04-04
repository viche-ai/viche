content = File.read!("lib/viche_web/plugs/api_auth.ex")

old_block = """
  defp assign_agent_id(conn, user_id) do
    case get_req_header(conn, "x-agent-id") do
      [agent_id | _] ->
        verified_id =
          case Registry.lookup(Viche.AgentRegistry, agent_id) do
            [{_pid, %{owner_id: ^user_id}}] -> agent_id
            _ -> nil
          end

        assign(conn, :current_agent_id, verified_id)

      _ ->
        assign(conn, :current_agent_id, nil)
    case get_bearer_token(conn) do
      nil ->
        assign(conn, :current_user_id, nil)

      raw_token ->
        case Auth.verify_api_token(raw_token) do
          {:ok, auth_token} ->
            assign(conn, :current_user_id, auth_token.user_id)

          {:error, :invalid_token} ->
            assign(conn, :current_user_id, nil)
        end
    end
  end
"""

new_block = """
  defp assign_agent_id(conn, user_id) do
    case get_req_header(conn, "x-agent-id") do
      [agent_id | _] ->
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
"""

content = String.replace(content, old_block, new_block)
File.write!("lib/viche_web/plugs/api_auth.ex", content)
