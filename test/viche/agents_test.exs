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

    test "returns all registered agents as maps with id/name/capabilities/description/registries" do
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
        assert Map.has_key?(agent, :registries)
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

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
               agent.id
             )

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

    test "agent ID is UUID v4 format" do
      assert {:ok, agent} = Agents.register_agent(%{capabilities: ["test"]})
      uuid_v4 = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert Regex.match?(uuid_v4, agent.id),
             "Expected UUID v4 format but got: #{inspect(agent.id)}"
    end

    test "registries defaults to [\"global\"] when not provided" do
      assert {:ok, agent} = Agents.register_agent(%{capabilities: ["test"]})
      assert agent.registries == ["global"]
    end

    test "registries can be set on registration" do
      assert {:ok, agent} =
               Agents.register_agent(%{
                 capabilities: ["test"],
                 registries: ["my-team-token"]
               })

      assert agent.registries == ["my-team-token"]
    end

    test "registries can contain multiple tokens" do
      assert {:ok, agent} =
               Agents.register_agent(%{
                 capabilities: ["test"],
                 registries: ["global", "my-team-token"]
               })

      assert agent.registries == ["global", "my-team-token"]
    end

    test "returns {:error, :invalid_registry_token} for empty string token" do
      assert {:error, :invalid_registry_token} =
               Agents.register_agent(%{capabilities: ["test"], registries: [""]})
    end

    test "returns {:error, :invalid_registry_token} for token shorter than 4 chars" do
      assert {:error, :invalid_registry_token} =
               Agents.register_agent(%{capabilities: ["test"], registries: ["ab"]})
    end

    test "accepts token of exactly 4 chars" do
      assert {:ok, agent} =
               Agents.register_agent(%{capabilities: ["test"], registries: ["abcd"]})

      assert agent.registries == ["abcd"]
    end

    test "accepts token with valid special chars (hyphens, underscores, dots)" do
      assert {:ok, agent} =
               Agents.register_agent(%{
                 capabilities: ["test"],
                 registries: ["my-team_token.v2"]
               })

      assert agent.registries == ["my-team_token.v2"]
    end

    test "returns {:error, :invalid_registry_token} for token with spaces" do
      assert {:error, :invalid_registry_token} =
               Agents.register_agent(%{capabilities: ["test"], registries: ["has spaces"]})
    end

    test "returns {:error, :invalid_registry_token} for token with special chars like @" do
      assert {:error, :invalid_registry_token} =
               Agents.register_agent(%{capabilities: ["test"], registries: ["has@special!"]})
    end

    test "returns {:error, :invalid_registry_token} for token longer than 256 chars" do
      long_token = String.duplicate("a", 257)

      assert {:error, :invalid_registry_token} =
               Agents.register_agent(%{capabilities: ["test"], registries: [long_token]})
    end

    test "accepts \"global\" as a valid (reserved) token" do
      assert {:ok, agent} =
               Agents.register_agent(%{capabilities: ["test"], registries: ["global"]})

      assert agent.registries == ["global"]
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

    test "wildcard capability '*' returns all registered agents", %{id_a: id_a, id_b: id_b} do
      assert {:ok, agents} = Agents.discover(%{capability: "*"})
      ids = Enum.map(agents, & &1.id)
      assert id_a in ids
      assert id_b in ids
      assert length(agents) == 2
    end

    test "wildcard name '*' returns all registered agents", %{id_a: id_a, id_b: id_b} do
      assert {:ok, agents} = Agents.discover(%{name: "*"})
      ids = Enum.map(agents, & &1.id)
      assert id_a in ids
      assert id_b in ids
      assert length(agents) == 2
    end

    test "wildcard returns {:ok, []} when no agents are registered" do
      clear_all_agents()
      assert {:ok, []} = Agents.discover(%{capability: "*"})
    end

    test "wildcard returns agents with expected keys", %{id_a: _id_a} do
      {:ok, agents} = Agents.discover(%{capability: "*"})

      for agent <- agents do
        assert Map.has_key?(agent, :id)
        assert Map.has_key?(agent, :name)
        assert Map.has_key?(agent, :capabilities)
        assert Map.has_key?(agent, :description)
        assert Map.has_key?(agent, :registries)
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
      # "msg-" + UUID (36 chars) = 40 chars total
      assert String.length(message_id) == 40
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

  describe "deregister/1" do
    setup do
      {:ok, agent} = Agents.register_agent(%{capabilities: ["test"]})
      %{agent_id: agent.id}
    end

    test "happy path: stops process and removes from Registry", %{agent_id: agent_id} do
      [{pid, _}] = Registry.lookup(Viche.AgentRegistry, agent_id)
      ref = Process.monitor(pid)

      assert :ok = Agents.deregister(agent_id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # Synchronize with Registry partitions to ensure the :DOWN message has been
      # processed and the ETS entries have been removed before checking.
      Viche.AgentRegistry
      |> Supervisor.which_children()
      |> Enum.each(fn {_, reg_pid, _, _} -> _ = :sys.get_state(reg_pid) end)

      assert Registry.lookup(Viche.AgentRegistry, agent_id) == []
    end

    test "returns {:error, :agent_not_found} for unknown id" do
      assert {:error, :agent_not_found} = Agents.deregister("nonexistent")
    end

    test "inbox is purged after deregister — re-registering with same caps gives empty inbox",
         %{agent_id: agent_id} do
      # Send a message so inbox has content
      Agents.send_message(%{to: agent_id, from: "sender", body: "hello", type: "task"})
      assert {:ok, [_msg]} = Agents.inspect_inbox(agent_id)

      # Deregister removes the process and its in-memory inbox
      assert :ok = Agents.deregister(agent_id)

      # Re-register a fresh agent (different ID, clean state)
      {:ok, new_agent} = Agents.register_agent(%{capabilities: ["test"]})
      assert {:ok, []} = Agents.drain_inbox(new_agent.id)
    end
  end

  describe "discover/1 scoped by registry" do
    setup do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{
          capabilities: ["coding"],
          name: "agent-a",
          registries: ["team-x"]
        })

      {:ok, agent_b} =
        Agents.register_agent(%{
          capabilities: ["coding"],
          name: "agent-b",
          registries: ["team-y"]
        })

      {:ok, agent_global} =
        Agents.register_agent(%{
          capabilities: ["coding"],
          name: "agent-global",
          registries: ["global"]
        })

      {:ok, agent_multi} =
        Agents.register_agent(%{
          capabilities: ["coding"],
          name: "agent-multi",
          registries: ["global", "team-x"]
        })

      %{
        id_a: agent_a.id,
        id_b: agent_b.id,
        id_global: agent_global.id,
        id_multi: agent_multi.id
      }
    end

    test "scoped to team-x returns agent_a and agent_multi only", %{
      id_a: id_a,
      id_b: id_b,
      id_global: id_global,
      id_multi: id_multi
    } do
      assert {:ok, agents} = Agents.discover(%{capability: "*", registry: "team-x"})
      ids = Enum.map(agents, & &1.id)
      assert id_a in ids
      assert id_multi in ids
      refute id_b in ids
      refute id_global in ids
      assert length(agents) == 2
    end

    test "scoped to team-y returns only agent_b", %{
      id_a: id_a,
      id_b: id_b,
      id_global: id_global,
      id_multi: id_multi
    } do
      assert {:ok, agents} = Agents.discover(%{capability: "*", registry: "team-y"})
      ids = Enum.map(agents, & &1.id)
      assert id_b in ids
      refute id_a in ids
      refute id_global in ids
      refute id_multi in ids
      assert length(agents) == 1
    end

    test "no registry key defaults to global namespace", %{
      id_a: id_a,
      id_b: id_b,
      id_global: id_global,
      id_multi: id_multi
    } do
      assert {:ok, agents} = Agents.discover(%{capability: "*"})
      ids = Enum.map(agents, & &1.id)
      assert id_global in ids
      assert id_multi in ids
      refute id_a in ids
      refute id_b in ids
      assert length(agents) == 2
    end

    test "agent in both global and team-x is discoverable in team-x namespace", %{
      id_multi: id_multi
    } do
      assert {:ok, agents} = Agents.discover(%{capability: "*", registry: "team-x"})
      ids = Enum.map(agents, & &1.id)
      assert id_multi in ids
    end

    test "agent in both global and team-x is discoverable in global namespace", %{
      id_multi: id_multi
    } do
      assert {:ok, agents} = Agents.discover(%{capability: "*"})
      ids = Enum.map(agents, & &1.id)
      assert id_multi in ids
    end

    test "no agents in team-z returns empty list" do
      assert {:ok, []} = Agents.discover(%{capability: "*", registry: "team-z"})
    end

    test "scoped capability search returns only matching agents in that registry", %{
      id_a: id_a,
      id_multi: id_multi
    } do
      assert {:ok, agents} = Agents.discover(%{capability: "coding", registry: "team-x"})
      ids = Enum.map(agents, & &1.id)
      assert id_a in ids
      assert id_multi in ids
      assert length(agents) == 2
    end

    test "unscoped capability search defaults to global namespace", %{
      id_global: id_global,
      id_multi: id_multi,
      id_a: id_a,
      id_b: id_b
    } do
      assert {:ok, agents} = Agents.discover(%{capability: "coding"})
      ids = Enum.map(agents, & &1.id)
      assert id_global in ids
      assert id_multi in ids
      refute id_a in ids
      refute id_b in ids
    end

    test "scoped name search finds agent in registry", %{id_a: id_a} do
      assert {:ok, agents} = Agents.discover(%{name: "agent-a", registry: "team-x"})
      assert length(agents) == 1
      [agent] = agents
      assert agent.id == id_a
    end

    test "scoped name search returns empty when agent is in different registry", %{id_a: _id_a} do
      assert {:ok, []} = Agents.discover(%{name: "agent-a", registry: "team-y"})
    end

    test "unscoped name search defaults to global", %{id_global: id_global, id_a: id_a} do
      assert {:ok, agents} = Agents.discover(%{name: "agent-global"})
      assert length(agents) == 1
      [agent] = agents
      assert agent.id == id_global
      _ = id_a
    end
  end

  describe "register_agent/1 with polling_timeout_ms" do
    test "accepts custom polling_timeout_ms and returns it in agent struct" do
      assert {:ok, agent} =
               Agents.register_agent(%{
                 capabilities: ["test"],
                 polling_timeout_ms: 30_000
               })

      assert agent.polling_timeout_ms == 30_000
    end

    test "defaults polling_timeout_ms to 60_000 when not provided" do
      assert {:ok, agent} = Agents.register_agent(%{capabilities: ["test"]})
      assert agent.polling_timeout_ms == 60_000
    end
  end
end
