# 1. Fix get_agent_record to handle invalid UUIDs
content = File.read!("lib/viche/agents.ex")

old_get_agent_record = """
  def get_agent_record(agent_id) do
    Repo.get(AgentRecord, agent_id)
  end
"""

new_get_agent_record = """
  def get_agent_record(agent_id) do
    case Ecto.UUID.cast(agent_id) do
      {:ok, uuid} -> Repo.get(AgentRecord, uuid)
      :error -> nil
    end
  end
"""

content = String.replace(content, old_get_agent_record, new_get_agent_record)
File.write!("lib/viche/agents.ex", content)

# 2. Fix test "unauthenticated user reading owned agent inbox is allowed (no REQUIRE_AUTH)"
content = File.read!("test/viche_web/controllers/user_scoped_agents_controller_test.exs")

old_test_1 = """
    test "unauthenticated user reading owned agent inbox is allowed (no REQUIRE_AUTH)", %{
      conn: conn
    } do
      {user, _} = create_user_with_token()
      agent = register_agent!(%{capabilities: ["c"], user_id: user.id})

      # Without auth, current_user_id is nil — user_owns_agent?(nil, _) returns false
      # But without REQUIRE_AUTH, the scoping only applies when authenticated
      conn = get(conn, ~p"/inbox/\#{agent.id}")
      # Should return 200 (no REQUIRE_AUTH env set)
      assert json_response(conn, 200)
    end
"""

new_test_1 = """
    test "unauthenticated user reading owned agent inbox is denied (even with no REQUIRE_AUTH)", %{
      conn: conn
    } do
      {user, _} = create_user_with_token()
      agent = register_agent!(%{capabilities: ["c"], user_id: user.id})

      conn = get(conn, ~p"/inbox/\#{agent.id}")
      assert json_response(conn, 403)["error"] == "not_owner"
    end
"""

content = String.replace(content, old_test_1, new_test_1)

# Also fix the deregister test for unauthenticated user
old_test_2 = """
    test "unauthenticated user deregistering owned agent is allowed (no REQUIRE_AUTH)", %{
      conn: conn
    } do
      {user, _} = create_user_with_token()
      agent = register_agent!(%{capabilities: ["c"], user_id: user.id})

      conn = delete(conn, ~p"/registry/deregister/\#{agent.id}")
      assert json_response(conn, 200)["deregistered"] == true
    end
"""

new_test_2 = """
    test "unauthenticated user deregistering owned agent is denied (even with no REQUIRE_AUTH)", %{
      conn: conn
    } do
      {user, _} = create_user_with_token()
      agent = register_agent!(%{capabilities: ["c"], user_id: user.id})

      conn = delete(conn, ~p"/registry/deregister/\#{agent.id}")
      assert json_response(conn, 403)["error"] == "not_owner"
    end
"""

content = String.replace(content, old_test_2, new_test_2)
File.write!("test/viche_web/controllers/user_scoped_agents_controller_test.exs", content)

# 3. Fix test "user_owns_agent?/2 returns true for unknown agent (no record in DB)"
content = File.read!("test/viche/user_scoped_agents_test.exs")

old_test_3 = """
    test "user_owns_agent?/2 returns true for unknown agent (no record in DB)" do
      user = insert_user()
      assert Agents.user_owns_agent?(user.id, Ecto.UUID.generate())
    end
"""

new_test_3 = """
    test "user_owns_agent?/2 returns false for unknown agent (no record in DB)" do
      user = insert_user()
      refute Agents.user_owns_agent?(user.id, Ecto.UUID.generate())
    end
"""

content = String.replace(content, old_test_3, new_test_3)
File.write!("test/viche/user_scoped_agents_test.exs", content)

IO.puts("Test fixes applied")
