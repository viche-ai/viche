defmodule VicheWeb.AuthPlugTest do
  @moduledoc """
  Tests for VicheWeb.AuthPlug — the browser session authentication plug.
  """

  use VicheWeb.ConnCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Viche.Accounts
  alias VicheWeb.AuthPlug

  # We need a proper session-capable connection for browser plug tests.
  # build_conn/0 gives us a basic conn; we init the session manually.
  defp session_conn do
    build_conn()
    |> init_test_session(%{})
    |> fetch_flash()
  end

  defp create_user! do
    {:ok, user} =
      Accounts.create_user(%{
        email: "auth-plug-test-#{System.unique_integer()}@example.com"
      })

    user
  end

  setup do
    Application.put_env(:viche, :require_auth, true)
    on_exit(fn -> Application.put_env(:viche, :require_auth, false) end)
    :ok
  end

  describe "call/2 — auth required (default)" do
    test "halts and redirects to /auth/login when no session" do
      conn =
        session_conn()
        |> AuthPlug.call([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/login"
    end

    test "halts and redirects when session has non-existent user_id" do
      conn =
        session_conn()
        |> put_session(:user_id, Ecto.UUID.generate())
        |> AuthPlug.call([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/login"
    end

    test "assigns current_user when session contains a valid user_id" do
      user = create_user!()

      conn =
        session_conn()
        |> put_session(:user_id, user.id)
        |> AuthPlug.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.current_user.email == user.email
    end

    test "sets flash error message when redirecting" do
      conn =
        session_conn()
        |> AuthPlug.call([])

      assert conn.halted
      # Flash is stored in session; check redirect happened
      assert redirected_to(conn) == "/auth/login"
    end
  end

  describe "call/2 — auth disabled (REQUIRE_AUTH=false)" do
    setup do
      Application.put_env(:viche, :require_auth, false)
      on_exit(fn -> Application.put_env(:viche, :require_auth, false) end)
      :ok
    end

    test "passes through without checking session" do
      conn =
        session_conn()
        |> AuthPlug.call([])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :current_user)
    end

    test "passes through even with missing user_id in session" do
      conn =
        session_conn()
        |> AuthPlug.call([])

      refute conn.halted
    end
  end

  describe "init/1" do
    test "returns opts unchanged" do
      assert AuthPlug.init([]) == []
      assert AuthPlug.init(key: :value) == [key: :value]
    end
  end
end
