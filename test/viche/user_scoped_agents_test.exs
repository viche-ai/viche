defmodule Viche.UserScopedAgentsTest do
  @moduledoc """
  Tests for user-scoped agent ownership (Issue #20).

  Covers:
  - Registration with user_id
  - Scoping rules (inbox read denied for non-owner, deregister denied for non-owner)
  - Unclaimed agent backwards compatibility
  - user_owns_agent? helper
  - list_agent_ids_for_user/1 and list_claimed_agent_ids/0
  """

  use Viche.DataCase, async: false

  alias Viche.Accounts
  alias Viche.Agents
  alias Viche.Agents.AgentRecord

  defp create_user(email \\ nil) do
    email = email || "user-#{System.unique_integer()}@example.com"
    {:ok, user} = Accounts.create_user(%{email: email})
    user
  end

  defp clear_all_agents do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)

    Viche.AgentRegistry
    |> Supervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} -> _ = :sys.get_state(pid) end)

    :ok
  end

  describe "migration: user_id column" do
    test "AgentRecord schema has user_id field" do
      assert %AgentRecord{user_id: nil} = %AgentRecord{}
    end

    test "AgentRecord belongs_to user association is defined" do
      assert Map.has_key?(%AgentRecord{}, :user)
    end
  end

  describe "registration with user_id" do
    setup do
      clear_all_agents()
      :ok
    end

    test "register_agent/1 accepts user_id and persists it in the DB" do
      user = create_user()

      {:ok, agent} =
        Agents.register_agent(%{
          capabilities: ["coding"],
          name: "owned-agent",
          user_id: user.id
        })

      record = Repo.get(AgentRecord, agent.id)
      assert record.user_id == user.id
    end

    test "register_agent/1 without user_id creates an unclaimed agent (user_id is nil)" do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["coding"], name: "unclaimed-agent"})

      record = Repo.get(AgentRecord, agent.id)
      assert record.user_id == nil
    end
  end

  describe "user_owns_agent?/2" do
    setup do
      clear_all_agents()
      :ok
    end

    test "returns true when user owns the agent" do
      user = create_user()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"], user_id: user.id})

      assert Agents.user_owns_agent?(user.id, agent.id)
    end

    test "returns false when a different user tries to access the agent" do
      user1 = create_user()
      user2 = create_user()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"], user_id: user1.id})

      refute Agents.user_owns_agent?(user2.id, agent.id)
    end

    test "returns true for unclaimed agents (no user_id)" do
      # Any user can interact with unclaimed agents
      user = create_user()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"]})

      assert Agents.user_owns_agent?(user.id, agent.id)
    end

    test "returns false when user_id is nil" do
      user = create_user()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["c"], user_id: user.id})

      refute Agents.user_owns_agent?(nil, agent.id)
    end

    test "returns true for unknown agent (no record in DB)" do
      user = create_user()
      # Unknown agents default to accessible (e.g. in-memory only)
      assert Agents.user_owns_agent?(user.id, Ecto.UUID.generate())
    end
  end

  describe "list_agent_ids_for_user/1" do
    setup do
      clear_all_agents()
      :ok
    end

    test "returns agent IDs owned by the given user" do
      user1 = create_user()
      user2 = create_user()

      {:ok, agent1} = Agents.register_agent(%{capabilities: ["a"], user_id: user1.id})
      {:ok, agent2} = Agents.register_agent(%{capabilities: ["b"], user_id: user1.id})
      {:ok, _agent3} = Agents.register_agent(%{capabilities: ["c"], user_id: user2.id})

      ids = Agents.list_agent_ids_for_user(user1.id)
      assert length(ids) == 2
      assert agent1.id in ids
      assert agent2.id in ids
    end

    test "returns empty list when user has no agents" do
      user = create_user()
      assert Agents.list_agent_ids_for_user(user.id) == []
    end

    test "does not return agents owned by other users" do
      user1 = create_user()
      user2 = create_user()
      {:ok, _agent} = Agents.register_agent(%{capabilities: ["a"], user_id: user2.id})

      assert Agents.list_agent_ids_for_user(user1.id) == []
    end
  end

  describe "list_claimed_agent_ids/0" do
    setup do
      clear_all_agents()
      :ok
    end

    test "returns only IDs of agents with a user_id set" do
      user = create_user()
      {:ok, claimed} = Agents.register_agent(%{capabilities: ["a"], user_id: user.id})
      {:ok, _unclaimed} = Agents.register_agent(%{capabilities: ["b"]})

      ids = Agents.list_claimed_agent_ids()
      assert claimed.id in ids
    end

    test "does not include unclaimed agents" do
      {:ok, unclaimed} = Agents.register_agent(%{capabilities: ["a"]})

      ids = Agents.list_claimed_agent_ids()
      refute unclaimed.id in ids
    end
  end

  describe "unclaimed agent backwards compatibility" do
    setup do
      clear_all_agents()
      :ok
    end

    test "unclaimed agents can receive messages from anyone" do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["legacy"]})

      assert {:ok, _msg_id} =
               Agents.send_message(%{to: agent.id, from: "anyone", body: "hello"})
    end

    test "unclaimed agents can be deregistered without auth" do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["legacy"]})
      assert :ok = Agents.deregister(agent.id)
    end

    test "unclaimed agents allow any user to read their inbox (user_owns_agent? returns true)" do
      user = create_user()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["legacy"]})

      assert Agents.user_owns_agent?(user.id, agent.id)
    end
  end
end
