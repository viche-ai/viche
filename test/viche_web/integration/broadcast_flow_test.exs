defmodule VicheWeb.Integration.BroadcastFlowTest do
  @moduledoc """
  End-to-end integration tests for broadcast messaging across REST and WebSocket
  transports.
  """

  use VicheWeb.ChannelCase, async: false

  import Phoenix.ConnTest
  use VicheWeb, :verified_routes

  alias Viche.Agents
  alias VicheWeb.AgentSocket

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

  defp register_agent(params) do
    conn = post(build_conn(), ~p"/registry/register", params)
    %{"id" => agent_id} = json_response(conn, 201)
    agent_id
  end

  defp authed_conn(agent_id) do
    build_conn()
    |> Plug.Conn.assign(:current_agent_id, agent_id)
  end

  defp connect_and_join(agent_id) do
    AgentSocket
    |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
    |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")
  end

  setup do
    clear_all_agents()
    :ok
  end

  describe "broadcast messaging end-to-end" do
    test "REST broadcast delivers to all registry members including sender" do
      agent_a_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "agent-a",
          "registries" => ["team-alpha"]
        })

      agent_b_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "agent-b",
          "registries" => ["team-alpha"]
        })

      agent_c_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "agent-c",
          "registries" => ["team-alpha"]
        })

      conn =
        authed_conn(agent_a_id)
        |> post(~p"/registry/team-alpha/broadcast", %{"body" => "hello team", "type" => "task"})

      assert %{"recipients" => 3, "message_ids" => message_ids} = json_response(conn, 202)
      assert length(message_ids) == 3

      drained_ids =
        [agent_a_id, agent_b_id, agent_c_id]
        |> Enum.map(fn agent_id ->
          assert {:ok, [message]} = Agents.drain_inbox(agent_id)
          assert message.from == agent_a_id
          assert message.body == "hello team"
          assert message.type == "task"
          message.id
        end)

      assert MapSet.new(drained_ids) == MapSet.new(message_ids)
    end

    test "WebSocket broadcast pushes new_message to sender and peers" do
      agent_a_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "socket-sender",
          "registries" => ["team-alpha"]
        })

      agent_b_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "socket-peer",
          "registries" => ["team-alpha"]
        })

      {:ok, _, socket_a} = connect_and_join(agent_a_id)
      {:ok, _, _socket_b} = connect_and_join(agent_b_id)

      ref =
        push(socket_a, "broadcast_message", %{
          "registry" => "team-alpha",
          "body" => "hello websocket",
          "type" => "task"
        })

      assert_reply ref, :ok, %{recipients: 2}

      assert_push "new_message", first_payload
      assert_push "new_message", second_payload

      [first_payload, second_payload]
      |> Enum.each(fn payload ->
        assert payload.from == agent_a_id
        assert payload.body == "hello websocket"
        assert payload.type == "task"
      end)

      assert {:ok, [message_a]} = Agents.drain_inbox(agent_a_id)
      assert {:ok, [message_b]} = Agents.drain_inbox(agent_b_id)

      assert message_a.body == "hello websocket"
      assert message_b.body == "hello websocket"
    end

    test "mixed transport broadcast pushes to websocket and drains for long-poll" do
      long_poll_agent_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "long-poll-agent",
          "registries" => ["team-alpha"]
        })

      websocket_agent_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "websocket-agent",
          "registries" => ["team-alpha"]
        })

      {:ok, _, _socket} = connect_and_join(websocket_agent_id)

      conn =
        authed_conn(long_poll_agent_id)
        |> post(~p"/registry/team-alpha/broadcast", %{
          "body" => "mixed transport payload",
          "type" => "task"
        })

      assert %{"recipients" => 2, "message_ids" => _message_ids} = json_response(conn, 202)

      assert_push "new_message", payload
      assert payload.from == long_poll_agent_id
      assert payload.body == "mixed transport payload"
      assert payload.type == "task"

      assert {:ok, [long_poll_message]} = Agents.drain_inbox(long_poll_agent_id)
      assert long_poll_message.from == long_poll_agent_id
      assert long_poll_message.body == "mixed transport payload"
      assert long_poll_message.type == "task"
    end

    test "broadcast preserves message fields while generating unique ids per recipient" do
      sender_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "integrity-sender",
          "registries" => ["team-alpha"]
        })

      recipient_a_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "integrity-recipient-a",
          "registries" => ["team-alpha"]
        })

      recipient_b_id =
        register_agent(%{
          "capabilities" => ["coding"],
          "name" => "integrity-recipient-b",
          "registries" => ["team-alpha"]
        })

      conn =
        authed_conn(sender_id)
        |> post(~p"/registry/team-alpha/broadcast", %{
          "body" => "integrity payload",
          "type" => "result"
        })

      assert %{"recipients" => 3, "message_ids" => message_ids} = json_response(conn, 202)

      messages =
        [sender_id, recipient_a_id, recipient_b_id]
        |> Enum.map(fn agent_id ->
          assert {:ok, [message]} = Agents.drain_inbox(agent_id)
          message
        end)

      assert Enum.all?(messages, fn message ->
               message.from == sender_id and
                 message.body == "integrity payload" and
                 message.type == "result"
             end)

      drained_ids = Enum.map(messages, & &1.id)
      assert length(drained_ids) == 3
      assert length(Enum.uniq(drained_ids)) == 3
      assert MapSet.new(drained_ids) == MapSet.new(message_ids)
    end
  end
end
