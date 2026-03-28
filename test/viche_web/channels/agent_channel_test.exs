defmodule VicheWeb.AgentChannelTest do
  use VicheWeb.ChannelCase

  alias Viche.Agents
  alias VicheWeb.AgentSocket

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

  setup do
    clear_all_agents()
    {:ok, agent} = Agents.register_agent(%{capabilities: ["testing"], name: "test-agent"})
    %{agent_id: agent.id}
  end

  describe "join/3" do
    test "joins valid agent topic successfully", %{agent_id: agent_id} do
      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      assert socket.assigns.agent_id == agent_id
    end

    test "returns error when agent does not exist" do
      assert {:error, %{reason: "agent_not_found"}} =
               AgentSocket
               |> socket("agent_socket:nonexistent", %{agent_id: "nonexistent"})
               |> subscribe_and_join(VicheWeb.AgentChannel, "agent:nonexistent")
    end
  end

  describe "handle_in/3 - discover" do
    setup %{agent_id: agent_id} do
      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      %{socket: socket}
    end

    test "discover by capability returns matching agents", %{socket: socket, agent_id: agent_id} do
      ref = push(socket, "discover", %{"capability" => "testing"})

      assert_reply ref, :ok, %{agents: agents}
      assert is_list(agents)
      ids = Enum.map(agents, & &1.id)
      assert agent_id in ids
    end

    test "discover by name returns matching agents", %{socket: socket, agent_id: agent_id} do
      ref = push(socket, "discover", %{"name" => "test-agent"})

      assert_reply ref, :ok, %{agents: agents}
      assert is_list(agents)
      ids = Enum.map(agents, & &1.id)
      assert agent_id in ids
    end

    test "discover with no matches returns empty list", %{socket: socket} do
      ref = push(socket, "discover", %{"capability" => "nonexistent"})

      assert_reply ref, :ok, %{agents: []}
    end
  end

  describe "handle_in/3 - send_message" do
    setup %{agent_id: agent_id} do
      {:ok, agent_b} = Agents.register_agent(%{capabilities: ["rcv"], name: "receiver"})

      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      %{socket: socket, receiver_id: agent_b.id}
    end

    test "send_message delivers message and returns message_id", %{
      socket: socket,
      receiver_id: receiver_id
    } do
      ref =
        push(socket, "send_message", %{
          "to" => receiver_id,
          "body" => "hello from channel",
          "type" => "task"
        })

      assert_reply ref, :ok, %{message_id: message_id}
      assert String.starts_with?(message_id, "msg-")

      assert {:ok, [msg]} = Agents.inspect_inbox(receiver_id)
      assert msg.body == "hello from channel"
    end

    test "send_message to unknown agent returns error", %{socket: socket} do
      ref =
        push(socket, "send_message", %{
          "to" => "ghost",
          "body" => "hello",
          "type" => "task"
        })

      assert_reply ref, :error, %{reason: :agent_not_found}
    end
  end

  describe "handle_in/3 - inspect_inbox" do
    setup %{agent_id: agent_id} do
      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      %{socket: socket}
    end

    test "returns inbox messages without consuming them", %{socket: socket, agent_id: agent_id} do
      Agents.send_message(%{to: agent_id, from: "sender", body: "peek", type: "ping"})

      ref = push(socket, "inspect_inbox", %{})
      assert_reply ref, :ok, %{messages: messages}

      assert length(messages) == 1
      [msg] = messages
      assert msg.body == "peek"
      assert msg.from == "sender"

      # Second inspect still returns messages (not consumed)
      ref2 = push(socket, "inspect_inbox", %{})
      assert_reply ref2, :ok, %{messages: messages2}
      assert length(messages2) == 1
    end
  end

  describe "handle_in/3 - drain_inbox" do
    setup %{agent_id: agent_id} do
      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      %{socket: socket}
    end

    test "returns inbox messages and consumes them", %{socket: socket, agent_id: agent_id} do
      Agents.send_message(%{to: agent_id, from: "sender", body: "drain me", type: "task"})

      ref = push(socket, "drain_inbox", %{})
      assert_reply ref, :ok, %{messages: messages}

      assert length(messages) == 1
      [msg] = messages
      assert msg.body == "drain me"

      # Second drain returns empty (consumed)
      ref2 = push(socket, "drain_inbox", %{})
      assert_reply ref2, :ok, %{messages: []}
    end
  end

  describe "real-time push - new_message" do
    test "connected client receives new_message push when a message is sent to it", %{
      agent_id: agent_id
    } do
      {:ok, _, _socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      Agents.send_message(%{to: agent_id, from: "pusher", body: "real-time!", type: "task"})

      assert_push "new_message", payload
      assert payload.body == "real-time!"
      assert payload.from == "pusher"
      assert payload.type == "task"
      assert is_binary(payload.id)
      assert is_binary(payload.sent_at)
    end
  end
end
