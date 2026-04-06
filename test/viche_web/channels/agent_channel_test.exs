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

    test "register-on-join creates an agent and returns its id" do
      params = %{
        "capabilities" => ["testing", "ws"],
        "name" => "register-join-agent",
        "description" => "registered via channel join",
        "registries" => ["global"]
      }

      assert {:ok, %{agent_id: agent_id}, socket} =
               AgentSocket
               |> socket("agent_socket:register", %{})
               |> subscribe_and_join(VicheWeb.AgentChannel, "agent:register", params)

      assert is_binary(agent_id)
      assert socket.assigns.agent_id == agent_id
      assert {:ok, [_]} = Agents.discover(%{name: "register-join-agent"})
    end

    test "register-on-join returns error when capabilities are missing" do
      assert {:error, %{reason: "capabilities_required"}} =
               AgentSocket
               |> socket("agent_socket:register", %{})
               |> subscribe_and_join(VicheWeb.AgentChannel, "agent:register", %{"name" => "oops"})
    end

    test "register-on-join returns error when capabilities are invalid" do
      assert {:error, %{reason: "invalid_capabilities"}} =
               AgentSocket
               |> socket("agent_socket:register", %{})
               |> subscribe_and_join(VicheWeb.AgentChannel, "agent:register", %{
                 "capabilities" => ["ok", 123]
               })
    end

    test "register-on-join returns error when optional params are invalid" do
      assert {:error, %{reason: "invalid_name"}} =
               AgentSocket
               |> socket("agent_socket:register", %{})
               |> subscribe_and_join(VicheWeb.AgentChannel, "agent:register", %{
                 "capabilities" => ["ok"],
                 "name" => 123
               })
    end
  end

  describe "AgentSocket.connect/3" do
    test "allows websocket connect without agent_id for register flow" do
      assert {:ok, socket} = connect(AgentSocket, %{})
      refute Map.has_key?(socket.assigns, :agent_id)
    end

    test "connect without agent_id cannot join existing agent topic" do
      {:ok, socket} = connect(AgentSocket, %{})
      {:ok, existing_agent} = Agents.register_agent(%{capabilities: ["testing"]})

      assert {:error, %{reason: "agent_id_required"}} =
               subscribe_and_join(socket, VicheWeb.AgentChannel, "agent:#{existing_agent.id}")
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

    test "discover with wildcard capability '*' returns all registered agents", %{
      socket: socket,
      agent_id: agent_id
    } do
      ref = push(socket, "discover", %{"capability" => "*"})

      assert_reply ref, :ok, %{agents: agents}
      assert is_list(agents)
      ids = Enum.map(agents, & &1.id)
      assert agent_id in ids
    end

    test "discover with wildcard name '*' returns all registered agents", %{
      socket: socket,
      agent_id: agent_id
    } do
      ref = push(socket, "discover", %{"name" => "*"})

      assert_reply ref, :ok, %{agents: agents}
      assert is_list(agents)
      ids = Enum.map(agents, & &1.id)
      assert agent_id in ids
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

    test "send_message 'from' is always socket.assigns.agent_id, ignoring any client-supplied 'from'",
         %{socket: socket, agent_id: sender_id, receiver_id: receiver_id} do
      ref =
        push(socket, "send_message", %{
          "to" => receiver_id,
          "body" => "impersonation attempt",
          "type" => "task",
          # client tries to set from — must be ignored
          "from" => "evil-impersonator-id"
        })

      assert_reply ref, :ok, %{message_id: _}

      assert {:ok, [msg]} = Agents.inspect_inbox(receiver_id)
      assert msg.from == sender_id
      refute msg.from == "evil-impersonator-id"
    end

    test "send_message to unknown agent returns error", %{socket: socket} do
      ref =
        push(socket, "send_message", %{
          "to" => "ghost",
          "body" => "hello",
          "type" => "task"
        })

      assert_reply ref, :error, %{error: "agent_not_found", message: _}
    end

    test "send_message missing 'to' field returns validation error", %{socket: socket} do
      ref = push(socket, "send_message", %{"body" => "hello", "type" => "result"})

      assert_reply ref, :error, %{error: "missing_field", message: message}
      assert message =~ "'to'"
    end

    test "send_message missing 'body' field returns validation error", %{socket: socket} do
      ref = push(socket, "send_message", %{"to" => "someagent"})

      assert_reply ref, :error, %{error: "missing_field", message: message}
      assert message =~ "'body'"
    end

    test "send_message with empty params returns validation error", %{socket: socket} do
      ref = push(socket, "send_message", %{})

      assert_reply ref, :error, %{error: "missing_fields", message: _}
    end
  end

  # ---------------------------------------------------------------------------
  # Impersonation prevention tests (issue #21)
  # ---------------------------------------------------------------------------

  describe "impersonation prevention via channel" do
    setup %{agent_id: agent_id} do
      {:ok, agent_b} =
        Agents.register_agent(%{capabilities: ["rcv"], name: "impersonation-target"})

      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      %{socket: socket, receiver_id: agent_b.id}
    end

    test "client-supplied 'from' is silently overwritten by socket.assigns.agent_id",
         %{socket: socket, agent_id: real_sender_id, receiver_id: receiver_id} do
      ref =
        push(socket, "send_message", %{
          "to" => receiver_id,
          "body" => "sneak",
          "type" => "ping",
          "from" => "totally-different-agent"
        })

      assert_reply ref, :ok, %{message_id: _}

      assert {:ok, [msg]} = Agents.inspect_inbox(receiver_id)
      assert msg.from == real_sender_id
      refute msg.from == "totally-different-agent"
    end

    test "message is attributed to the correct socket-verified agent even when 'from' is absent",
         %{socket: socket, agent_id: real_sender_id, receiver_id: receiver_id} do
      ref =
        push(socket, "send_message", %{
          "to" => receiver_id,
          "body" => "legit message",
          "type" => "task"
        })

      assert_reply ref, :ok, %{message_id: _}

      assert {:ok, [msg]} = Agents.inspect_inbox(receiver_id)
      assert msg.from == real_sender_id
    end

    test "two different authenticated sockets produce correct distinct 'from' values" do
      clear_all_agents()

      {:ok, agent_a} = Agents.register_agent(%{capabilities: ["alpha"]})
      {:ok, agent_b} = Agents.register_agent(%{capabilities: ["beta"]})
      {:ok, recipient} = Agents.register_agent(%{capabilities: ["rcv"]})

      {:ok, _, socket_a} =
        AgentSocket
        |> socket("agent_socket:#{agent_a.id}", %{agent_id: agent_a.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_a.id}")

      {:ok, _, socket_b} =
        AgentSocket
        |> socket("agent_socket:#{agent_b.id}", %{agent_id: agent_b.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_b.id}")

      ref_a =
        push(socket_a, "send_message", %{
          "to" => recipient.id,
          "body" => "from A",
          "type" => "task"
        })

      ref_b =
        push(socket_b, "send_message", %{
          "to" => recipient.id,
          "body" => "from B",
          "type" => "task"
        })

      assert_reply ref_a, :ok, %{message_id: _}
      assert_reply ref_b, :ok, %{message_id: _}

      assert {:ok, messages} = Agents.inspect_inbox(recipient.id)
      froms = Enum.map(messages, & &1.from)
      assert agent_a.id in froms
      assert agent_b.id in froms
    end
  end

  describe "handle_in/3 - discover validation" do
    setup %{agent_id: agent_id} do
      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      %{socket: socket}
    end

    test "discover with no capability or name returns validation error", %{socket: socket} do
      ref = push(socket, "discover", %{})

      assert_reply ref, :error, %{error: "missing_field", message: _}
    end

    test "discover with unrecognised field returns validation error", %{socket: socket} do
      ref = push(socket, "discover", %{"unknown_field" => "value"})

      assert_reply ref, :error, %{error: "missing_field", message: _}
    end
  end

  describe "handle_in/3 - unknown event" do
    setup %{agent_id: agent_id} do
      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      %{socket: socket}
    end

    test "unknown event returns error reply with event name", %{socket: socket} do
      ref = push(socket, "not_a_real_event", %{"data" => "anything"})

      assert_reply ref, :error, %{error: "unknown_event", message: message}
      assert message =~ "not_a_real_event"
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

    test "register-on-join client receives new_message push for newly created agent" do
      params = %{
        "capabilities" => ["testing"],
        "name" => "rt-register-agent"
      }

      {:ok, %{agent_id: registered_id}, _socket} =
        AgentSocket
        |> socket("agent_socket:register-rt", %{})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:register", params)

      {:ok, sender} = Agents.register_agent(%{capabilities: ["sender"], name: "sender-agent"})

      assert {:ok, _message_id} =
               Agents.send_message(%{
                 to: registered_id,
                 from: sender.id,
                 body: "hello registered"
               })

      assert_push "new_message", payload
      assert payload.body == "hello registered"
      assert payload.from == sender.id
    end
  end

  describe "join/3 - sends :websocket_connected to AgentServer" do
    test "joining channel sets connection_type to :websocket on the AgentServer", %{
      agent_id: agent_id
    } do
      {:ok, _, _socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      # Synchronize with the AgentServer to ensure the message was processed
      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      _ = :sys.get_state(GenServer.whereis(via))

      state = Viche.AgentServer.get_state(via)
      assert state.connection_type == :websocket
    end
  end

  # ---------------------------------------------------------------------------
  # Registry Channel Tests (Phase 3)
  # ---------------------------------------------------------------------------

  describe "registry channel - join/3" do
    test "agent in team-x can join registry:team-x" do
      clear_all_agents()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["testing"], registries: ["team-x"]})

      assert {:ok, _, socket} =
               AgentSocket
               |> socket("agent_socket:#{agent.id}", %{agent_id: agent.id})
               |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-x")

      assert socket.assigns.registry_token == "team-x"
    end

    test "agent in team-x cannot join registry:team-y" do
      clear_all_agents()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["testing"], registries: ["team-x"]})

      assert {:error, %{reason: "not_in_registry"}} =
               AgentSocket
               |> socket("agent_socket:#{agent.id}", %{agent_id: agent.id})
               |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-y")
    end

    test "agent in global registry can join registry:global" do
      clear_all_agents()
      # Default registration puts agent in "global"
      {:ok, agent} = Agents.register_agent(%{capabilities: ["testing"]})

      assert {:ok, _, _socket} =
               AgentSocket
               |> socket("agent_socket:#{agent.id}", %{agent_id: agent.id})
               |> subscribe_and_join(VicheWeb.AgentChannel, "registry:global")
    end

    test "agent not in any registry cannot join any registry channel" do
      clear_all_agents()
      {:ok, agent} = Agents.register_agent(%{capabilities: ["testing"], registries: ["team-x"]})

      assert {:error, %{reason: "not_in_registry"}} =
               AgentSocket
               |> socket("agent_socket:#{agent.id}", %{agent_id: agent.id})
               |> subscribe_and_join(VicheWeb.AgentChannel, "registry:global")
    end
  end

  describe "registry channel - scoped discover" do
    test "discover returns only agents in the registry", %{agent_id: _global_agent_id} do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{capabilities: ["coding"], registries: ["team-x"]})

      # agent_b is in "global" (default), not "team-x"
      {:ok, agent_b} = Agents.register_agent(%{capabilities: ["coding"]})

      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_a.id}", %{agent_id: agent_a.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-x")

      ref = push(socket, "discover", %{"capability" => "*"})
      assert_reply ref, :ok, %{agents: agents}

      ids = Enum.map(agents, & &1.id)
      assert agent_a.id in ids
      refute agent_b.id in ids
    end

    test "discover by name is scoped to the registry" do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{
          capabilities: ["coding"],
          name: "forge",
          registries: ["team-x"]
        })

      # Same name, different registry
      {:ok, _agent_b} =
        Agents.register_agent(%{capabilities: ["coding"], name: "forge", registries: ["team-y"]})

      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_a.id}", %{agent_id: agent_a.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-x")

      ref = push(socket, "discover", %{"name" => "forge"})
      assert_reply ref, :ok, %{agents: agents}

      assert length(agents) == 1
      assert hd(agents).id == agent_a.id
    end
  end

  describe "registry channel - agent_joined broadcast" do
    test "agent receives agent_joined when another agent registers in the same registry" do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{capabilities: ["observer"], registries: ["team-x"]})

      {:ok, _, _socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_a.id}", %{agent_id: agent_a.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-x")

      {:ok, agent_b} =
        Agents.register_agent(%{
          capabilities: ["builder"],
          name: "new-agent",
          registries: ["team-x"]
        })

      assert_push "agent_joined", payload
      assert payload.id == agent_b.id
      assert payload.name == agent_b.name
      assert payload.capabilities == agent_b.capabilities
    end

    test "agent does NOT receive agent_joined when agent registers in a different registry" do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{capabilities: ["observer"], registries: ["team-x"]})

      {:ok, _, _socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_a.id}", %{agent_id: agent_a.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-x")

      # Register in team-y — should NOT trigger agent_joined on team-x
      {:ok, _agent_b} =
        Agents.register_agent(%{capabilities: ["builder"], registries: ["team-y"]})

      refute_push "agent_joined", _payload
    end
  end

  describe "registry channel - agent_left broadcast" do
    test "agent receives agent_left when another agent in same registry deregisters" do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{capabilities: ["observer"], registries: ["team-x"]})

      {:ok, agent_b} =
        Agents.register_agent(%{capabilities: ["worker"], registries: ["team-x"]})

      {:ok, _, _socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_a.id}", %{agent_id: agent_a.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-x")

      :ok = Agents.deregister(agent_b.id)

      assert_push "agent_left", payload
      assert payload.id == agent_b.id
    end

    test "agent does NOT receive agent_left when agent in different registry deregisters" do
      clear_all_agents()

      {:ok, agent_a} =
        Agents.register_agent(%{capabilities: ["observer"], registries: ["team-x"]})

      {:ok, agent_b} =
        Agents.register_agent(%{capabilities: ["worker"], registries: ["team-y"]})

      {:ok, _, _socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_a.id}", %{agent_id: agent_a.id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "registry:team-x")

      :ok = Agents.deregister(agent_b.id)

      refute_push "agent_left", _payload
    end
  end

  describe "terminate/2 - sends :websocket_disconnected to AgentServer" do
    test "closing the socket triggers grace period and eventually deregisters the agent", %{
      agent_id: agent_id
    } do
      [{pid, _}] = Registry.lookup(Viche.AgentRegistry, agent_id)
      ref = Process.monitor(pid)

      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      # Close the socket — triggers terminate/2 → :websocket_disconnected → grace timer
      Process.unlink(socket.channel_pid)
      close(socket)

      # Wait for grace period (150ms in tests) and agent process to exit
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      # Synchronize with Registry partitions to ensure the :DOWN message has been processed
      # and the ETS entries have been removed before checking
      Viche.AgentRegistry
      |> Supervisor.which_children()
      |> Enum.each(fn {_, reg_pid, _, _} -> _ = :sys.get_state(reg_pid) end)

      assert Registry.lookup(Viche.AgentRegistry, agent_id) == []
    end

    test "disconnecting sets grace timer but agent stays alive during grace period", %{
      agent_id: agent_id
    } do
      [{pid, _}] = Registry.lookup(Viche.AgentRegistry, agent_id)
      ref = Process.monitor(pid)

      {:ok, _, socket} =
        AgentSocket
        |> socket("agent_socket:#{agent_id}", %{agent_id: agent_id})
        |> subscribe_and_join(VicheWeb.AgentChannel, "agent:#{agent_id}")

      # Close the socket
      Process.unlink(socket.channel_pid)
      close(socket)

      # Agent should stay up during grace period (no DOWN yet)
      refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      # It eventually shuts down when grace period expires
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end
end
