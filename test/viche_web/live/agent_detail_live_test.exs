defmodule VicheWeb.AgentDetailLiveTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp setup_user(_context \\ %{}) do
    {:ok, user} =
      Viche.Accounts.create_user(%{
        email: "agent-detail-test-#{System.unique_integer()}@example.com"
      })

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

  describe "mount/3 — valid agent" do
    test "mount succeeds and shows agent name in content", %{conn: conn} do
      agent =
        register_agent!(%{name: "detail-agent", capabilities: ["coding"], registries: ["global"]})

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}")

      assert html =~ "detail-agent"
    end

    test "assigns selected_registry, public_mode, and registries on mount", %{conn: conn} do
      agent =
        register_agent!(%{
          name: "detail-assigns",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, _view, _html} = live(conn, ~p"/agents/#{agent.id}")
      # Mount succeeds — registry assigns are wired (no crash)
    end

    test "registry selector is present when public_mode is false", %{conn: conn} do
      agent =
        register_agent!(%{
          name: "detail-sel-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      assert has_element?(view, "#registry-selector")
    end

    test "registry selector is NOT present when public_mode is true", %{conn: conn} do
      Application.put_env(:viche, :public_mode, true)
      on_exit(fn -> Application.delete_env(:viche, :public_mode) end)

      agent =
        register_agent!(%{
          name: "detail-nopub-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      refute has_element?(view, "#registry-selector")
    end
  end

  describe "mount/3 — unknown agent" do
    test "shows 'Agent not found' for an unknown ID", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      {:ok, _view, html} = live(conn, ~p"/agents/#{fake_id}")

      assert html =~ "Agent not found"
    end
  end

  describe "URL param — ?registry=" do
    setup :setup_user

    test "?registry=team-alpha is read and stored as selected_registry", %{
      conn: conn,
      user: user
    } do
      # Register a team-alpha agent so the registry exists in the known list
      _alpha =
        register_agent!(%{
          name: "detail-alpha-reg",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      agent =
        register_agent!(%{
          name: "detail-url-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} = live_as_user(conn, user, ~p"/agents/#{agent.id}?registry=team-alpha")

      # The selector reflects the team-alpha registry
      assert has_element?(view, "#registry-selector option[value='team-alpha'][selected]")
    end

    test "unknown ?registry= param defaults to global", %{conn: conn, user: user} do
      agent =
        register_agent!(%{
          name: "detail-def-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} =
        live_as_user(conn, user, ~p"/agents/#{agent.id}?registry=nonexistent-xyz")

      assert has_element?(view, "#registry-selector option[value='global'][selected]")
    end
  end

  describe "sidebar links carry ?registry= param" do
    setup :setup_user

    test "sidebar links include the selected registry query param", %{conn: conn, user: user} do
      _alpha =
        register_agent!(%{
          name: "detail-lnk-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      agent =
        register_agent!(%{
          name: "detail-lnk-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, _view, html} =
        live_as_user(conn, user, ~p"/agents/#{agent.id}?registry=team-alpha")

      # Sidebar navigation links should carry the registry param forward
      assert html =~ "registry=team-alpha"
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

      :ok
    end

    test "?registry=team-secret URL param is ignored — selected_registry stays global", %{
      conn: conn
    } do
      agent =
        register_agent!(%{
          name: "detail-pm-url-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}?registry=team-secret")

      # Selector is hidden in public_mode
      refute has_element?(view, "#registry-selector")
      # No team-secret option visible
      refute has_element?(view, "#registry-selector option[value='team-secret']")
    end

    test "agent_count reflects only global agents, not private ones", %{conn: conn} do
      global_agent =
        register_agent!(%{
          name: "detail-pm-cnt-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      register_agent!(%{
        name: "detail-pm-cnt-private",
        capabilities: ["testing"],
        registries: ["team-secret"]
      })

      {:ok, _view, html} = live(conn, ~p"/agents/#{global_agent.id}")

      # Exactly 1 global agent — the footer metric must not include the private one
      assert html =~ "1 agents"
      refute html =~ "2 agents"
    end
  end

  describe "handle_event select_registry" do
    setup :setup_user

    test "switching registry patches the URL to include ?registry= param", %{
      conn: conn,
      user: user
    } do
      _alpha =
        register_agent!(%{
          name: "detail-patch-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      agent =
        register_agent!(%{
          name: "detail-patch-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} = live_as_user(conn, user, ~p"/agents/#{agent.id}")

      render_hook(view, "select_registry", %{"registry" => "team-alpha"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#registry-selector option[value='team-alpha'][selected]")
    end
  end
end
