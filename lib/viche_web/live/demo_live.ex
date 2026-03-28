defmodule VicheWeb.DemoLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    agents = Viche.Agents.list_agents()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "registry:global")
    end

    {:ok,
     assign(socket,
       agent_count: length(agents),
       messages_today: 0
     )}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "agent_joined"}, socket) do
    {:noreply, assign(socket, agent_count: length(Viche.Agents.list_agents()))}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "agent_left"}, socket) do
    {:noreply, assign(socket, agent_count: length(Viche.Agents.list_agents()))}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
