defmodule VicheWeb.InboxControllerTest do
  use VicheWeb.ConnCase, async: false

  alias Viche.Accounts.User
  alias Viche.AgentServer
  alias Viche.Repo

  defp register_agent(conn, capabilities) do
    conn = post(conn, ~p"/registry/register", %{"capabilities" => capabilities})
    %{"id" => id} = json_response(conn, 201)
    id
  end

  defp register_agent(conn), do: register_agent(conn, ["coding"])

  # Registers a throwaway sender agent and uses it as the verified `current_agent_id`
  # so that MessageController can derive `from` from the server-assigned identity.
  # A `from:` option may still be passed and is forwarded as the registered sender
  # when it looks like a registered agent ID; otherwise a fresh agent is created.
  defp send_message(agent_id, opts) do
    type = Keyword.get(opts, :type, "task")
    body = Keyword.get(opts, :body, "hello")
    in_reply_to = Keyword.get(opts, :in_reply_to)
    conversation_id = Keyword.get(opts, :conversation_id)

    # Use the caller-supplied `from` agent_id when given; fall back to registering
    # a fresh throwaway agent so there is always a valid `current_agent_id`.
    sender_id =
      case Keyword.get(opts, :from) do
        nil ->
          conn = post(build_conn(), ~p"/registry/register", %{"capabilities" => ["sender"]})
          %{"id" => id} = json_response(conn, 201)
          id

        id ->
          id
      end

    build_conn()
    |> Plug.Conn.assign(:current_agent_id, sender_id)
    |> post(~p"/messages/#{agent_id}", %{
      "type" => type,
      "body" => body,
      "in_reply_to" => in_reply_to,
      "conversation_id" => conversation_id
    })
  end

  describe "GET /inbox/:agent_id" do
    test "returns 200 with empty messages for new agent", %{conn: conn} do
      agent_id = register_agent(conn)

      conn = get(build_conn(), ~p"/inbox/#{agent_id}")

      assert %{"messages" => []} = json_response(conn, 200)
    end

    test "returns messages oldest-first and clears inbox", %{conn: conn} do
      agent_id = register_agent(conn)

      send_message(agent_id, body: "first", from: "a1")
      send_message(agent_id, body: "second", from: "a2")
      send_message(agent_id, body: "third", from: "a3")

      conn = get(build_conn(), ~p"/inbox/#{agent_id}")
      %{"messages" => messages} = json_response(conn, 200)

      assert length(messages) == 3
      assert Enum.at(messages, 0)["body"] == "first"
      assert Enum.at(messages, 1)["body"] == "second"
      assert Enum.at(messages, 2)["body"] == "third"
    end

    test "messages include all required fields", %{conn: conn} do
      agent_id = register_agent(conn)

      send_message(agent_id, type: "task", from: "sender-abc", body: "do the thing")

      conn = get(build_conn(), ~p"/inbox/#{agent_id}")
      %{"messages" => [msg]} = json_response(conn, 200)

      assert Map.has_key?(msg, "id")
      assert Map.has_key?(msg, "type")
      assert Map.has_key?(msg, "from")
      assert Map.has_key?(msg, "body")
      assert Map.has_key?(msg, "sent_at")
      assert Map.has_key?(msg, "in_reply_to")
      assert Map.has_key?(msg, "conversation_id")

      assert String.starts_with?(msg["id"], "msg-")
      assert msg["type"] == "task"
      assert msg["from"] == "sender-abc"
      assert msg["body"] == "do the thing"
      assert msg["in_reply_to"] == nil
      assert msg["conversation_id"] == nil
      # Verify ISO 8601 format
      assert {:ok, _, _} = DateTime.from_iso8601(msg["sent_at"])
    end

    test "messages include in_reply_to and conversation_id when provided", %{conn: conn} do
      agent_id = register_agent(conn)

      send_message(agent_id,
        type: "result",
        body: "threaded",
        in_reply_to: "msg-parent",
        conversation_id: "conv-thread"
      )

      conn = get(build_conn(), ~p"/inbox/#{agent_id}")
      %{"messages" => [msg]} = json_response(conn, 200)

      assert msg["in_reply_to"] == "msg-parent"
      assert msg["conversation_id"] == "conv-thread"
    end

    test "second read after consume returns empty list (Erlang receive semantics)", %{conn: conn} do
      agent_id = register_agent(conn)

      send_message(agent_id, body: "first")

      # First read — consumes the message
      conn = get(build_conn(), ~p"/inbox/#{agent_id}")
      %{"messages" => messages} = json_response(conn, 200)
      assert length(messages) == 1

      # Second read — inbox must be empty
      conn2 = get(build_conn(), ~p"/inbox/#{agent_id}")
      assert %{"messages" => []} = json_response(conn2, 200)
    end

    test "new messages arriving after drain appear on next read", %{conn: conn} do
      agent_id = register_agent(conn)

      send_message(agent_id, body: "before drain")

      # Drain inbox
      get(build_conn(), ~p"/inbox/#{agent_id}")

      # Send a new message after drain
      send_message(agent_id, body: "after drain")

      conn = get(build_conn(), ~p"/inbox/#{agent_id}")
      %{"messages" => messages} = json_response(conn, 200)

      assert length(messages) == 1
      assert hd(messages)["body"] == "after drain"
    end

    test "full round-trip: A sends to B, B reads, B replies to A, A reads", %{conn: conn} do
      agent_a = register_agent(conn, ["testing"])
      agent_b = register_agent(build_conn(), ["coding"])

      # A sends task to B
      send_message(agent_b, type: "task", from: agent_a, body: "implement feature X")

      # B reads inbox — gets and consumes message
      conn = get(build_conn(), ~p"/inbox/#{agent_b}")
      %{"messages" => [task]} = json_response(conn, 200)
      assert task["from"] == agent_a
      assert task["body"] == "implement feature X"

      # B's inbox is now empty
      conn = get(build_conn(), ~p"/inbox/#{agent_b}")
      assert %{"messages" => []} = json_response(conn, 200)

      # B replies to A
      send_message(agent_a, type: "result", from: agent_b, body: "done")

      # A reads inbox
      conn = get(build_conn(), ~p"/inbox/#{agent_a}")
      %{"messages" => [reply]} = json_response(conn, 200)
      assert reply["from"] == agent_b
      assert reply["body"] == "done"
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, ~p"/inbox/nonexistent-agent-id")

      assert %{"error" => "agent_not_found", "message" => message} = json_response(conn, 404)
      assert is_binary(message)
    end

    test "returns 403 with message when user does not own the agent", %{conn: conn} do
      {:ok, owner} =
        Repo.insert(User.changeset(%User{}, %{email: "inbox-owner@test.com"}))

      # Set both assigns so ApiAuth plug bypasses and preserves current_user_id
      conn_owner =
        conn
        |> Plug.Conn.assign(:current_user_id, owner.id)
        |> Plug.Conn.assign(:current_agent_id, nil)

      conn_owner = post(conn_owner, ~p"/registry/register", %{"capabilities" => ["test"]})
      %{"id" => agent_id} = json_response(conn_owner, 201)

      {:ok, other_user} =
        Repo.insert(User.changeset(%User{}, %{email: "inbox-other@test.com"}))

      conn_other =
        build_conn()
        |> Plug.Conn.assign(:current_user_id, other_user.id)
        |> Plug.Conn.assign(:current_agent_id, nil)

      conn_other = get(conn_other, ~p"/inbox/#{agent_id}")

      assert %{"error" => "not_owner", "message" => message} = json_response(conn_other, 403)
      assert is_binary(message)
    end

    test "inbox drain is atomic via GenServer serialization", %{conn: conn} do
      agent_id = register_agent(conn)

      # Send 3 messages
      for i <- 1..3 do
        send_message(agent_id, body: "msg-#{i}")
      end

      # Drain via HTTP — all 3 must be returned atomically
      conn = get(build_conn(), ~p"/inbox/#{agent_id}")
      %{"messages" => messages} = json_response(conn, 200)

      assert length(messages) == 3

      # Verify GenServer state is reset to empty
      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      state = AgentServer.get_state(via)
      assert state.inbox == []
    end

    test "reading inbox updates last_activity timestamp", %{conn: conn} do
      agent_id = register_agent(conn)

      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      state_before = AgentServer.get_state(via)
      initial_activity = state_before.last_activity

      # Small delay to ensure measurable time difference
      Process.sleep(10)

      # Read inbox via HTTP
      get(build_conn(), ~p"/inbox/#{agent_id}")

      state_after = AgentServer.get_state(via)
      assert DateTime.compare(state_after.last_activity, initial_activity) == :gt
    end
  end
end
