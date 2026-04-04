# 1. Fix user_owns_agent? to return {:error, :not_found}
content = File.read!("lib/viche/agents.ex")

old_user_owns = """
  def user_owns_agent?(user_id, agent_id) do
    case get_agent_record(agent_id) do
      nil -> false
      %AgentRecord{user_id: nil} -> true
      %AgentRecord{user_id: ^user_id} -> true
      _ -> false
    end
  end
"""

new_user_owns = """
  def user_owns_agent?(user_id, agent_id) do
    case get_agent_record(agent_id) do
      nil -> {:error, :not_found}
      %AgentRecord{user_id: nil} -> true
      %AgentRecord{user_id: ^user_id} -> true
      _ -> false
    end
  end
"""

content = String.replace(content, old_user_owns, new_user_owns)
File.write!("lib/viche/agents.ex", content)

# 2. Fix InboxController
content = File.read!("lib/viche_web/controllers/inbox_controller.ex")

old_inbox = """
      not Agents.user_owns_agent?(user_id, agent_id) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "not_owner"})

      true ->
        case Agents.drain_inbox(agent_id) do
"""

new_inbox = """
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
"""

content = String.replace(content, old_inbox, new_inbox)
# We also need to add an extra `end` for the case statement
content =
  String.replace(
    content,
    "            end\n    end\n  end",
    "            end\n        end\n    end\n  end"
  )

File.write!("lib/viche_web/controllers/inbox_controller.ex", content)

# 3. Fix RegistryController
content = File.read!("lib/viche_web/controllers/registry_controller.ex")

old_registry = """
      not Agents.user_owns_agent?(user_id, agent_id) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "not_owner"})

      true ->
        case Agents.deregister(agent_id) do
"""

new_registry = """
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
"""

content = String.replace(content, old_registry, new_registry)

content =
  String.replace(
    content,
    "            end\n    end\n  end",
    "            end\n        end\n    end\n  end"
  )

File.write!("lib/viche_web/controllers/registry_controller.ex", content)

# 4. Fix test "returns false for unknown agent (no record in DB)"
content = File.read!("test/viche/user_scoped_agents_test.exs")

old_test = """
    test "returns false for unknown agent (no record in DB)" do
      user = insert_user()
      refute Agents.user_owns_agent?(user.id, Ecto.UUID.generate())
    end
"""

new_test = """
    test "returns {:error, :not_found} for unknown agent (no record in DB)" do
      user = insert_user()
      assert {:error, :not_found} = Agents.user_owns_agent?(user.id, Ecto.UUID.generate())
    end
"""

content = String.replace(content, old_test, new_test)
File.write!("test/viche/user_scoped_agents_test.exs", content)

IO.puts("404 fixes applied")
