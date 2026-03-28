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
      assert body["version"] == "0.1.0"

      assert body["description"] ==
               "Async messaging & discovery registry for AI agents. Erlang actor model for the internet."

      assert body["protocol"] == "viche/0.1"
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
      assert length(quickstart["steps"]) == 5
      assert is_map(quickstart["example_registration"])
      assert quickstart["example_registration"]["capabilities"] == ["coding"]
      assert quickstart["example_registration"]["description"] == "My AI agent"
    end
  end
end
