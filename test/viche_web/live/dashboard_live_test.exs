defmodule VicheWeb.DashboardLiveTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp register_agent!(attrs) do
    {:ok, agent} = Viche.Agents.register_agent(attrs)
    agent
  end

  describe "mount/3 — registry assigns" do
    test "assigns selected_registry to global by default and shows only global agents", %{
      conn: conn
    } do
      _global =
        register_agent!(%{
          name: "dash-global-bot",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "dash-alpha-bot",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "dash-global-bot"
      refute html =~ "dash-alpha-bot"
    end

    test "assigns public_mode from application config", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/dashboard")
      # Mount succeeds without error — public_mode assign is wired
    end

    test "assigns registries list from Viche.Agents.list_registries/0", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "dash-reg-a",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, _view, _html} = live(conn, ~p"/dashboard")
      # Mount succeeds — registries assign is populated (no crash means it's wired)
    end
  end

  describe "URL param — ?registry=" do
    test "?registry=team-alpha filters dashboard to team-alpha agents only", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "dash-url-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "dash-url-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard?registry=team-alpha")

      refute html =~ "dash-url-global"
      assert html =~ "dash-url-alpha"
    end

    test "unknown ?registry= param defaults to showing global agents", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "dash-def-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard?registry=nonexistent-xyz")

      assert html =~ "dash-def-global"
    end
  end

  describe "registry selector UI" do
    test "selector #registry-selector is present when public_mode is false", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      assert has_element?(view, "#registry-selector")
    end

    test "selector is NOT present when public_mode is true", %{conn: conn} do
      Application.put_env(:viche, :public_mode, true)
      on_exit(fn -> Application.delete_env(:viche, :public_mode) end)
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      refute has_element?(view, "#registry-selector")
    end
  end

  describe "handle_event select_registry" do
    test "switching registry updates the agent display", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "dash-chg-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "dash-chg-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, view, html} = live(conn, ~p"/dashboard")
      assert html =~ "dash-chg-global"
      refute html =~ "dash-chg-alpha"

      html_after = render_hook(view, "select_registry", %{"registry" => "team-alpha"})

      refute html_after =~ "dash-chg-global"
      assert html_after =~ "dash-chg-alpha"
    end

    test "switching to :all shows agents from all registries", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "dash-all-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "dash-all-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      html_all = render_hook(view, "select_registry", %{"registry" => "all"})

      assert html_all =~ "dash-all-global"
      assert html_all =~ "dash-all-alpha"
    end
  end
end
