defmodule VicheWeb.BroadcastControllerTest do
  use VicheWeb.ConnCase, async: false

  alias Viche.Agents

  setup do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)

    :ok
  end

  defp register_agent(conn, registries) do
    conn =
      post(conn, "/registry/register", %{
        "capabilities" => ["coding"],
        "registries" => registries
      })

    %{"id" => id} = json_response(conn, 201)
    id
  end

  defp authed_conn(sender_agent_id) do
    build_conn()
    |> Plug.Conn.assign(:current_agent_id, sender_agent_id)
  end

  describe "POST /registry/:token/broadcast" do
    test "returns 202 with recipients and message_ids on success", %{conn: conn} do
      sender_id = register_agent(conn, ["team-alpha"])
      recipient_a_id = register_agent(build_conn(), ["team-alpha"])
      recipient_b_id = register_agent(build_conn(), ["team-alpha"])

      conn =
        authed_conn(sender_id)
        |> post("/registry/team-alpha/broadcast", %{
          "type" => "task",
          "from" => "impersonated-agent-id",
          "body" => "hello team"
        })

      assert %{"recipients" => 2, "message_ids" => message_ids, "failed" => failed} =
               json_response(conn, 202)

      assert length(message_ids) == 2
      assert failed == []

      assert {:ok, []} = Agents.drain_inbox(sender_id)

      for agent_id <- [recipient_a_id, recipient_b_id] do
        assert {:ok, [message]} = Agents.drain_inbox(agent_id)
        assert message.from == sender_id
        assert message.body == "hello team"
        assert message.type == "task"
      end
    end

    test "returns 422 when sender identity is missing", %{conn: _conn} do
      conn =
        build_conn()
        |> post("/registry/team-alpha/broadcast", %{
          "type" => "task",
          "body" => "hello"
        })

      assert %{"error" => "invalid_message"} = json_response(conn, 422)
    end

    test "returns 403 when sender is not in target registry", %{conn: conn} do
      sender_id = register_agent(conn, ["global"])
      _recipient_id = register_agent(build_conn(), ["team-alpha"])

      conn =
        authed_conn(sender_id)
        |> post("/registry/team-alpha/broadcast", %{"type" => "task", "body" => "hello"})

      assert %{"error" => "not_in_registry"} = json_response(conn, 403)
    end

    test "returns 422 when body is missing", %{conn: conn} do
      sender_id = register_agent(conn, ["team-alpha"])

      conn =
        authed_conn(sender_id)
        |> post("/registry/team-alpha/broadcast", %{"type" => "task"})

      assert %{"error" => "invalid_message"} = json_response(conn, 422)
    end

    test "returns 422 for invalid registry token", %{conn: conn} do
      sender_id = register_agent(conn, ["team-alpha"])

      conn =
        authed_conn(sender_id)
        |> post("/registry/bad!/broadcast", %{"type" => "task", "body" => "hello"})

      assert %{"error" => "invalid_token"} = json_response(conn, 422)
    end
  end
end
