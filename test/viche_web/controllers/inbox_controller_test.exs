defmodule VicheWeb.InboxControllerTest do
  use VicheWeb.ConnCase, async: false

  alias Viche.AgentServer

  defp register_agent(conn, capabilities) do
    conn = post(conn, ~p"/registry/register", %{"capabilities" => capabilities})
    %{"id" => id} = json_response(conn, 201)
    id
  end

  defp register_agent(conn), do: register_agent(conn, ["coding"])

  defp send_message(agent_id, opts) do
    type = Keyword.get(opts, :type, "task")
    from = Keyword.get(opts, :from, "sender-123")
    body = Keyword.get(opts, :body, "hello")

    post(build_conn(), ~p"/messages/#{agent_id}", %{
      "type" => type,
      "from" => from,
      "body" => body
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

      assert String.starts_with?(msg["id"], "msg-")
      assert msg["type"] == "task"
      assert msg["from"] == "sender-abc"
      assert msg["body"] == "do the thing"
      # Verify ISO 8601 format
      assert {:ok, _, _} = DateTime.from_iso8601(msg["sent_at"])
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

      assert %{"error" => "agent_not_found"} = json_response(conn, 404)
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
  end
end
