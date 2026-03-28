defmodule VicheWeb.AgentsLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "registry:global")
      Phoenix.PubSub.subscribe(Viche.PubSub, "metrics:messages")
    end

    socket =
      socket
      |> assign(:filter, :all)
      |> assign(:query, "")
      |> assign(:session_count, 3)
      |> assign(:messages_today, Viche.MessageCounter.get())
      |> load_agents()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"status" => s}, socket) do
    filter = String.to_atom(s)

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:agents, apply_filters(socket.assigns.all_agents, filter, socket.assigns.query))

    {:noreply, socket}
  end

  def handle_event("search", %{"value" => q}, socket) do
    socket =
      socket
      |> assign(:query, q)
      |> assign(:agents, apply_filters(socket.assigns.all_agents, socket.assigns.filter, q))

    {:noreply, socket}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/agents/#{id}")}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "registry:global", event: event},
        socket
      )
      when event in ["agent_joined", "agent_left"] do
    {:noreply, load_agents(socket)}
  end

  def handle_info({:messages_today, n}, socket), do: {:noreply, assign(socket, :messages_today, n)}

  # -- Helpers --

  defp load_agents(socket) do
    all = Viche.Agents.list_agents_with_status()
    filtered = apply_filters(all, socket.assigns.filter, socket.assigns.query)
    online = Enum.count(all, &(&1.status == :online))

    socket
    |> assign(:all_agents, all)
    |> assign(:agents, filtered)
    |> assign(:agent_count, length(all))
    |> assign(:online_count, online)
  end

  defp apply_filters(agents, filter, query) do
    agents |> filter_by_status(filter) |> filter_by_query(query)
  end

  defp filter_by_status(agents, :all), do: agents
  defp filter_by_status(agents, :online), do: Enum.filter(agents, &(&1.status == :online))
  defp filter_by_status(agents, :offline), do: Enum.filter(agents, &(&1.status == :offline))
  defp filter_by_status(agents, _), do: agents

  defp filter_by_query(agents, ""), do: agents

  defp filter_by_query(agents, q) do
    q = String.downcase(q)

    Enum.filter(agents, fn a ->
      String.contains?(String.downcase(a.name || ""), q) ||
        Enum.any?(a.capabilities, &String.contains?(String.downcase(&1), q))
    end)
  end
end
