defmodule VicheWeb.AuthControllerTest do
  use VicheWeb.ConnCase, async: true

  alias Viche.Accounts
  alias Viche.Auth

  describe "POST /auth/login" do
    test "returns 200 and sends email for valid email", %{conn: conn} do
      conn = post(conn, ~p"/auth/login", %{"email" => "login@example.com"})

      assert json_response(conn, 200)["message"] =~ "login link"
    end

    test "returns 200 even for non-existent email (no enumeration)", %{conn: conn} do
      conn = post(conn, ~p"/auth/login", %{"email" => "nobody@example.com"})

      assert json_response(conn, 200)["message"] =~ "login link"
    end

    test "returns 422 when email is missing", %{conn: conn} do
      conn = post(conn, ~p"/auth/login", %{})

      assert json_response(conn, 422)["error"] =~ "email is required"
    end
  end

  describe "GET /auth/confirm" do
    test "sets session and redirects for a valid token", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "verify@example.com"})
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      conn = get(conn, ~p"/auth/confirm", %{"token" => raw_token})

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, :user_id) == user.id
    end

    test "redirects to login for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/auth/confirm", %{"token" => "bogus"})

      assert redirected_to(conn) == ~p"/login"
    end

    test "redirects to login for already-used token", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "used@example.com"})
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      # Use the token once
      _conn1 = get(conn, ~p"/auth/confirm", %{"token" => raw_token})

      # Second attempt should redirect to login
      conn2 = get(build_conn(), ~p"/auth/confirm", %{"token" => raw_token})
      assert redirected_to(conn2) == ~p"/login"
    end

    test "redirects to login when token param is missing", %{conn: conn} do
      conn = get(conn, ~p"/auth/confirm")

      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "DELETE /auth/logout" do
    test "clears session and redirects to /", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{user_id: Ecto.UUID.generate()})
        |> delete(~p"/auth/logout")

      assert redirected_to(conn) == ~p"/"
      # Session is marked for drop (client cookie will be cleared)
      assert conn.private[:plug_session_info] == :drop
    end
  end
end
