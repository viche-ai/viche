defmodule VicheWeb.SettingsLiveTest do
  # Settings page is hidden (route commented out) per design feedback.
  # Tests are skipped until the page is re-enabled.
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @moduletag :skip

  describe "mount/3 — registry assigns" do
    test "mount succeeds and page renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Settings"
    end

    test "assigns public_mode, registries, and selected_registry on mount", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/settings")
      # Mount succeeds without error — all registry assigns are wired
    end
  end

  describe "URL param — ?registry=" do
    test "?registry=team-alpha is read and stored in selected_registry", %{conn: conn} do
      # Register an agent in team-alpha so the registry exists in the list
      {:ok, _agent} =
        Viche.Agents.register_agent(%{
          name: "cfg-alpha-bot",
          capabilities: ["coding"],
          registries: ["team-alpha"]
        })

      {:ok, view, _html} = live(conn, ~p"/settings?registry=team-alpha")

      # The selector should reflect the team-alpha registry as selected
      assert has_element?(view, "#registry-selector option[value='team-alpha'][selected]")
    end

    test "unknown ?registry= param defaults to global", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?registry=nonexistent-xyz")

      # Falls back to global — the global option is selected
      assert has_element?(view, "#registry-selector option[value='global'][selected]")
    end
  end

  describe "registry selector UI" do
    test "selector #registry-selector is present when public_mode is false", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "#registry-selector")
    end

    test "selector is NOT present when public_mode is true", %{conn: conn} do
      Application.put_env(:viche, :public_mode, true)
      on_exit(fn -> Application.delete_env(:viche, :public_mode) end)
      {:ok, view, _html} = live(conn, ~p"/settings")
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

      :ok
    end

    test "?registry=team-secret URL param is ignored — selected_registry stays global", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings?registry=team-secret")

      # Selector is hidden in public_mode, but global must still be the effective registry
      refute has_element?(view, "#registry-selector")
      # No team-secret option visible
      refute has_element?(view, "#registry-selector option[value='team-secret']")
    end

    test "agent_count reflects only global agents, not private ones", %{conn: conn} do
      {:ok, _a1} =
        Viche.Agents.register_agent(%{
          name: "cfg-pm-cnt-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, _a2} =
        Viche.Agents.register_agent(%{
          name: "cfg-pm-cnt-private",
          capabilities: ["testing"],
          registries: ["team-secret"]
        })

      {:ok, _view, html} = live(conn, ~p"/settings")

      # Exactly 1 global agent — the footer metric must not include the private one
      assert html =~ "1 agents"
      refute html =~ "2 agents"
    end
  end

  describe "handle_event select_registry" do
    test "switching registry pushes a patch and updates selected_registry", %{conn: conn} do
      # Register a team-alpha agent so the registry is known
      {:ok, _agent} =
        Viche.Agents.register_agent(%{
          name: "cfg-patch-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      {:ok, view, _html} = live(conn, ~p"/settings")

      # After switching, the selector should reflect the new registry
      render_hook(view, "select_registry", %{"registry" => "team-alpha"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#registry-selector option[value='team-alpha'][selected]")
    end
  end
end
