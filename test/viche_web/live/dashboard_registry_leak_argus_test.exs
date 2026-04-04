defmodule VicheWeb.DashboardRegistryLeakArgusTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)

    {:ok, user} =
      Viche.Accounts.create_user(%{email: "leak-test-#{System.unique_integer()}@example.com"})

    {:ok, user: user}
  end

  defp register_agent!(attrs) do
    {:ok, agent} = Viche.Agents.register_agent(attrs)
    agent
  end

  test "Argus: switching registry leaves global dashboard message subscriptions active", %{
    conn: conn,
    user: user
  } do
    global_agent =
      register_agent!(%{
        name: "dash-leak-global",
        capabilities: ["coding"],
        registries: ["global"],
        user_id: user.id
      })

    _alpha_agent =
      register_agent!(%{
        name: "dash-leak-alpha",
        capabilities: ["testing"],
        registries: ["team-alpha"],
        user_id: user.id
      })

    {:ok, view, html} =
      conn
      |> init_test_session(%{"user_id" => user.id})
      |> live(~p"/dashboard")

    assert html =~ "dash-leak-global"
    refute html =~ "dash-leak-alpha"

    html_after_switch = render_hook(view, "select_registry", %{"registry" => "team-alpha"})

    assert html_after_switch =~ "dash-leak-alpha"
    refute html_after_switch =~ "dash-leak-global"

    leaked_sender = "cross-registry-dashboard-secret"

    Phoenix.PubSub.broadcast(
      Viche.PubSub,
      "agent:#{global_agent.id}",
      %Phoenix.Socket.Broadcast{
        topic: "agent:#{global_agent.id}",
        event: "new_message",
        payload: %{
          type: "task",
          from: leaked_sender,
          body: "should stay scoped to global"
        }
      }
    )

    _ = :sys.get_state(view.pid)

    html_after_leak = render(view)

    refute html_after_leak =~ leaked_sender
  end
end
