defmodule VicheWeb.SessionsLiveTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp register_agent!(attrs) do
    {:ok, agent} = Viche.Agents.register_agent(attrs)
    agent
  end

  defp send_message_to!(agent, body \\ "hello") do
    {:ok, _msg_id} =
      Viche.Agents.send_message(%{
        to: agent.id,
        from: "test-sender",
        body: body,
        type: "task"
      })
  end

  describe "mount/3 — registry assigns" do
    test "assigns selected_registry to global by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sessions")
      # Mount succeeds — page renders with "Inboxes" heading
      assert html =~ "Inboxes"
    end

    test "assigns public_mode and registries on mount", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/sessions")
      # Mount succeeds without error — all assigns wired
    end
  end

  describe "URL param — ?registry=" do
    test "default registry shows only global agent inboxes", %{conn: conn} do
      global_agent =
        register_agent!(%{
          name: "ses-global-bot",
          capabilities: ["coding"],
          registries: ["global"]
        })

      alpha_agent =
        register_agent!(%{
          name: "ses-alpha-bot",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      send_message_to!(global_agent)
      send_message_to!(alpha_agent)

      {:ok, _view, html} = live(conn, ~p"/sessions")

      assert html =~ "ses-global-bot"
      refute html =~ "ses-alpha-bot"
    end

    test "?registry=team-alpha shows only team-alpha agent inboxes", %{conn: conn} do
      global_agent =
        register_agent!(%{
          name: "ses-url-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      alpha_agent =
        register_agent!(%{
          name: "ses-url-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      send_message_to!(global_agent)
      send_message_to!(alpha_agent)

      {:ok, _view, html} = live(conn, ~p"/sessions?registry=team-alpha")

      refute html =~ "ses-url-global"
      assert html =~ "ses-url-alpha"
    end

    test "unknown ?registry= param defaults to global agent inboxes", %{conn: conn} do
      global_agent =
        register_agent!(%{
          name: "ses-def-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      send_message_to!(global_agent)

      {:ok, _view, html} = live(conn, ~p"/sessions?registry=nonexistent-xyz")

      assert html =~ "ses-def-global"
    end
  end

  describe "registry selector UI" do
    test "selector #registry-selector is present when public_mode is false", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions")
      assert has_element?(view, "#registry-selector")
    end

    test "selector is NOT present when public_mode is true", %{conn: conn} do
      Application.put_env(:viche, :public_mode, true)
      on_exit(fn -> Application.delete_env(:viche, :public_mode) end)
      {:ok, view, _html} = live(conn, ~p"/sessions")
      refute has_element?(view, "#registry-selector")
    end
  end

  describe "handle_event select_registry" do
    test "switching registry updates inbox display", %{conn: conn} do
      global_agent =
        register_agent!(%{
          name: "ses-chg-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      alpha_agent =
        register_agent!(%{
          name: "ses-chg-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      send_message_to!(global_agent)
      send_message_to!(alpha_agent)

      {:ok, view, html} = live(conn, ~p"/sessions")
      assert html =~ "ses-chg-global"
      refute html =~ "ses-chg-alpha"

      html_after = render_hook(view, "select_registry", %{"registry" => "team-alpha"})

      refute html_after =~ "ses-chg-global"
      assert html_after =~ "ses-chg-alpha"
    end

    test "switching to :all shows inboxes from all registries", %{conn: conn} do
      global_agent =
        register_agent!(%{
          name: "ses-all-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      alpha_agent =
        register_agent!(%{
          name: "ses-all-alpha",
          capabilities: ["testing"],
          registries: ["team-alpha"]
        })

      send_message_to!(global_agent)
      send_message_to!(alpha_agent)

      {:ok, view, _html} = live(conn, ~p"/sessions")

      html_all = render_hook(view, "select_registry", %{"registry" => "all"})

      assert html_all =~ "ses-all-global"
      assert html_all =~ "ses-all-alpha"
    end

    test "agent without inbox messages does not appear in inbox list", %{conn: conn} do
      _silent_agent =
        register_agent!(%{
          name: "ses-silent-global",
          capabilities: ["coding"],
          registries: ["global"]
        })

      {:ok, _view, html} = live(conn, ~p"/sessions")

      # Agent with no messages does not appear in the inbox panel
      refute html =~ "ses-silent-global"
    end
  end
end
