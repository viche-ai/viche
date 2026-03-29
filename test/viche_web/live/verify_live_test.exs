defmodule VicheWeb.VerifyLiveTest do
  use VicheWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Viche.Accounts
  alias Viche.Auth

  describe "GET /verify" do
    test "renders verifying view for a valid token", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "verify-live@example.com"})
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      {:ok, _view, html} = live(conn, ~p"/verify?token=#{raw_token}")

      assert html =~ "One sec"
      assert html =~ "Verifying magic link"
    end

    test "renders error view for an invalid token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/verify?token=bogus")

      assert html =~ "Link expired"
      assert html =~ "Back to sign in"
    end

    test "renders error view when token param is missing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/verify")

      assert html =~ "Link expired"
    end

    test "shows success view after steps complete", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "steps@example.com"})
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      {:ok, view, _html} = live(conn, ~p"/verify?token=#{raw_token}")

      # Drive steps to completion without the auto-scheduled timers
      for step <- 1..4 do
        send(view.pid, {:activate_step, step})
        send(view.pid, {:complete_step, step})
      end

      send(view.pid, :show_success)
      html = render(view)
      assert html =~ "Identity confirmed"
      assert html =~ "Open dashboard"
    end

    test "redirects to confirm after success", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "redirect@example.com"})
      {:ok, raw_token, _} = Auth.create_magic_link_token(user.id)

      {:ok, view, _html} = live(conn, ~p"/verify?token=#{raw_token}")

      send(view.pid, :redirect_to_confirm)

      assert_redirect(view, "/auth/confirm?token=#{raw_token}")
    end
  end
end
