defmodule VicheWeb.NetworkLiveTest do
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
          name: "net-global-bot",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "net-alpha-bot",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, _view, html} = live(conn, ~p"/network")

      assert html =~ "net-global-bot"
      refute html =~ "net-alpha-bot"
    end

    test "assigns public_mode and registries on mount", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/network")
      # Mount succeeds without error — all assigns wired
    end
  end

  describe "URL param — ?registry=" do
    test "?registry=team-alpha filters network view to team-alpha agents only", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "net-url-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "net-url-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, _view, html} = live(conn, ~p"/network?registry=team-alpha")

      refute html =~ "net-url-global"
      assert html =~ "net-url-alpha"
    end

    test "unknown ?registry= param defaults to global agents", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "net-def-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, _view, html} = live(conn, ~p"/network?registry=nonexistent-xyz")

      assert html =~ "net-def-global"
    end
  end

  describe "registry selector UI" do
    test "selector #registry-selector is present when public_mode is false", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/network")
      assert has_element?(view, "#registry-selector")
    end

    test "selector is NOT present when public_mode is true", %{conn: conn} do
      Application.put_env(:viche, :public_mode, true)
      on_exit(fn -> Application.delete_env(:viche, :public_mode) end)
      {:ok, view, _html} = live(conn, ~p"/network")
      refute has_element?(view, "#registry-selector")
    end
  end

  describe "handle_event select_registry" do
    test "switching registry updates the agent roster display", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "net-chg-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "net-chg-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, view, html} = live(conn, ~p"/network")
      assert html =~ "net-chg-global"
      refute html =~ "net-chg-alpha"

      html_after = render_hook(view, "select_registry", %{"registry" => "team-alpha"})

      refute html_after =~ "net-chg-global"
      assert html_after =~ "net-chg-alpha"
    end

    test "switching to :all shows agents from all registries in the roster", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "net-all-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      _alpha =
        register_agent!(%{
          name: "net-all-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, view, _html} = live(conn, ~p"/network")

      html_all = render_hook(view, "select_registry", %{"registry" => "all"})

      assert html_all =~ "net-all-global"
      assert html_all =~ "net-all-alpha"
    end

    test "registry filter new_agent broadcast re-subscribes and refreshes roster", %{conn: conn} do
      _global =
        register_agent!(%{
          name: "net-pubsub-g",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} = live(conn, ~p"/network")

      # Switch to team-alpha
      render_hook(view, "select_registry", %{"registry" => "team-alpha"})

      # Register a new agent in team-alpha — broadcasts agent_joined
      {:ok, _new_agent} =
        Viche.Agents.register_agent(%{
          name: "net-new-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      # Allow the broadcast to propagate
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "net-new-alpha"
    end
  end
end
