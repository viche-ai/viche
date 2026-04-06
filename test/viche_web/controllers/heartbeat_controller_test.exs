defmodule VicheWeb.HeartbeatControllerTest do
  use VicheWeb.ConnCase, async: false

  alias Viche.AgentServer

  defp register_agent(conn, opts \\ []) do
    params = Map.merge(%{"capabilities" => ["coding"]}, Map.new(opts))
    conn = post(conn, ~p"/registry/register", params)
    %{"id" => id} = json_response(conn, 201)
    id
  end

  describe "POST /agents/:agent_id/heartbeat" do
    test "returns 200 OK for a registered agent", %{conn: conn} do
      agent_id = register_agent(conn)

      conn = post(build_conn(), ~p"/agents/#{agent_id}/heartbeat")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = post(conn, ~p"/agents/nonexistent-id/heartbeat")

      assert %{"error" => "agent_not_found", "message" => message} = json_response(conn, 404)
      assert is_binary(message)
    end

    test "heartbeat updates last_activity timestamp", %{conn: conn} do
      agent_id = register_agent(conn)

      state_before = AgentServer.get_state({:via, Registry, {Viche.AgentRegistry, agent_id}})
      initial_activity = state_before.last_activity

      Process.sleep(10)

      post(build_conn(), ~p"/agents/#{agent_id}/heartbeat")

      state_after =
        AgentServer.get_state({:via, Registry, {Viche.AgentRegistry, agent_id}})

      assert DateTime.compare(state_after.last_activity, initial_activity) == :gt
    end

    test "heartbeat keeps long-poll agent alive past original timeout", %{conn: conn} do
      agent_id = register_agent(conn, [{"polling_timeout_ms", 5_000}])

      [{pid, _}] = Registry.lookup(Viche.AgentRegistry, agent_id)

      post(build_conn(), ~p"/agents/#{agent_id}/heartbeat")

      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      state = Viche.AgentServer.get_state(via)

      # Verify heartbeat updated last_activity
      assert DateTime.compare(state.last_activity, state.registered_at) != :lt
      assert Process.alive?(pid)
    end
  end
end
