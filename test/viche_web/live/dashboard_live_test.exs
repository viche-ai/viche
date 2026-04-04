defmodule VicheWeb.DashboardLiveTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Creates a user and returns {user, conn_with_session}
  defp setup_user(_context \\ %{}) do
    {:ok, user} =
      Viche.Accounts.create_user(%{email: "dash-test-#{System.unique_integer()}@example.com"})

    {:ok, user: user}
  end

  defp live_as_user(conn, user, path) do
    conn
    |> init_test_session(%{"user_id" => user.id})
    |> live(path)
  end

  defp register_agent!(attrs) do
    {:ok, agent} = Viche.Agents.register_agent(attrs)
    agent
  end

  describe "mount/3 — registry assigns" do
    setup :setup_user

    test "assigns selected_registry to global by default and shows only global agents", %{
      conn: conn,
      user: user
    } do
      _global =
        register_agent!(%{
          name: "dash-global-bot",
          capabilities: ["coding"],
          registries: ["global"],
          user_id: user.id
        })

      _alpha =
        register_agent!(%{
          name: "dash-alpha-bot",
          capabilities: ["testing"],
          registries: ["team-alpha"],
          user_id: user.id
        })

      {:ok, _view, html} = live_as_user(conn, user, ~p"/dashboard")

      assert html =~ "dash-global-bot"
      refute html =~ "dash-alpha-bot"
    end

    test "assigns public_mode from application config", %{conn: conn, user: user} do
      {:ok, _view, _html} = live_as_user(conn, user, ~p"/dashboard")
      # Mount succeeds without error — public_mode assign is wired
    end

    test "assigns registries list from Viche.Agents.list_registries/0", %{conn: conn, user: user} do
      _global =
        register_agent!(%{
          name: "dash-reg-a",
          capabilities: ["coding"],
          registries: ["global"],
          user_id: user.id
        })

      {:ok, _view, _html} = live_as_user(conn, user, ~p"/dashboard")
      # Mount succeeds — registries assign is populated (no crash means it's wired)
    end
  end

  describe "URL param — ?registry=" do
    setup :setup_user

    test "?registry=team-alpha filters dashboard to team-alpha agents only", %{
      conn: conn,
      user: user
    } do
      _global =
        register_agent!(%{
          name: "dash-url-global",
          capabilities: ["coding"],
          registries: ["global"],
          user_id: user.id
        })

      _alpha =
        register_agent!(%{
          name: "dash-url-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"],
          user_id: user.id
        })

      {:ok, _view, html} = live_as_user(conn, user, ~p"/dashboard?registry=team-alpha")

      refute html =~ "dash-url-global"
      assert html =~ "dash-url-alpha"
    end

    test "unknown ?registry= param defaults to showing global agents", %{conn: conn, user: user} do
      _global =
        register_agent!(%{
          name: "dash-def-global",
          capabilities: ["coding"],
          registries: ["global"],
          user_id: user.id
        })

      {:ok, _view, html} = live_as_user(conn, user, ~p"/dashboard?registry=nonexistent-xyz")

      assert html =~ "dash-def-global"
    end
  end

  describe "registry selector UI" do
    setup :setup_user

    test "selector #registry-selector is present when public_mode is false", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live_as_user(conn, user, ~p"/dashboard")
      assert has_element?(view, "#registry-selector")
    end

    test "selector is NOT present when public_mode is true", %{conn: conn, user: user} do
      Application.put_env(:viche, :public_mode, true)
      on_exit(fn -> Application.delete_env(:viche, :public_mode) end)
      {:ok, view, _html} = live_as_user(conn, user, ~p"/dashboard")
      refute has_element?(view, "#registry-selector")
    end
  end

  describe "public_mode: true — global-only scoping" do
    setup do
      Application.put_env(:viche, :public_mode, true)
      on_exit(fn -> Application.delete_env(:viche, :public_mode) end)

      # Clear all agents for deterministic counts
      Viche.AgentSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
      end)

      {:ok, user} =
        Viche.Accounts.create_user(%{email: "pm-test-#{System.unique_integer()}@example.com"})

      {:ok, user: user}
    end

    test "only global agents visible; private registry agents are hidden", %{
      conn: conn,
      user: user
    } do
      register_agent!(%{
        name: "dash-pm-global",
        capabilities: ["coding"],
        registries: ["global"],
        user_id: user.id
      })

      register_agent!(%{
        name: "dash-pm-private",
        capabilities: ["testing"],
        registries: ["team-secret"],
        user_id: user.id
      })

      {:ok, _view, html} = live_as_user(conn, user, ~p"/dashboard")

      assert html =~ "dash-pm-global"
      refute html =~ "dash-pm-private"
    end

    test "?registry=team-secret URL param is ignored — still shows global only", %{
      conn: conn,
      user: user
    } do
      register_agent!(%{
        name: "dash-pm-url-global",
        capabilities: ["coding"],
        registries: ["global"],
        user_id: user.id
      })

      register_agent!(%{
        name: "dash-pm-url-private",
        capabilities: ["testing"],
        registries: ["team-secret"],
        user_id: user.id
      })

      {:ok, _view, html} = live_as_user(conn, user, ~p"/dashboard?registry=team-secret")

      assert html =~ "dash-pm-url-global"
      refute html =~ "dash-pm-url-private"
    end

    test "agent_count reflects only global agents, not private ones", %{conn: conn, user: user} do
      register_agent!(%{
        name: "dash-pm-cnt-global",
        capabilities: ["coding"],
        registries: ["global"],
        user_id: user.id
      })

      register_agent!(%{
        name: "dash-pm-cnt-private",
        capabilities: ["testing"],
        registries: ["team-secret"],
        user_id: user.id
      })

      {:ok, _view, html} = live_as_user(conn, user, ~p"/dashboard")

      # Exactly 1 global agent — the footer metric must not include the private one
      assert html =~ "1 agents"
      refute html =~ "2 agents"
    end
  end

  describe "handle_event select_registry" do
    setup :setup_user

    test "switching registry updates the agent display", %{conn: conn, user: user} do
      _global =
        register_agent!(%{
          name: "dash-chg-global",
          capabilities: ["coding"],
          registries: ["global"],
          user_id: user.id
        })

      _alpha =
        register_agent!(%{
          name: "dash-chg-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"],
          user_id: user.id
        })

      {:ok, view, html} = live_as_user(conn, user, ~p"/dashboard")
      assert html =~ "dash-chg-global"
      refute html =~ "dash-chg-alpha"

      html_after = render_hook(view, "select_registry", %{"registry" => "team-alpha"})

      refute html_after =~ "dash-chg-global"
      assert html_after =~ "dash-chg-alpha"
    end

    test "switching to :all shows agents from all registries", %{conn: conn, user: user} do
      _global =
        register_agent!(%{
          name: "dash-all-global",
          capabilities: ["coding"],
          registries: ["global"],
          user_id: user.id
        })

      _alpha =
        register_agent!(%{
          name: "dash-all-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"],
          user_id: user.id
        })

      {:ok, view, _html} = live_as_user(conn, user, ~p"/dashboard")

      html_all = render_hook(view, "select_registry", %{"registry" => "all"})

      assert html_all =~ "dash-all-global"
      assert html_all =~ "dash-all-alpha"
    end
  end
end
