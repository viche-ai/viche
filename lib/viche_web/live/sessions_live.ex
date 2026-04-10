defmodule VicheWeb.SessionsLive do
  use VicheWeb, :live_view

  alias VicheWeb.Live.RegistryScope

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      RegistryScope.subscribe("global")
      subscribe_to_all_agents()
      Process.send_after(self(), :tick, 5_000)
    end

    public_mode = Application.get_env(:viche, :public_mode, false)
    user_id = session["user_id"]

    socket =
      socket
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_messages, [])
      |> assign(:selected_registry, "global")
      |> assign(:public_mode, public_mode)
      |> assign(:hosted, Viche.Config.hosted?())
      |> assign(:current_user_id, user_id)
      |> assign(:registries, RegistryScope.visible_registries(public_mode, user_id))
      |> assign(:registry_names, RegistryScope.registry_names(user_id))
      |> assign(:agent_registry_map, Viche.Agents.list_agent_registries())
      |> assign(:mobile_menu_open, false)
      |> load_inboxes()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    registry =
      if socket.assigns.public_mode do
        "global"
      else
        params
        |> Map.get("registry", "global")
        |> RegistryScope.normalize(socket.assigns.registries)
      end

    old_registry = socket.assigns.selected_registry

    if connected?(socket) do
      RegistryScope.switch(old_registry, registry)
    end

    socket =
      socket
      |> assign(:selected_registry, registry)
      |> load_inboxes()

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    selected_messages =
      case Enum.find(socket.assigns.inbox_agents, &(&1.agent.id == id)) do
        nil -> []
        entry -> entry.messages
      end

    {:noreply,
     socket
     |> assign(:selected_agent_id, id)
     |> assign(:selected_messages, selected_messages)}
  end

  def handle_event("select_registry", %{"registry" => registry}, socket) do
    {:noreply, push_patch(socket, to: ~p"/sessions?registry=#{registry}")}
  end

  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 5_000)
    {:noreply, load_inboxes(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "agent_joined", payload: payload}, socket) do
    Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{payload.id}")

    new_agent_registry_map = Viche.Agents.list_agent_registries()

    socket =
      socket
      |> assign(
        :registries,
        RegistryScope.visible_registries(
          socket.assigns.public_mode,
          socket.assigns.current_user_id
        )
      )
      |> assign(:agent_registry_map, new_agent_registry_map)
      |> load_inboxes()

    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "agent_left"}, socket) do
    new_agent_registry_map = Viche.Agents.list_agent_registries()

    socket =
      socket
      |> assign(
        :registries,
        RegistryScope.visible_registries(
          socket.assigns.public_mode,
          socket.assigns.current_user_id
        )
      )
      |> assign(:agent_registry_map, new_agent_registry_map)
      |> load_inboxes()

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "agent:" <> agent_id,
          event: "new_message"
        },
        socket
      ) do
    registries =
      RegistryScope.registries_for_agent(socket.assigns.agent_registry_map, agent_id)

    selected = socket.assigns.selected_registry
    in_scope? = selected == "all" or selected in registries

    if in_scope? do
      {:noreply, load_inboxes(socket)}
    else
      {:noreply, socket}
    end
  end

  # Catch-all for other broadcasts
  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  # -- Private --

  defp load_inboxes(socket) do
    filter = RegistryScope.to_filter(socket.assigns.selected_registry)
    agents_for_display = Viche.Agents.list_agents_with_status(filter)

    all_agents =
      if socket.assigns.public_mode do
        agents_for_display
      else
        Viche.Agents.list_agents_with_status(:all)
      end

    inbox_agents =
      agents_for_display
      |> Enum.map(fn agent ->
        case Viche.Agents.inspect_inbox(agent.id) do
          {:ok, messages} when messages != [] ->
            %{agent: agent, messages: messages, count: length(messages)}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(
        fn %{messages: msgs} ->
          last = List.last(msgs)
          last && DateTime.to_unix(last.sent_at)
        end,
        :desc
      )

    selected_messages =
      case socket.assigns[:selected_agent_id] do
        nil ->
          []

        id ->
          case Enum.find(inbox_agents, &(&1.agent.id == id)) do
            nil -> []
            entry -> entry.messages
          end
      end

    socket
    |> assign(:inbox_agents, inbox_agents)
    |> assign(:all_agents, agents_for_display)
    |> assign(:agent_count, length(all_agents))
    |> assign(:session_count, length(inbox_agents))
    |> assign(:selected_messages, selected_messages)
  end

  defp subscribe_to_all_agents do
    Viche.Agents.list_agents()
    |> Enum.each(fn agent ->
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{agent.id}")
    end)
  end
end
