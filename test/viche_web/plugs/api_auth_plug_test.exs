defmodule VicheWeb.ApiAuthPlugTest do
  @moduledoc """
  Tests for VicheWeb.ApiAuthPlug — the API authentication plug.
  """

  use VicheWeb.ConnCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Viche.Accounts
  alias Viche.Auth
  alias VicheWeb.ApiAuthPlug

  defp create_user! do
    {:ok, user} =
      Accounts.create_user(%{
        email: "api-auth-plug-test-#{System.unique_integer()}@example.com"
      })
    user
  end

  defp create_api_token!(user) do
    {:ok, raw_token, auth_token} = Auth.create_api_token(user.id)
    {raw_token, auth_token}
  end

  setup do
    Application.put_env(:viche, :require_auth, true)
    on_exit(fn -> Application.put_env(:viche, :require_auth, false) end)
    
    conn = build_conn()
    {:ok, conn: conn}
  end

  describe "call/2 — auth required" do
    test "halts and returns 401 when Authorization header is missing", %{conn: conn} do
      conn = ApiAuthPlug.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "halts and returns 401 when Authorization format is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic abcdef")
        |> ApiAuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "halts and returns 401 when token is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid-token-string")
        |> ApiAuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "assigns current_user and current_api_token when token is valid", %{conn: conn} do
      user = create_user!()
      {raw_token, auth_token} = create_api_token!(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> ApiAuthPlug.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.current_api_token.id == auth_token.id
    end
  end

  describe "call/2 — auth disabled (REQUIRE_AUTH=false)" do
    setup do
      Application.put_env(:viche, :require_auth, false)
      on_exit(fn -> Application.put_env(:viche, :require_auth, false) end)
      :ok
    end

    test "passes through without checking authorization", %{conn: conn} do
      conn = ApiAuthPlug.call(conn, [])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :current_api_token)
    end
  end

  describe "init/1" do
    test "returns opts unchanged" do
      assert ApiAuthPlug.init([]) == []
      assert ApiAuthPlug.init(key: :value) == [key: :value]
    end
  end
end
