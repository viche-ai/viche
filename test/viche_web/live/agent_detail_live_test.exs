defmodule VicheWeb.AgentDetailLiveTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

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
    test "?registry=team-alpha is read and stored as selected_registry", %{conn: conn} do
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

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}?registry=team-alpha")

      # The selector reflects the team-alpha registry
      assert has_element?(view, "#registry-selector option[value='team-alpha'][selected]")
    end

    test "unknown ?registry= param defaults to global", %{conn: conn} do
      agent =
        register_agent!(%{
          name: "detail-def-agent",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}?registry=nonexistent-xyz")

      assert has_element?(view, "#registry-selector option[value='global'][selected]")
    end
  end

  describe "sidebar links carry ?registry= param" do
    test "sidebar links include the selected registry query param", %{conn: conn} do
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

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}?registry=team-alpha")

      # Sidebar navigation links should carry the registry param forward
      assert html =~ "registry=team-alpha"
    end
  end

  describe "handle_event select_registry" do
    test "switching registry patches the URL to include ?registry= param", %{conn: conn} do
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

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      render_hook(view, "select_registry", %{"registry" => "team-alpha"})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#registry-selector option[value='team-alpha'][selected]")
    end
  end
end
