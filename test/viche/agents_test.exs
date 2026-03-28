defmodule Viche.AgentsTest do
  use ExUnit.Case, async: false

  alias Viche.Agents

  defp clear_all_agents do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)

    # Synchronize with all Registry partition processes to ensure :DOWN messages
    # have been processed and ETS entries removed before returning.
    Viche.AgentRegistry
    |> Supervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} -> _ = :sys.get_state(pid) end)

    :ok
  end

  describe "list_agents/0" do
    setup do
      clear_all_agents()
      :ok
    end

    test "returns empty list when no agents are registered" do
      assert Agents.list_agents() == []
    end

    test "returns all registered agents as maps with id/name/capabilities/description" do
      {:ok, _} = Agents.register_agent(%{capabilities: ["coding"], name: "agent-a"})
      {:ok, _} = Agents.register_agent(%{capabilities: ["testing"], name: "agent-b"})

      agents = Agents.list_agents()
      assert length(agents) == 2

      names = Enum.map(agents, & &1.name)
      assert "agent-a" in names
      assert "agent-b" in names

      for agent <- agents do
        assert Map.has_key?(agent, :id)
        assert Map.has_key?(agent, :name)
        assert Map.has_key?(agent, :capabilities)
        assert Map.has_key?(agent, :description)
      end
    end
  end

  describe "register_agent/1" do
    test "happy path returns {:ok, %Agent{}} with all fields" do
      assert {:ok, agent} =
               Agents.register_agent(%{
                 capabilities: ["coding"],
                 name: "test-agent",
                 description: "A test agent"
               })

      assert %Viche.Agent{} = agent
      assert agent.capabilities == ["coding"]
      assert agent.name == "test-agent"
      assert agent.description == "A test agent"
      assert String.length(agent.id) == 8
      assert %DateTime{} = agent.registered_at
    end

    test "works without optional name and description" do
      assert {:ok, agent} = Agents.register_agent(%{capabilities: ["minimal"]})
      assert agent.name == nil
      assert agent.description == nil
      assert agent.capabilities == ["minimal"]
    end

    test "returns {:error, :capabilities_required} when capabilities key missing" do
      assert {:error, :capabilities_required} = Agents.register_agent(%{name: "no-caps"})
    end

    test "returns {:error, :capabilities_required} when capabilities is empty list" do
      assert {:error, :capabilities_required} = Agents.register_agent(%{capabilities: []})
    end

    test "returns {:error, :capabilities_required} when capabilities is not a list" do
      assert {:error, :capabilities_required} = Agents.register_agent(%{capabilities: "coding"})
    end
  end

  describe "discover/1" do
    setup do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{
          capabilities: ["coding", "testing"],
          name: "agent-a",
          description: "Agent A"
        })

      {:ok, agent_b} =
        Agents.register_agent(%{
          capabilities: ["coding"],
          name: "agent-b",
          description: "Agent B"
        })

      %{id_a: agent_a.id, id_b: agent_b.id}
    end

    test "discovers agents by capability - single match", %{id_a: id_a} do
      assert {:ok, agents} = Agents.discover(%{capability: "testing"})
      assert length(agents) == 1
      [agent] = agents
      assert agent.id == id_a
      assert "testing" in agent.capabilities
    end

    test "discovers agents by capability - multiple matches", %{id_a: id_a, id_b: id_b} do
      assert {:ok, agents} = Agents.discover(%{capability: "coding"})
      ids = Enum.map(agents, & &1.id)
      assert id_a in ids
      assert id_b in ids
      assert length(agents) == 2
    end

    test "returns {:ok, []} when capability has no matches" do
      assert {:ok, []} = Agents.discover(%{capability: "nonexistent"})
    end

    test "discovers agents by name - exact match", %{id_a: id_a} do
      assert {:ok, agents} = Agents.discover(%{name: "agent-a"})
      assert length(agents) == 1
      [agent] = agents
      assert agent.id == id_a
    end

    test "returns {:ok, []} when name has no matches" do
      assert {:ok, []} = Agents.discover(%{name: "ghost"})
    end

    test "returns {:error, :query_required} when map is empty" do
      assert {:error, :query_required} = Agents.discover(%{})
    end

    test "returns {:error, :query_required} when capability is empty string" do
      assert {:error, :query_required} = Agents.discover(%{capability: ""})
    end

    test "does not expose inbox or registered_at" do
      {:ok, agents} = Agents.discover(%{capability: "coding"})

      for agent <- agents do
        refute Map.has_key?(agent, :inbox)
        refute Map.has_key?(agent, :registered_at)
      end
    end
  end

  describe "send_message/1" do
    setup do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["test"]})
      %{agent_id: agent.id}
    end

    test "happy path returns {:ok, message_id}", %{agent_id: agent_id} do
      assert {:ok, message_id} =
               Agents.send_message(%{
                 to: agent_id,
                 from: "sender",
                 body: "hello",
                 type: "task"
               })

      assert String.starts_with?(message_id, "msg-")
      assert String.length(message_id) == 12
    end

    test "defaults type to task when omitted", %{agent_id: agent_id} do
      assert {:ok, _message_id} =
               Agents.send_message(%{
                 to: agent_id,
                 from: "sender",
                 body: "hello"
               })
    end

    test "all valid types are accepted", %{agent_id: agent_id} do
      for type <- ["task", "result", "ping"] do
        assert {:ok, _} =
                 Agents.send_message(%{to: agent_id, from: "sender", body: "body", type: type})
      end
    end

    test "returns {:error, :agent_not_found} for unknown agent" do
      assert {:error, :agent_not_found} =
               Agents.send_message(%{
                 to: "nonexistent",
                 from: "sender",
                 body: "hello",
                 type: "task"
               })
    end

    test "returns {:error, :invalid_message} for invalid type", %{agent_id: agent_id} do
      assert {:error, :invalid_message} =
               Agents.send_message(%{
                 to: agent_id,
                 from: "sender",
                 body: "hello",
                 type: "invalid"
               })
    end

    test "returns {:error, :invalid_message} when from is missing", %{agent_id: agent_id} do
      assert {:error, :invalid_message} =
               Agents.send_message(%{to: agent_id, body: "hello", type: "task"})
    end

    test "returns {:error, :invalid_message} when body is missing", %{agent_id: agent_id} do
      assert {:error, :invalid_message} =
               Agents.send_message(%{to: agent_id, from: "sender", type: "task"})
    end

    test "message lands in agent inbox", %{agent_id: agent_id} do
      Agents.send_message(%{to: agent_id, from: "aris", body: "ping!", type: "ping"})

      assert {:ok, [msg]} = Agents.inspect_inbox(agent_id)
      assert msg.from == "aris"
      assert msg.body == "ping!"
      assert msg.type == "ping"
    end
  end

  describe "inspect_inbox/1" do
    setup do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["test"]})
      %{agent_id: agent.id}
    end

    test "returns {:ok, []} for empty inbox", %{agent_id: agent_id} do
      assert {:ok, []} = Agents.inspect_inbox(agent_id)
    end

    test "returns messages WITHOUT consuming them - two calls return same results",
         %{agent_id: agent_id} do
      Agents.send_message(%{to: agent_id, from: "sender", body: "hello", type: "task"})

      assert {:ok, messages1} = Agents.inspect_inbox(agent_id)
      assert length(messages1) == 1

      # Second call — inbox must NOT be drained
      assert {:ok, messages2} = Agents.inspect_inbox(agent_id)
      assert length(messages2) == 1

      assert hd(messages1).id == hd(messages2).id
    end

    test "returns {:error, :agent_not_found} for unknown agent" do
      assert {:error, :agent_not_found} = Agents.inspect_inbox("nonexistent")
    end
  end

  describe "drain_inbox/1" do
    setup do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["test"]})
      %{agent_id: agent.id}
    end

    test "returns {:ok, []} for empty inbox", %{agent_id: agent_id} do
      assert {:ok, []} = Agents.drain_inbox(agent_id)
    end

    test "consumes messages - second call returns empty list", %{agent_id: agent_id} do
      Agents.send_message(%{to: agent_id, from: "sender", body: "hello", type: "task"})

      assert {:ok, messages1} = Agents.drain_inbox(agent_id)
      assert length(messages1) == 1

      # Second call — inbox has been drained
      assert {:ok, []} = Agents.drain_inbox(agent_id)
    end

    test "drain and inspect diverge: inspect after drain returns empty", %{agent_id: agent_id} do
      Agents.send_message(%{to: agent_id, from: "sender", body: "hello", type: "task"})

      # Drain first
      assert {:ok, [_msg]} = Agents.drain_inbox(agent_id)

      # Inspect after drain — empty
      assert {:ok, []} = Agents.inspect_inbox(agent_id)
    end

    test "returns {:error, :agent_not_found} for unknown agent" do
      assert {:error, :agent_not_found} = Agents.drain_inbox("nonexistent")
    end
  end
end
