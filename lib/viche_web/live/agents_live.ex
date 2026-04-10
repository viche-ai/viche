defmodule VicheWeb.AgentsLive do
  use VicheWeb, :live_view

  alias VicheWeb.Live.RegistryScope

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      RegistryScope.subscribe("global")
    end

    public_mode = Application.get_env(:viche, :public_mode, false)
    user_id = session["user_id"]

    socket =
      socket
      |> assign(:filter, :all)
      |> assign(:query, "")
      |> assign(:session_count, 3)
      |> assign(:selected_registry, "global")
      |> assign(:public_mode, public_mode)
      |> assign(:current_user_id, user_id)
      |> assign(:registries, RegistryScope.visible_registries(public_mode, user_id))
      |> assign(:registry_names, RegistryScope.registry_names(user_id))
      |> assign(:mobile_menu_open, false)
      |> load_agents()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    registry = RegistryScope.effective_registry(params, socket)
    old_registry = socket.assigns.selected_registry

    if connected?(socket) do
      RegistryScope.switch(old_registry, registry)
    end

    socket =
      socket
      |> assign(:selected_registry, registry)
      |> load_agents()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"status" => s}, socket) do
    filter = to_filter_atom(s)

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

  def handle_event("select_registry", %{"registry" => registry}, socket) do
    {:noreply, push_patch(socket, to: ~p"/agents?registry=#{registry}")}
  end

  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "registry:" <> _, event: event},
        socket
      )
      when event in ["agent_joined", "agent_left"] do
    socket =
      socket
      |> assign(
        :registries,
        RegistryScope.visible_registries(
          socket.assigns.public_mode,
          socket.assigns.current_user_id
        )
      )
      |> load_agents()

    {:noreply, socket}
  end

  # -- Helpers --

  defp load_agents(socket) do
    filter = RegistryScope.to_filter(socket.assigns.selected_registry)
    display = Viche.Agents.list_agents_with_status(filter)
    filtered = apply_filters(display, socket.assigns.filter, socket.assigns.query)

    metrics_agents = RegistryScope.metrics_agents(socket.assigns.public_mode, display)

    socket
    |> assign(:all_agents, display)
    |> assign(:agents, filtered)
    |> assign(:agent_count, length(metrics_agents))
  end

  defp to_filter_atom("all"), do: :all
  defp to_filter_atom("online"), do: :online
  defp to_filter_atom("offline"), do: :offline
  defp to_filter_atom(_), do: :all

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
