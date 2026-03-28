defmodule VicheWeb.MessageControllerTest do
  use VicheWeb.ConnCase, async: false

  alias Viche.AgentServer

  defp register_agent(conn, capabilities \\ ["coding"]) do
    conn = post(conn, ~p"/registry/register", %{"capabilities" => capabilities})
    %{"id" => id} = json_response(conn, 201)
    id
  end

  describe "POST /messages/:agent_id" do
    test "returns 202 with message_id on success", %{conn: conn} do
      agent_id = register_agent(conn)

      conn =
        post(build_conn(), ~p"/messages/#{agent_id}", %{
          "type" => "task",
          "from" => "sender-123",
          "body" => "hello"
        })

      assert %{"message_id" => message_id} = json_response(conn, 202)
      assert String.starts_with?(message_id, "msg-")
      # "msg-" + UUID (36 chars) = 40 chars total
      assert String.length(message_id) == 40
    end

    test "message appears in agent's GenServer inbox", %{conn: conn} do
      agent_id = register_agent(conn)

      post(build_conn(), ~p"/messages/#{agent_id}", %{
        "type" => "task",
        "from" => "sender-abc",
        "body" => "do the thing"
      })

      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      state = AgentServer.get_state(via)

      assert length(state.inbox) == 1
      [msg] = state.inbox
      assert msg.type == "task"
      assert msg.from == "sender-abc"
      assert msg.body == "do the thing"
      assert String.starts_with?(msg.id, "msg-")
      assert %DateTime{} = msg.sent_at
    end

    test "returns 404 when agent not found", %{conn: conn} do
      conn =
        post(conn, ~p"/messages/nonexistent", %{
          "type" => "task",
          "from" => "sender-123",
          "body" => "hello"
        })

      assert %{"error" => "agent_not_found"} = json_response(conn, 404)
    end

    test "returns 422 when type is missing", %{conn: conn} do
      agent_id = register_agent(conn)

      conn =
        post(build_conn(), ~p"/messages/#{agent_id}", %{
          "from" => "sender-123",
          "body" => "hello"
        })

      assert %{"error" => "invalid_message", "message" => msg} = json_response(conn, 422)
      assert msg == "type, from, and body are required"
    end

    test "returns 422 when from is missing", %{conn: conn} do
      agent_id = register_agent(conn)

      conn =
        post(build_conn(), ~p"/messages/#{agent_id}", %{
          "type" => "task",
          "body" => "hello"
        })

      assert %{"error" => "invalid_message", "message" => msg} = json_response(conn, 422)
      assert msg == "type, from, and body are required"
    end

    test "returns 422 when body is missing", %{conn: conn} do
      agent_id = register_agent(conn)

      conn =
        post(build_conn(), ~p"/messages/#{agent_id}", %{
          "type" => "task",
          "from" => "sender-123"
        })

      assert %{"error" => "invalid_message", "message" => msg} = json_response(conn, 422)
      assert msg == "type, from, and body are required"
    end

    test "returns 422 when type is invalid", %{conn: conn} do
      agent_id = register_agent(conn)

      conn =
        post(build_conn(), ~p"/messages/#{agent_id}", %{
          "type" => "invalid-type",
          "from" => "sender-123",
          "body" => "hello"
        })

      assert %{"error" => "invalid_message", "message" => msg} = json_response(conn, 422)
      assert msg == "type, from, and body are required"
    end

    test "multiple messages are ordered oldest first in inbox", %{conn: conn} do
      agent_id = register_agent(conn)

      post(build_conn(), ~p"/messages/#{agent_id}", %{
        "type" => "ping",
        "from" => "agent-1",
        "body" => "first"
      })

      post(build_conn(), ~p"/messages/#{agent_id}", %{
        "type" => "task",
        "from" => "agent-2",
        "body" => "second"
      })

      post(build_conn(), ~p"/messages/#{agent_id}", %{
        "type" => "result",
        "from" => "agent-3",
        "body" => "third"
      })

      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      state = AgentServer.get_state(via)

      assert length(state.inbox) == 3
      [first, second, third] = state.inbox
      assert first.body == "first"
      assert second.body == "second"
      assert third.body == "third"
    end

    test "fake from agent ID is accepted (trusted actor model)", %{conn: conn} do
      agent_id = register_agent(conn)

      conn =
        post(build_conn(), ~p"/messages/#{agent_id}", %{
          "type" => "task",
          "from" => "fake-agent-id-does-not-exist",
          "body" => "hello"
        })

      assert %{"message_id" => _} = json_response(conn, 202)
    end

    test "all valid message types are accepted", %{conn: conn} do
      agent_id = register_agent(conn)

      for type <- ["task", "result", "ping"] do
        conn =
          post(build_conn(), ~p"/messages/#{agent_id}", %{
            "type" => type,
            "from" => "sender",
            "body" => "test"
          })

        assert %{"message_id" => _} = json_response(conn, 202)
      end
    end
  end
end
