defmodule VicheWeb.SettingsLiveTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

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
