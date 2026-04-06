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

      uuid_v4 = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      assert Regex.match?(uuid_v4, id)
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

      uuid_v4 = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      assert Regex.match?(uuid_v4, id)
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

    test "accepts valid polling_timeout_ms and returns it in response", %{conn: conn} do
      params = %{"capabilities" => ["test"], "polling_timeout_ms" => 120_000}

      conn = post(conn, ~p"/registry/register", params)

      assert %{
               "polling_timeout_ms" => 120_000
             } = json_response(conn, 201)
    end

    test "defaults polling_timeout_ms to 60_000 when not provided", %{conn: conn} do
      params = %{"capabilities" => ["test"]}

      conn = post(conn, ~p"/registry/register", params)

      assert %{
               "polling_timeout_ms" => 60_000
             } = json_response(conn, 201)
    end

    test "returns 422 when polling_timeout_ms is below minimum (5000)", %{conn: conn} do
      params = %{"capabilities" => ["test"], "polling_timeout_ms" => 1_000}

      conn = post(conn, ~p"/registry/register", params)

      assert %{"error" => "invalid_polling_timeout"} = json_response(conn, 422)
    end

    test "returns 422 when polling_timeout_ms is not an integer", %{conn: conn} do
      params = %{"capabilities" => ["test"], "polling_timeout_ms" => "fast"}

      conn = post(conn, ~p"/registry/register", params)

      assert %{"error" => "invalid_polling_timeout"} = json_response(conn, 422)
    end

    test "accepts polling_timeout_ms exactly at minimum (5000)", %{conn: conn} do
      params = %{"capabilities" => ["test"], "polling_timeout_ms" => 5_000}

      conn = post(conn, ~p"/registry/register", params)

      assert %{"polling_timeout_ms" => 5_000} = json_response(conn, 201)
    end

    test "registration without registries returns registries: [\"global\"] in response",
         %{conn: conn} do
      params = %{"capabilities" => ["test"], "name" => "no-registry-agent"}

      conn = post(conn, ~p"/registry/register", params)

      assert %{"registries" => ["global"]} = json_response(conn, 201)
    end

    test "registration with registries returns them in response", %{conn: conn} do
      params = %{
        "capabilities" => ["coding"],
        "name" => "team-agent",
        "registries" => ["my-team-token"]
      }

      conn = post(conn, ~p"/registry/register", params)

      assert %{
               "registries" => ["my-team-token"]
             } = json_response(conn, 201)
    end

    test "registration with multiple registries returns all in response", %{conn: conn} do
      params = %{
        "capabilities" => ["coding"],
        "registries" => ["global", "team-secret"]
      }

      conn = post(conn, ~p"/registry/register", params)

      assert %{"registries" => ["global", "team-secret"]} = json_response(conn, 201)
    end

    test "returns 422 for invalid registry token", %{conn: conn} do
      params = %{
        "capabilities" => ["coding"],
        "registries" => ["bad token!"]
      }

      conn = post(conn, ~p"/registry/register", params)

      assert %{"error" => "invalid_registry_token"} = json_response(conn, 422)
    end
  end

  describe "GET /registry/discover" do
    setup do
      # Terminate all existing agents to ensure test isolation
      Viche.AgentSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
      end)

      :ok
    end

    setup %{conn: conn} do
      # Register two agents to use in discovery tests
      conn_a =
        post(conn, ~p"/registry/register", %{
          "name" => "agent-a",
          "capabilities" => ["testing", "coding"],
          "description" => "Agent A"
        })

      conn_b =
        post(build_conn(), ~p"/registry/register", %{
          "name" => "agent-b",
          "capabilities" => ["coding"],
          "description" => "Agent B"
        })

      %{"id" => id_a} = json_response(conn_a, 201)
      %{"id" => id_b} = json_response(conn_b, 201)

      %{id_a: id_a, id_b: id_b}
    end

    test "returns 400 when no query params provided", %{conn: conn} do
      conn = get(conn, ~p"/registry/discover")

      assert %{
               "error" => "query_required",
               "message" => "Provide ?capability= or ?name= parameter"
             } = json_response(conn, 400)
    end

    test "discovers agents by capability - single match", %{conn: conn, id_b: id_b} do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "testing"})

      assert %{"agents" => agents} = json_response(conn, 200)
      assert length(agents) == 1
      [agent] = agents
      assert agent["name"] == "agent-a"
      assert "testing" in agent["capabilities"]
      assert Map.has_key?(agent, "id")
      assert Map.has_key?(agent, "description")
      refute Map.has_key?(agent, "inbox")
      _ = id_b
    end

    test "discovers agents by capability - multiple matches", %{
      conn: conn,
      id_a: id_a,
      id_b: id_b
    } do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "coding"})

      assert %{"agents" => agents} = json_response(conn, 200)
      ids = Enum.map(agents, & &1["id"])
      assert id_a in ids
      assert id_b in ids
      assert length(agents) == 2
    end

    test "returns 200 with empty list when capability has no matches", %{conn: conn} do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "nonexistent"})

      assert %{"agents" => []} = json_response(conn, 200)
    end

    test "discovers agents by name - exact match", %{conn: conn, id_a: id_a} do
      conn = get(conn, ~p"/registry/discover", %{"name" => "agent-a"})

      assert %{"agents" => agents} = json_response(conn, 200)
      assert length(agents) == 1
      [agent] = agents
      assert agent["id"] == id_a
      assert agent["name"] == "agent-a"
    end

    test "returns 200 with empty list when name has no matches", %{conn: conn} do
      conn = get(conn, ~p"/registry/discover", %{"name" => "nonexistent-agent"})

      assert %{"agents" => []} = json_response(conn, 200)
    end

    test "does not expose inbox contents in response", %{conn: conn} do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "coding"})

      assert %{"agents" => agents} = json_response(conn, 200)

      for agent <- agents do
        refute Map.has_key?(agent, "inbox")
        refute Map.has_key?(agent, "registered_at")
      end
    end

    test "wildcard capability '*' returns all registered agents", %{
      conn: conn,
      id_a: id_a,
      id_b: id_b
    } do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "*"})

      assert %{"agents" => agents} = json_response(conn, 200)
      ids = Enum.map(agents, & &1["id"])
      assert id_a in ids
      assert id_b in ids
      assert length(agents) == 2
    end

    test "wildcard name '*' returns all registered agents", %{
      conn: conn,
      id_a: id_a,
      id_b: id_b
    } do
      conn = get(conn, ~p"/registry/discover", %{"name" => "*"})

      assert %{"agents" => agents} = json_response(conn, 200)
      ids = Enum.map(agents, & &1["id"])
      assert id_a in ids
      assert id_b in ids
      assert length(agents) == 2
    end

    test "wildcard returns 200 with empty list when no agents registered", %{conn: conn} do
      # Clear all agents first
      Viche.AgentSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
      end)

      conn = get(conn, ~p"/registry/discover", %{"capability" => "*"})

      assert %{"agents" => []} = json_response(conn, 200)
    end
  end

  describe "GET /registry/discover scoped by token" do
    setup do
      Viche.AgentSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
      end)

      # agent in team-x only
      conn_a =
        post(build_conn(), ~p"/registry/register", %{
          "name" => "team-agent",
          "capabilities" => ["coding"],
          "registries" => ["team-x"]
        })

      # agent in global only
      conn_b =
        post(build_conn(), ~p"/registry/register", %{
          "name" => "global-agent",
          "capabilities" => ["coding"],
          "registries" => ["global"]
        })

      # agent in both
      conn_c =
        post(build_conn(), ~p"/registry/register", %{
          "name" => "both-agent",
          "capabilities" => ["coding"],
          "registries" => ["global", "team-x"]
        })

      %{"id" => id_a} = json_response(conn_a, 201)
      %{"id" => id_b} = json_response(conn_b, 201)
      %{"id" => id_c} = json_response(conn_c, 201)

      %{id_a: id_a, id_b: id_b, id_c: id_c}
    end

    test "discover with token=team-x returns only team-x agents", %{
      conn: conn,
      id_a: id_a,
      id_b: id_b,
      id_c: id_c
    } do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "coding", "token" => "team-x"})

      assert %{"agents" => agents} = json_response(conn, 200)
      ids = Enum.map(agents, & &1["id"])
      assert id_a in ids
      assert id_c in ids
      refute id_b in ids
      assert length(agents) == 2
    end

    test "discover without token returns global agents only", %{
      conn: conn,
      id_a: id_a,
      id_b: id_b,
      id_c: id_c
    } do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "coding"})

      assert %{"agents" => agents} = json_response(conn, 200)
      ids = Enum.map(agents, & &1["id"])
      assert id_b in ids
      assert id_c in ids
      refute id_a in ids
      assert length(agents) == 2
    end

    test "discover with token for empty registry returns empty list", %{conn: conn} do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "*", "token" => "team-z"})

      assert %{"agents" => []} = json_response(conn, 200)
    end

    test "wildcard with token=team-x returns all agents in team-x", %{
      conn: conn,
      id_a: id_a,
      id_c: id_c
    } do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "*", "token" => "team-x"})

      assert %{"agents" => agents} = json_response(conn, 200)
      ids = Enum.map(agents, & &1["id"])
      assert id_a in ids
      assert id_c in ids
      assert length(agents) == 2
    end

    test "response agents do not expose registries field", %{conn: conn} do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "*", "token" => "team-x"})

      assert %{"agents" => agents} = json_response(conn, 200)

      for agent <- agents do
        refute Map.has_key?(agent, "registries"),
               "discover response must not expose registries — got #{inspect(agent)}"
      end
    end

    test "returns 422 for invalid token query param", %{conn: conn} do
      conn =
        get(conn, ~p"/registry/discover", %{"capability" => "coding", "token" => "bad token!"})

      assert %{"error" => "invalid_token", "details" => _} = json_response(conn, 422)
    end

    test "returns 422 for token that is too short", %{conn: conn} do
      conn = get(conn, ~p"/registry/discover", %{"capability" => "coding", "token" => "abc"})

      assert %{"error" => "invalid_token"} = json_response(conn, 422)
    end
  end
end
