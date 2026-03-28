defmodule VicheWeb.WellKnownControllerTest do
  use VicheWeb.ConnCase, async: true

  describe "GET /.well-known/agent-registry" do
    test "returns 200 with application/json content-type", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")

      assert response_content_type(conn, :json)
      assert conn.status == 200
    end

    test "response contains all required top-level fields", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)

      assert body["descriptor_version"] == "1.0.0"
      assert is_map(body["protocol"])
      assert is_map(body["service"])
      assert is_map(body["endpoints"])
      assert is_map(body["transports"])
      assert is_list(body["integrations"])
      assert is_map(body["lifecycle"])
      assert is_map(body["quickstart"])
      assert is_map(body["self_hosting"])
    end

    test "protocol section is correct", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      protocol = body["protocol"]

      assert protocol["name"] == "Viche"
      assert protocol["version"] == "0.2.0"
      assert protocol["identifier"] == "viche/0.2"
    end

    test "service section is correct", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      service = body["service"]

      assert service["name"] == "Viche"
      assert is_binary(service["description"])
      assert service["production_url"] == "https://viche.ai"
      assert is_binary(service["repository_url"])
      assert service["well_known_path"] == "/.well-known/agent-registry"
    end

    test "response contains exactly 5 endpoints", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)

      endpoint_keys = Map.keys(body["endpoints"]) |> Enum.sort()

      assert endpoint_keys == [
               "agent_socket",
               "discover",
               "read_inbox",
               "register",
               "send_message"
             ]
    end

    test "register endpoint descriptor is correct", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      register = body["endpoints"]["register"]

      assert register["method"] == "POST"
      assert register["path"] == "/registry/register"
      assert is_binary(register["description"])
      assert is_map(register["request_schema"])
    end

    test "discover endpoint descriptor is correct", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      discover = body["endpoints"]["discover"]

      assert discover["method"] == "GET"
      assert discover["path"] == "/registry/discover"
      assert is_binary(discover["description"])
      assert is_map(discover["query_params"])
    end

    test "send_message endpoint descriptor is correct", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      send_msg = body["endpoints"]["send_message"]

      assert send_msg["method"] == "POST"
      assert send_msg["path"] == "/messages/{agentId}"
      assert is_binary(send_msg["description"])
      assert is_map(send_msg["request_schema"])
    end

    test "read_inbox endpoint descriptor is correct", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      read_inbox = body["endpoints"]["read_inbox"]

      assert read_inbox["method"] == "GET"
      assert read_inbox["path"] == "/inbox/{agentId}"
      assert is_binary(read_inbox["description"])
    end

    test "agent_socket endpoint descriptor is correct", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      agent_socket = body["endpoints"]["agent_socket"]

      assert agent_socket["method"] == "WS"
      assert agent_socket["path"] == "/agent/websocket"
      assert is_binary(agent_socket["description"])
    end

    test "quickstart contains steps and example_registration", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      quickstart = body["quickstart"]

      assert is_list(quickstart["steps"])
      assert length(quickstart["steps"]) == 6
      assert is_map(quickstart["example_registration"])
      assert quickstart["example_registration"]["capabilities"] == ["coding"]
      assert quickstart["example_registration"]["description"] == "My AI agent"
      assert quickstart["example_registration"]["polling_timeout_ms"] == 60_000
    end

    test "discover endpoint descriptors mention wildcard '*'", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)

      discover = body["endpoints"]["discover"]
      assert discover["description"] =~ "*"
      assert discover["query_params"]["capability"]["description"] =~ "*"
      assert discover["query_params"]["name"]["description"] =~ "*"

      assert body["transports"]["websocket"]["client_events"]["discover"] =~ "*"
    end

    test "no registry section when no token provided", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)

      refute Map.has_key?(body, "registry")
    end

    test "register request_schema includes registries field", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      register = body["endpoints"]["register"]

      assert is_map(register["request_schema"]["registries"])
      assert register["request_schema"]["registries"]["type"] == "array"
    end

    test "discover query_params includes token field", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      discover = body["endpoints"]["discover"]

      assert is_map(discover["query_params"]["token"])
      assert is_binary(discover["query_params"]["token"]["description"])
    end

    test "transports section has preferred order and both transports", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      transports = body["transports"]

      assert transports["preferred"] == ["websocket", "http_long_poll"]
      assert is_map(transports["websocket"])
      assert is_map(transports["http_long_poll"])
    end

    test "websocket transport has correct details", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      ws = body["transports"]["websocket"]

      assert ws["supports_push"] == true
      assert ws["connect_url"] == "/agent/websocket"
      assert is_map(ws["params"])
      assert is_map(ws["channel_topics"])
      assert is_map(ws["client_events"])
      assert is_map(ws["server_events"])
      assert ws["grace_period_ms"] == 5_000
    end

    test "websocket server_events includes all three events", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      server_events = body["transports"]["websocket"]["server_events"]

      assert is_binary(server_events["new_message"])
      assert is_binary(server_events["agent_joined"])
      assert is_binary(server_events["agent_left"])
    end

    test "websocket channel_topics includes agent and registry topics", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      topics = body["transports"]["websocket"]["channel_topics"]

      assert topics["agent"] == "agent:{agentId}"
      assert topics["registry"] == "registry:{token}"
    end

    test "http_long_poll transport has correct details", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      lp = body["transports"]["http_long_poll"]

      assert lp["supports_push"] == false
      assert lp["poll_url_template"] == "/inbox/{agentId}"
      assert lp["fallback_for"] == "websocket"
      assert lp["default_timeout_ms"] == 60_000
      assert lp["minimum_timeout_ms"] == 5_000
    end

    test "integrations list has 3 entries with required fields", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      integrations = body["integrations"]

      assert length(integrations) == 3

      Enum.each(integrations, fn integration ->
        assert is_binary(integration["id"])
        assert is_binary(integration["name"])
        assert is_binary(integration["kind"])
        assert is_binary(integration["homepage_url"])
        assert is_binary(integration["install_ref"])
      end)
    end

    test "integrations include openclaw, opencode, and claude_code_mcp", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      ids = Enum.map(body["integrations"], & &1["id"]) |> Enum.sort()

      assert ids == ["claude_code_mcp", "openclaw", "opencode"]
    end

    test "self_hosting section has repository_url and steps", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)
      self_hosting = body["self_hosting"]

      assert self_hosting["repository_url"] == "https://github.com/viche-ai/viche"
      assert is_list(self_hosting["steps"])
      assert self_hosting["steps"] != []
    end
  end

  describe "GET /.well-known/agent-registry?token=..." do
    test "response has registry section with token value", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry?token=my-secret")
      body = json_response(conn, 200)

      assert is_map(body["registry"])
      assert body["registry"]["token"] == "my-secret"
    end

    test "registry description explains how to use the token", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry?token=my-secret")
      body = json_response(conn, 200)

      assert is_binary(body["registry"]["description"])
      assert body["registry"]["description"] =~ "token"
    end
  end
end
