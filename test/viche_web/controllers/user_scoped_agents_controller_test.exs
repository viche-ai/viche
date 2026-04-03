defmodule VicheWeb.UserScopedAgentsControllerTest do
  @moduledoc """
  Tests for user-scoped agent ownership — HTTP controller layer (Issue #20).

  Covers:
  - Inbox read denied for non-owner when authenticated
  - Deregister denied for non-owner when authenticated
  - Owned-agent inbox and deregister succeed for the owner
  """

  use VicheWeb.ConnCase, async: false

  alias Viche.{Accounts, Agents, Auth}

  defp create_user_with_token(email \\ nil) do
    email = email || "ctrl-user-#{System.unique_integer()}@example.com"
    {:ok, user} = Accounts.create_user(%{email: email})
    {:ok, token_string, _auth_token} = Auth.create_api_token(user.id)
    {user, token_string}
  end

  defp authed_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp register_agent!(attrs) do
    {:ok, agent} = Agents.register_agent(attrs)
    agent
  end

  describe "GET /inbox/:agent_id — inbox scoping" do
    test "owner can read their agent's inbox", %{conn: conn} do
      {user, token} = create_user_with_token()
      agent = register_agent!(%{capabilities: ["c"], user_id: user.id})

      conn = authed_conn(conn, token) |> get(~p"/inbox/#{agent.id}")
      assert json_response(conn, 200)
    end

    test "non-owner authenticated user is denied (403)", %{conn: conn} do
      {user1, _} = create_user_with_token()
      {_user2, token2} = create_user_with_token()

      agent = register_agent!(%{capabilities: ["c"], user_id: user1.id})

      conn = authed_conn(conn, token2) |> get(~p"/inbox/#{agent.id}")
      assert json_response(conn, 403)["error"] == "not_owner"
    end

    test "unauthenticated user can read unclaimed agent inbox", %{conn: conn} do
      agent = register_agent!(%{capabilities: ["c"]})

      conn = get(conn, ~p"/inbox/#{agent.id}")
      assert json_response(conn, 200)
    end

    test "unauthenticated user reading owned agent inbox is allowed (no REQUIRE_AUTH)", %{
      conn: conn
    } do
      {user, _} = create_user_with_token()
      agent = register_agent!(%{capabilities: ["c"], user_id: user.id})

      # Without auth, current_user_id is nil — user_owns_agent?(nil, _) returns false
      # But without REQUIRE_AUTH, the scoping only applies when authenticated
      conn = get(conn, ~p"/inbox/#{agent.id}")
      # Should return 200 (no REQUIRE_AUTH env set)
      assert json_response(conn, 200)
    end
  end

  describe "DELETE /registry/deregister/:agent_id — deregister scoping" do
    test "owner can deregister their agent", %{conn: conn} do
      {user, token} = create_user_with_token()
      agent = register_agent!(%{capabilities: ["c"], user_id: user.id})

      conn = authed_conn(conn, token) |> delete(~p"/registry/deregister/#{agent.id}")
      assert json_response(conn, 200)["deregistered"] == true
    end

    test "non-owner authenticated user is denied (403)", %{conn: conn} do
      {user1, _} = create_user_with_token()
      {_user2, token2} = create_user_with_token()

      agent = register_agent!(%{capabilities: ["c"], user_id: user1.id})

      conn = authed_conn(conn, token2) |> delete(~p"/registry/deregister/#{agent.id}")
      assert json_response(conn, 403)["error"] == "not_owner"
    end

    test "unauthenticated user can deregister unclaimed agent", %{conn: conn} do
      agent = register_agent!(%{capabilities: ["c"]})

      conn = delete(conn, ~p"/registry/deregister/#{agent.id}")
      assert json_response(conn, 200)["deregistered"] == true
    end
  end
end
