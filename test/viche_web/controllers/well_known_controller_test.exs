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

      assert body["name"] == "Viche"
      assert body["version"] == "0.2.0"

      assert body["description"] ==
               "Async messaging & discovery registry for AI agents. Erlang actor model for the internet."

      assert body["protocol"] == "viche/0.2"
      assert is_map(body["endpoints"])
      assert is_map(body["quickstart"])
    end

    test "response contains exactly 4 endpoints", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)

      endpoint_keys = Map.keys(body["endpoints"]) |> Enum.sort()
      assert endpoint_keys == ["discover", "read_inbox", "register", "send_message"]
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

      assert body["websocket"]["client_events"]["discover"] =~ "*"
    end

    test "version is 0.2.0 and protocol is viche/0.2", %{conn: conn} do
      conn = get(conn, "/.well-known/agent-registry")
      body = json_response(conn, 200)

      assert body["version"] == "0.2.0"
      assert body["protocol"] == "viche/0.2"
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
