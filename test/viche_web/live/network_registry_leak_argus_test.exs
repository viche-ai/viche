defmodule VicheWeb.NetworkRegistryLeakArgusTest do
  use VicheWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    Viche.AgentSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
    end)

    :ok
  end

  defp register_agent!(attrs) do
    {:ok, agent} = Viche.Agents.register_agent(attrs)
    agent
  end

  test "Argus: switching registry leaves global network message subscriptions active", %{
    conn: conn
  } do
    global_agent =
      register_agent!(%{
        name: "net-leak-global",
        capabilities: ["coding"],
        registries: ["global"]
      })

    _alpha_agent =
      register_agent!(%{
        name: "net-leak-alpha",
        capabilities: ["testing"],
        registries: ["team-alpha"]
      })

    {:ok, view, html} = live(conn, ~p"/network")

    assert html =~ "net-leak-global"
    refute html =~ "net-leak-alpha"

    html_after_switch = render_hook(view, "select_registry", %{"registry" => "team-alpha"})

    assert html_after_switch =~ "net-leak-alpha"
    refute html_after_switch =~ "net-leak-global"

    leaked_sender = "cross-registry-network-secret"

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
