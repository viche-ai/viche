defmodule VicheWeb.MessageControllerTest do
  use VicheWeb.ConnCase, async: false

  alias Viche.AgentServer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp register_agent(conn, capabilities \\ ["coding"]) do
    conn = post(conn, ~p"/registry/register", %{"capabilities" => capabilities})
    %{"id" => id} = json_response(conn, 201)
    id
  end

  # Build a conn with the sender's agent_id asserted via the server-side assign.
  # In tests we bypass HTTP auth by directly assigning current_agent_id on the conn.
  defp authed_conn(sender_agent_id) do
    build_conn()
    |> Plug.Conn.assign(:current_agent_id, sender_agent_id)
  end

  describe "POST /messages/:agent_id" do
    test "returns 202 with message_id when sender is authenticated via current_agent_id",
         %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_id = register_agent(build_conn(), ["sending"])

      conn =
        authed_conn(sender_id)
        |> post(~p"/messages/#{recipient_id}", %{
          "type" => "task",
          "body" => "hello"
        })

      assert %{"message_id" => message_id} = json_response(conn, 202)
      assert String.starts_with?(message_id, "msg-")
      # "msg-" + UUID (36 chars) = 40 chars total
      assert String.length(message_id) == 40
    end

    test "message 'from' is derived from current_agent_id, not from request body", %{conn: conn} do
      recipient_id = register_agent(conn)
      real_sender_id = register_agent(build_conn(), ["sending"])

      authed_conn(real_sender_id)
      |> post(~p"/messages/#{recipient_id}", %{
        "type" => "task",
        # This "from" value should be completely ignored
        "from" => "impersonated-agent-id",
        "body" => "do the thing"
      })

      via = {:via, Registry, {Viche.AgentRegistry, recipient_id}}
      state = AgentServer.get_state(via)

      assert length(state.inbox) == 1
      [msg] = state.inbox
      # Must be the server-verified sender, NOT the client-supplied impersonated ID
      assert msg.from == real_sender_id
      refute msg.from == "impersonated-agent-id"
    end

    test "message appears in agent's GenServer inbox with correct from", %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_id = register_agent(build_conn(), ["sending"])

      authed_conn(sender_id)
      |> post(~p"/messages/#{recipient_id}", %{
        "type" => "task",
        "body" => "do the thing"
      })

      via = {:via, Registry, {Viche.AgentRegistry, recipient_id}}
      state = AgentServer.get_state(via)

      assert length(state.inbox) == 1
      [msg] = state.inbox
      assert msg.type == "task"
      assert msg.from == sender_id
      assert msg.body == "do the thing"
      assert String.starts_with?(msg.id, "msg-")
      assert %DateTime{} = msg.sent_at
    end

    test "returns 422 when current_agent_id is nil (unauthenticated sender)", %{conn: conn} do
      recipient_id = register_agent(conn)

      # No current_agent_id set — simulates unauthenticated or missing X-Agent-ID
      conn =
        build_conn()
        |> Plug.Conn.assign(:current_agent_id, nil)
        |> post(~p"/messages/#{recipient_id}", %{
          "type" => "task",
          "body" => "hello"
        })

      assert %{"error" => "invalid_message"} = json_response(conn, 422)
    end

    test "returns 422 when no authentication at all (ApiAuth sets nil)", %{conn: conn} do
      recipient_id = register_agent(conn)

      # Plain build_conn() goes through ApiAuth which sets current_agent_id: nil
      conn =
        post(build_conn(), ~p"/messages/#{recipient_id}", %{
          "type" => "task",
          "body" => "hello"
        })

      assert %{"error" => "invalid_message"} = json_response(conn, 422)
    end

    test "returns 404 when recipient agent not found", %{conn: conn} do
      sender_id = register_agent(conn)

      conn =
        authed_conn(sender_id)
        |> post(~p"/messages/nonexistent", %{
          "type" => "task",
          "body" => "hello"
        })

      assert %{"error" => "agent_not_found"} = json_response(conn, 404)
    end

    test "returns 422 when type is missing", %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_id = register_agent(build_conn(), ["sending"])

      conn =
        authed_conn(sender_id)
        |> post(~p"/messages/#{recipient_id}", %{
          "body" => "hello"
        })

      assert %{"error" => "invalid_message"} = json_response(conn, 422)
    end

    test "returns 422 when body is missing", %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_id = register_agent(build_conn(), ["sending"])

      conn =
        authed_conn(sender_id)
        |> post(~p"/messages/#{recipient_id}", %{
          "type" => "task"
        })

      assert %{"error" => "invalid_message"} = json_response(conn, 422)
    end

    test "returns 422 when type is invalid", %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_id = register_agent(build_conn(), ["sending"])

      conn =
        authed_conn(sender_id)
        |> post(~p"/messages/#{recipient_id}", %{
          "type" => "invalid-type",
          "body" => "hello"
        })

      assert %{"error" => "invalid_message"} = json_response(conn, 422)
    end

    test "multiple messages are ordered oldest first in inbox", %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_id = register_agent(build_conn(), ["sending"])

      authed_conn(sender_id)
      |> post(~p"/messages/#{recipient_id}", %{"type" => "ping", "body" => "first"})

      authed_conn(sender_id)
      |> post(~p"/messages/#{recipient_id}", %{"type" => "task", "body" => "second"})

      authed_conn(sender_id)
      |> post(~p"/messages/#{recipient_id}", %{"type" => "result", "body" => "third"})

      via = {:via, Registry, {Viche.AgentRegistry, recipient_id}}
      state = AgentServer.get_state(via)

      assert length(state.inbox) == 3
      [first, second, third] = state.inbox
      assert first.body == "first"
      assert second.body == "second"
      assert third.body == "third"
    end

    test "all valid message types are accepted", %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_id = register_agent(build_conn(), ["sending"])

      for type <- ["task", "result", "ping"] do
        conn =
          authed_conn(sender_id)
          |> post(~p"/messages/#{recipient_id}", %{
            "type" => type,
            "body" => "test"
          })

        assert %{"message_id" => _} = json_response(conn, 202)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Impersonation prevention tests (issue #21)
  # ---------------------------------------------------------------------------

  describe "impersonation prevention" do
    test "client-supplied 'from' in body cannot override server-verified sender", %{conn: conn} do
      recipient_id = register_agent(conn)
      real_sender_id = register_agent(build_conn(), ["real"])

      # The client claims to be "evil-impersonator" in the body, but the server
      # should use real_sender_id from current_agent_id.
      authed_conn(real_sender_id)
      |> post(~p"/messages/#{recipient_id}", %{
        "type" => "task",
        "from" => "evil-impersonator",
        "body" => "sneaky message"
      })

      via = {:via, Registry, {Viche.AgentRegistry, recipient_id}}
      state = AgentServer.get_state(via)

      [msg] = state.inbox
      assert msg.from == real_sender_id
      refute msg.from == "evil-impersonator"
    end

    test "request without X-Agent-ID (no current_agent_id) is rejected even with valid body",
         %{conn: conn} do
      recipient_id = register_agent(conn)

      # Attacker sends a fully-formed request with no authenticated sender identity
      conn =
        build_conn()
        |> post(~p"/messages/#{recipient_id}", %{
          "type" => "task",
          "from" => "any-agent-id",
          "body" => "impersonation attempt"
        })

      assert %{"error" => "invalid_message"} = json_response(conn, 422)

      # Recipient inbox must remain empty
      via = {:via, Registry, {Viche.AgentRegistry, recipient_id}}
      state = AgentServer.get_state(via)
      assert state.inbox == []
    end

    test "two different authenticated senders produce correct 'from' fields", %{conn: conn} do
      recipient_id = register_agent(conn)
      sender_a_id = register_agent(build_conn(), ["alpha"])
      sender_b_id = register_agent(build_conn(), ["beta"])

      authed_conn(sender_a_id)
      |> post(~p"/messages/#{recipient_id}", %{"type" => "task", "body" => "from A"})

      authed_conn(sender_b_id)
      |> post(~p"/messages/#{recipient_id}", %{"type" => "task", "body" => "from B"})

      via = {:via, Registry, {Viche.AgentRegistry, recipient_id}}
      state = AgentServer.get_state(via)

      assert length(state.inbox) == 2
      [msg_a, msg_b] = state.inbox
      assert msg_a.from == sender_a_id
      assert msg_b.from == sender_b_id
    end
  end
end
