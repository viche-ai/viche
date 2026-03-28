defmodule VicheWeb.RegistryControllerTest do
  use VicheWeb.ConnCase, async: false

  describe "POST /registry/register" do
    test "registers agent with all fields and returns 201", %{conn: conn} do
      params = %{
        "name" => "claude-code",
        "capabilities" => ["coding"],
        "description" => "AI coding assistant"
      }

      conn = post(conn, ~p"/registry/register", params)

      assert %{
               "id" => id,
               "name" => "claude-code",
               "capabilities" => ["coding"],
               "description" => "AI coding assistant",
               "inbox_url" => inbox_url,
               "registered_at" => registered_at
             } = json_response(conn, 201)

      assert String.length(id) == 8
      assert inbox_url == "/inbox/#{id}"
      assert is_binary(registered_at)
    end

    test "registers agent without optional fields and returns 201", %{conn: conn} do
      params = %{"capabilities" => ["testing"]}

      conn = post(conn, ~p"/registry/register", params)

      assert %{
               "id" => id,
               "name" => nil,
               "capabilities" => ["testing"],
               "description" => nil,
               "inbox_url" => _inbox_url,
               "registered_at" => _registered_at
             } = json_response(conn, 201)

      assert String.length(id) == 8
    end

    test "returns 422 when capabilities is missing", %{conn: conn} do
      params = %{"name" => "bad-agent"}

      conn = post(conn, ~p"/registry/register", params)

      assert %{"error" => "capabilities_required"} = json_response(conn, 422)
    end

    test "returns 422 when capabilities is empty list", %{conn: conn} do
      params = %{"name" => "bad-agent", "capabilities" => []}

      conn = post(conn, ~p"/registry/register", params)

      assert %{"error" => "capabilities_required"} = json_response(conn, 422)
    end

    test "registered agent is findable in registry", %{conn: conn} do
      params = %{"capabilities" => ["lookup-test"]}

      conn = post(conn, ~p"/registry/register", params)
      %{"id" => agent_id} = json_response(conn, 201)

      assert [{_pid, _meta}] = Registry.lookup(Viche.AgentRegistry, agent_id)
    end

    test "each registration produces a unique ID", %{conn: conn} do
      params = %{"capabilities" => ["uniqueness"]}

      conn1 = post(conn, ~p"/registry/register", params)
      conn2 = post(build_conn(), ~p"/registry/register", params)

      %{"id" => id1} = json_response(conn1, 201)
      %{"id" => id2} = json_response(conn2, 201)

      assert id1 != id2
    end
  end
end
