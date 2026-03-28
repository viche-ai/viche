defmodule Viche.AgentServerTest do
  use ExUnit.Case, async: false

  alias Viche.AgentServer

  defp unique_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp start_agent(opts \\ []) do
    id = Keyword.get(opts, :id, unique_id())
    capabilities = Keyword.get(opts, :capabilities, ["test"])
    polling_timeout_ms = Keyword.get(opts, :polling_timeout_ms, nil)

    full_opts = [id: id, capabilities: capabilities]

    full_opts =
      if polling_timeout_ms,
        do: Keyword.put(full_opts, :polling_timeout_ms, polling_timeout_ms),
        else: full_opts

    pid = start_supervised!({AgentServer, full_opts})
    {id, pid}
  end

  defp wait_for_exit(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
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

    test "new agent has default connection_type :long_poll" do
      {_id, pid} = start_agent()
      state = AgentServer.get_state(pid)
      assert state.connection_type == :long_poll
    end

    test "new agent has last_activity equal to registered_at" do
      {_id, pid} = start_agent()
      state = AgentServer.get_state(pid)
      assert %DateTime{} = state.last_activity
      assert DateTime.compare(state.last_activity, state.registered_at) == :eq
    end

    test "new agent has default polling_timeout_ms of 60_000" do
      {_id, pid} = start_agent()
      state = AgentServer.get_state(pid)
      assert state.polling_timeout_ms == 60_000
    end

    test "polling_timeout_ms is configurable via start opts" do
      {_id, pid} = start_agent(polling_timeout_ms: 30_000)
      state = AgentServer.get_state(pid)
      assert state.polling_timeout_ms == 30_000
    end
  end

  describe "WebSocket grace period (Mode 1)" do
    test "agent stays alive during grace period after disconnect" do
      {_id, pid} = start_agent()

      send(pid, :websocket_disconnected)
      # Synchronize to ensure the message was processed
      _ = :sys.get_state(pid)

      # Agent should still be alive immediately after disconnect
      assert Process.alive?(pid)
    end

    test "agent is deregistered after grace period expires" do
      {_id, pid} = start_agent()

      send(pid, :websocket_disconnected)

      # Wait for grace period (150ms in tests) plus buffer
      wait_for_exit(pid)
      refute Process.alive?(pid)
    end

    test "reconnecting within grace period cancels deregistration" do
      {_id, pid} = start_agent()

      # Disconnect — starts grace timer
      send(pid, :websocket_disconnected)
      _ = :sys.get_state(pid)

      # Reconnect before grace period expires
      send(pid, :websocket_connected)
      _ = :sys.get_state(pid)

      # Wait well past grace period (150ms in tests)
      Process.sleep(300)

      # Agent should still be alive
      assert Process.alive?(pid)
    end

    test "websocket_connected sets connection_type to :websocket" do
      {_id, pid} = start_agent()

      send(pid, :websocket_connected)
      _ = :sys.get_state(pid)

      state = AgentServer.get_state(pid)
      assert state.connection_type == :websocket
    end
  end

  describe "polling timeout (Mode 2)" do
    test "long-poll agent is deregistered after polling_timeout_ms with no activity" do
      # Use very short timeout for tests
      {_id, pid} = start_agent(polling_timeout_ms: 100)

      # Wait for timeout to fire
      wait_for_exit(pid)
      refute Process.alive?(pid)
    end

    test "inbox read resets the polling timer and keeps agent alive" do
      # Register with 200ms timeout
      {_id, pid} = start_agent(polling_timeout_ms: 200)

      # Poll at 150ms (before timeout)
      Process.sleep(150)
      AgentServer.drain_inbox(pid)

      # Wait 100ms more (total ~250ms but timer was reset at 150ms)
      Process.sleep(100)

      # Agent should still be alive (new timeout of 200ms from poll time has not expired)
      assert Process.alive?(pid)
    end

    test "websocket agents skip polling timeout check" do
      # Register with very short polling timeout
      {_id, pid} = start_agent(polling_timeout_ms: 100)

      # Upgrade to WebSocket — should cancel polling-based deregistration
      send(pid, :websocket_connected)
      _ = :sys.get_state(pid)

      # Wait well past polling timeout
      Process.sleep(300)

      # Agent should still be alive (WebSocket mode ignores polling timeout)
      assert Process.alive?(pid)
    end
  end

  describe "drain_inbox/1 updates last_activity" do
    test "drain_inbox updates last_activity to current time" do
      {_id, pid} = start_agent()
      state_before = AgentServer.get_state(pid)
      initial_activity = state_before.last_activity

      # Small delay to ensure time difference
      Process.sleep(10)
      AgentServer.drain_inbox(pid)

      state_after = AgentServer.get_state(pid)
      assert DateTime.compare(state_after.last_activity, initial_activity) == :gt
    end
  end
end
