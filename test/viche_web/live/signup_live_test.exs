defmodule VicheWeb.SignupLiveTest do
  use VicheWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "GET /signup" do
    test "renders the signup form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signup")

      assert html =~ "Create your account"
      assert html =~ "Join the agent network"
      assert html =~ "ada@example.com"
    end

    test "does not render password field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/signup")

      refute html =~ "password"
      refute html =~ "Password"
    end
  end

  describe "multi-step navigation" do
    test "advances to step 2 after valid name and email", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      view |> element("input[name=name]") |> render_change(%{"name" => "Ada Lovelace"})
      view |> element("input[name=email]") |> render_change(%{"email" => "ada@example.com"})

      html = view |> element("button", "Continue") |> render_click()

      assert html =~ "Username"
      assert html =~ "@"
    end

    test "shows error when name is empty on step 1", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      view |> element("input[name=email]") |> render_change(%{"email" => "ada@example.com"})

      html = view |> element("button", "Continue") |> render_click()

      assert html =~ "Please enter your name"
    end

    test "shows error when email is invalid on step 1", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      view |> element("input[name=name]") |> render_change(%{"name" => "Ada"})
      view |> element("input[name=email]") |> render_change(%{"email" => "not-an-email"})

      html = view |> element("button", "Continue") |> render_click()

      assert html =~ "Please enter a valid email address"
    end

    test "goes back from step 2 to step 1", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      view |> element("input[name=name]") |> render_change(%{"name" => "Ada"})
      view |> element("input[name=email]") |> render_change(%{"email" => "ada@example.com"})
      view |> element("button", "Continue") |> render_click()

      html = view |> element("button", "Back") |> render_click()

      assert html =~ "Name"
      assert html =~ "Email"
    end

    test "advances to step 3 after valid username", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      view |> element("input[name=name]") |> render_change(%{"name" => "Ada"})
      view |> element("input[name=email]") |> render_change(%{"email" => "ada@example.com"})
      view |> element("button", "Continue") |> render_click()

      view |> element("input[name=username]") |> render_change(%{"username" => "ada_lovelace"})
      html = view |> element("button", "Continue") |> render_click()

      assert html =~ "How do you plan to use Viche?"
    end

    test "shows error for invalid username", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      view |> element("input[name=name]") |> render_change(%{"name" => "Ada"})
      view |> element("input[name=email]") |> render_change(%{"email" => "ada@example.com"})
      view |> element("button", "Continue") |> render_click()

      html = view |> element("button", "Continue") |> render_click()

      assert html =~ "Username must be"
    end
  end

  describe "submit" do
    test "shows success state after completing all steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      # Step 1
      view |> element("input[name=name]") |> render_change(%{"name" => "Ada Lovelace"})
      view |> element("input[name=email]") |> render_change(%{"email" => "signup@example.com"})
      view |> element("button", "Continue") |> render_click()

      # Step 2
      view |> element("input[name=username]") |> render_change(%{"username" => "ada_signup"})
      view |> element("button", "Continue") |> render_click()

      # Step 3
      view |> element("[phx-value-value=personal]") |> render_click()
      html = view |> element("button", "Create account") |> render_click()

      assert html =~ "Check your email"
      assert html =~ "magic link"
      refute html =~ "Create your account"
    end

    test "shows error when no use case selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signup")

      # Step 1
      view |> element("input[name=name]") |> render_change(%{"name" => "Ada"})
      view |> element("input[name=email]") |> render_change(%{"email" => "ada@example.com"})
      view |> element("button", "Continue") |> render_click()

      # Step 2
      view |> element("input[name=username]") |> render_change(%{"username" => "ada_test"})
      view |> element("button", "Continue") |> render_click()

      # Step 3 - no use case selected
      html = view |> element("button", "Create account") |> render_click()

      assert html =~ "Please select how you plan to use Viche"
    end
  end
end
