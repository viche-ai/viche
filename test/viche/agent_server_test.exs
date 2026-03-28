defmodule Viche.AgentServerTest do
  use ExUnit.Case, async: false

  alias Viche.AgentServer

  defp unique_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  describe "start_link/1" do
    test "starts agent server process" do
      opts = [
        id: unique_id(),
        name: "test-agent",
        capabilities: ["coding"],
        description: "Test agent"
      ]

      assert {:ok, pid} = AgentServer.start_link(opts)
      assert is_pid(pid)
    end

    test "registers agent in AgentRegistry" do
      agent_id = unique_id()

      opts = [
        id: agent_id,
        name: "registry-agent",
        capabilities: ["testing"],
        description: nil
      ]

      {:ok, _pid} = AgentServer.start_link(opts)
      assert [{_pid, _meta}] = Registry.lookup(Viche.AgentRegistry, agent_id)
    end

    test "stores metadata as registry value" do
      agent_id = unique_id()

      opts = [
        id: agent_id,
        name: "meta-agent",
        capabilities: ["reading", "writing"],
        description: "Reads and writes"
      ]

      {:ok, _pid} = AgentServer.start_link(opts)
      [{_pid, meta}] = Registry.lookup(Viche.AgentRegistry, agent_id)

      assert meta.name == "meta-agent"
      assert meta.capabilities == ["reading", "writing"]
      assert meta.description == "Reads and writes"
    end
  end

  describe "get_state/1" do
    test "returns the full agent struct" do
      agent_id = unique_id()

      opts = [
        id: agent_id,
        name: "state-agent",
        capabilities: ["reading"],
        description: "I read things"
      ]

      {:ok, pid} = AgentServer.start_link(opts)
      state = AgentServer.get_state(pid)

      assert %Viche.Agent{} = state
      assert state.id == agent_id
      assert state.name == "state-agent"
      assert state.capabilities == ["reading"]
      assert state.description == "I read things"
      assert state.inbox == []
      assert %DateTime{} = state.registered_at
    end

    test "get_state works via via-tuple" do
      agent_id = unique_id()

      opts = [
        id: agent_id,
        name: "via-agent",
        capabilities: ["via"],
        description: nil
      ]

      {:ok, _pid} = AgentServer.start_link(opts)
      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      state = AgentServer.get_state(via)

      assert state.id == agent_id
    end
  end
end
