defmodule VicheWeb.Integration.OpenclawPluginFlowTest do
  @moduledoc """
  End-to-end integration tests simulating the full OpenClaw plugin lifecycle:
  HTTP registration → WebSocket connect → channel join → discover → send message → real-time push.
  """

  use VicheWeb.ChannelCase, async: false

  import Phoenix.ConnTest
  use VicheWeb, :verified_routes

  alias VicheWeb.AgentSocket

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  defp register_agent(params) do
    conn = post(build_conn(), ~p"/registry/register", params)
    %{"id" => agent_id} = json_response(conn, 201)
    agent_id
  end

  defp connect_and_join(agent_id) do
    AgentSocket
    |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
    |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    clear_all_agents()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "OpenClaw plugin full lifecycle" do
    test "registers via HTTP, connects WebSocket, and joins channel" do
      # Step 1: HTTP POST /registry/register
      conn =
        post(build_conn(), ~p"/registry/register", %{
          "capabilities" => ["coding"],
          "name" => "openclaw-agent",
          "description" => "OpenClaw instance"
        })

      assert %{"id" => agent_id} = json_response(conn, 201)
      assert String.length(agent_id) == 8

      # Steps 2 & 3: WebSocket connect + channel join
      assert {:ok, _, socket} = connect_and_join(agent_id)

      assert socket.assigns.agent_id == agent_id

      # Verify agent is present in the Registry
      assert [{_pid, _meta}] = Registry.lookup(Viche.AgentRegistry, agent_id)

      # Verify connection_type is set to :websocket on the AgentServer
      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      # Synchronize to ensure the GenServer has processed :websocket_connected
      _ = :sys.get_state(GenServer.whereis(via))
      state = Viche.AgentServer.get_state(via)
      assert state.connection_type == :websocket
    end

    test "discovers other agents via channel after HTTP registration" do
      # Register agent A via HTTP
      agent_a_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "openclaw-agent-a"
        })

      # Register agent B via HTTP
      agent_b_id =
        register_agent(%{
          "capabilities" => ["translation"],
          "name" => "openclaw-agent-b"
        })

      # Agent A connects WebSocket + joins channel
      {:ok, _, socket} = connect_and_join(agent_a_id)

      # Step 4: Discover via wildcard — both agents must appear
      ref = push(socket, "discover", %{"capability" => "*"})
      assert_reply ref, :ok, %{agents: agents}

      discovered_ids = Enum.map(agents, & &1.id)
      assert agent_a_id in discovered_ids
      assert agent_b_id in discovered_ids
    end

    test "sends message to another agent via channel and receiver gets real-time push" do
      # Register agent A (sender) and agent B (receiver) via HTTP
      agent_a_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "openclaw-sender"
        })

      agent_b_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "openclaw-receiver"
        })

      # Both agents connect WebSocket + join channels
      {:ok, _, socket_a} = connect_and_join(agent_a_id)
      {:ok, _, _socket_b} = connect_and_join(agent_b_id)

      # Step 5: Agent A sends a message to agent B via channel event
      ref =
        push(socket_a, "send_message", %{
          "to" => agent_b_id,
          "body" => "hello from openclaw",
          "type" => "task"
        })

      assert_reply ref, :ok, %{message_id: message_id}
      assert String.starts_with?(message_id, "msg-")

      # Step 6: Agent B receives the "new_message" real-time push
      assert_push "new_message", payload
      assert payload.body == "hello from openclaw"
      assert payload.type == "task"
      assert payload.from == agent_a_id
      assert is_binary(payload.id)
      assert is_binary(payload.sent_at)
    end

    test "re-registration flow: join fails for dead agent, new registration works" do
      # Register agent via HTTP
      agent_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "openclaw-reregister"
        })

      # Kill the agent process to simulate a server restart / crash
      [{pid, _}] = Registry.lookup(Viche.AgentRegistry, agent_id)
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)

      # Wait for the process to exit
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # Synchronize Registry partition processes to ensure ETS entries are removed
      Viche.AgentRegistry
      |> Supervisor.which_children()
      |> Enum.each(fn {_, reg_pid, _, _} -> _ = :sys.get_state(reg_pid) end)

      # Attempt channel join with stale ID → must fail
      assert {:error, %{reason: "agent_not_found"}} =
               AgentSocket
               |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
               |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      # Re-register via HTTP → must receive a NEW agent ID
      new_agent_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "openclaw-reregister"
        })

      assert new_agent_id != agent_id

      # Connect + join with the new ID → must succeed
      assert {:ok, _, socket} = connect_and_join(new_agent_id)
      assert socket.assigns.agent_id == new_agent_id
    end

    test "controller returns 422 for invalid capabilities" do
      conn =
        post(build_conn(), ~p"/registry/register", %{
          "capabilities" => [123],
          "name" => "invalid-agent"
        })

      assert %{"error" => "invalid_capabilities"} = json_response(conn, 422)
    end
  end
end
