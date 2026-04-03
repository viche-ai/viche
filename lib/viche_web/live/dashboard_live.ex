defmodule VicheWeb.DashboardLive do
  use VicheWeb, :live_view

  alias VicheWeb.Live.RegistryScope

  @impl true
  def mount(_params, session, socket) do
    public_mode = Application.get_env(:viche, :public_mode, false)
    user_id = session["user_id"]

    socket =
      socket
      |> assign(:selected_registry, "global")
      |> assign(:public_mode, public_mode)
      |> assign(:current_user_id, user_id)
      |> assign(:registries, RegistryScope.visible_registries(public_mode))
      |> assign(:agent_registry_map, Viche.Agents.list_agent_registries())
      |> load_and_assign_agents()

    if connected?(socket) do
      RegistryScope.subscribe("global")
      Phoenix.PubSub.subscribe(Viche.PubSub, "dashboard:feed")
      subscribe_to_all_agents(socket.assigns.agents)
      Process.send_after(self(), :tick, 10_000)
    end

    socket =
      socket
      |> assign(:feed_by_registry, %{})
      |> assign(:feed, [])
      |> assign(:messages_today, 0)
      |> assign(:queued_messages, total_queued_messages(socket.assigns.agents))
      |> assign(:paused, false)
      |> assign(:mobile_menu_open, false)

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
      |> load_and_assign_agents()
      |> recompute_feed()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 10_000)

    socket =
      socket
      |> load_and_assign_agents()
      |> assign(:queued_messages, total_queued_messages(socket.assigns.agents))

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "registry:" <> _,
          event: "agent_joined",
          payload: payload
        },
        socket
      ) do
    Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{payload.id}")

    new_agent_registry_map = Viche.Agents.list_agent_registries()
    registries = RegistryScope.registries_for_agent(new_agent_registry_map, payload.id)

    event = %{
      id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now(),
      type: "join",
      from: payload.name,
      to: "registry",
      body: "New agent registered. Capabilities: #{Enum.join(payload.capabilities, ", ")}",
      at: "just now"
    }

    feed_by_registry =
      RegistryScope.push_event_by_registry(socket.assigns.feed_by_registry, registries, event)

    socket =
      socket
      |> assign(:registries, RegistryScope.visible_registries(socket.assigns.public_mode))
      |> assign(:agent_registry_map, new_agent_registry_map)
      |> assign(:feed_by_registry, feed_by_registry)
      |> load_and_assign_agents()
      |> recompute_feed()

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "registry:" <> _,
          event: "agent_left",
          payload: payload
        },
        socket
      ) do
    leaving_registries =
      RegistryScope.registries_for_agent(socket.assigns.agent_registry_map, payload.id)

    event = %{
      id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now(),
      type: "leave",
      from: payload.id,
      to: "registry",
      body: "Agent disconnected",
      at: "just now"
    }

    feed_by_registry =
      RegistryScope.push_event_by_registry(
        socket.assigns.feed_by_registry,
        leaving_registries,
        event
      )

    new_agent_registry_map = Viche.Agents.list_agent_registries()

    socket =
      socket
      |> assign(
        :registries,
        if(socket.assigns.public_mode, do: [], else: Viche.Agents.list_registries())
      )
      |> assign(:agent_registry_map, new_agent_registry_map)
      |> assign(:feed_by_registry, feed_by_registry)
      |> load_and_assign_agents()
      |> recompute_feed()

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "agent:" <> agent_id,
          event: "new_message",
          payload: message
        },
        socket
      ) do
    registries =
      RegistryScope.registries_for_agent(socket.assigns.agent_registry_map, agent_id)

    if registries == [] do
      {:noreply, socket}
    else
      event = %{
        id: Ecto.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        type: message.type,
        from: message.from,
        to: message[:to] || "unknown",
        body: message.body,
        at: "just now"
      }

      feed_by_registry =
        RegistryScope.push_event_by_registry(
          socket.assigns.feed_by_registry,
          registries,
          event
        )

      socket =
        socket
        |> update(:messages_today, &(&1 + 1))
        |> assign(:feed_by_registry, feed_by_registry)
        |> recompute_feed()

      {:noreply, socket}
    end
  end

  def handle_info({:feed_event, event}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      event_with_meta =
        event
        |> Map.put_new(:id, Ecto.UUID.generate())
        |> Map.put_new(:inserted_at, DateTime.utc_now())

      all_registries = socket.assigns.registries

      feed_by_registry =
        RegistryScope.push_event_by_registry(
          socket.assigns.feed_by_registry,
          all_registries,
          event_with_meta
        )

      socket =
        socket
        |> assign(:feed_by_registry, feed_by_registry)
        |> recompute_feed()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  def handle_event("navigate", %{"to" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("select_registry", %{"registry" => registry}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard?registry=#{registry}")}
  end

  # -- Helpers --

  defp recompute_feed(socket) do
    feed =
      RegistryScope.selected_feed(
        socket.assigns.feed_by_registry,
        socket.assigns.selected_registry
      )

    assign(socket, :feed, feed)
  end

  defp load_and_assign_agents(socket) do
    filter = RegistryScope.to_filter(socket.assigns.selected_registry)
    all_agents = Viche.Agents.list_agents_with_status(filter)

    # Filter to show only the current user's agents on the dashboard.
    # When not logged in, show only claimed agents (user_id IS NOT NULL).
    user_id = socket.assigns[:current_user_id]

    owned_ids =
      if user_id, do: MapSet.new(Viche.Agents.list_agent_ids_for_user(user_id)), else: nil

    claimed_ids = MapSet.new(Viche.Agents.list_claimed_agent_ids())

    agents =
      if user_id do
        Enum.filter(all_agents, &MapSet.member?(owned_ids, &1.id))
      else
        Enum.filter(all_agents, &MapSet.member?(claimed_ids, &1.id))
      end

    metrics_agents =
      if socket.assigns.public_mode do
        agents
      else
        all_unfiltered = Viche.Agents.list_agents_with_status(:all)

        if user_id do
          Enum.filter(all_unfiltered, &MapSet.member?(owned_ids, &1.id))
        else
          Enum.filter(all_unfiltered, &MapSet.member?(claimed_ids, &1.id))
        end
      end

    online = Enum.count(metrics_agents, &(&1.status == :online))

    socket
    |> assign(:agents, agents)
    |> assign(:agent_count, length(metrics_agents))
    |> assign(:online_count, online)
  end

  defp subscribe_to_all_agents(agents) do
    Enum.each(agents, fn agent ->
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{agent.id}")
    end)
  end

  defp total_queued_messages(agents) do
    Enum.sum(Enum.map(agents, & &1.queue_depth))
  end
end
