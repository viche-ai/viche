defmodule VicheWeb.NetworkLive do
  use VicheWeb, :live_view

  alias VicheWeb.Live.RegistryScope

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      RegistryScope.subscribe("global")
      subscribe_to_all_agents(Viche.Agents.list_agents_with_status())
      Process.send_after(self(), :tick, 3_000)
    end

    public_mode = Application.get_env(:viche, :public_mode, false)
    user_id = session["user_id"]

    socket =
      socket
      |> assign(:selected_registry, "global")
      |> assign(:public_mode, public_mode)
      |> assign(:current_user_id, user_id)
      |> assign(:registries, RegistryScope.visible_registries(public_mode, user_id))
      |> assign(:registry_names, RegistryScope.registry_names(user_id))
      |> assign(:agent_registry_map, Viche.Agents.list_agent_registries())
      |> assign(:feed_by_registry, %{})
      |> assign(:feed, [])
      |> assign(:paused, false)
      |> assign(:mobile_menu_open, false)
      |> load_graph()

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
      |> load_graph_and_push()
      |> recompute_feed()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 3_000)

    {:noreply, load_graph_and_push(socket)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "registry:" <> _,
          event: "agent_joined",
          payload: payload
        },
        socket
      ) do
    new_agent_registry_map = Viche.Agents.list_agent_registries()
    registries = RegistryScope.registries_for_agent(new_agent_registry_map, payload.id)

    event = %{
      id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now(),
      type: "join",
      from: payload.name,
      to: "registry",
      color: "#A7C080",
      at: "just now"
    }

    feed_by_registry =
      RegistryScope.push_event_by_registry(socket.assigns.feed_by_registry, registries, event)

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
      |> assign(:feed_by_registry, feed_by_registry)
      |> load_graph_and_push()
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
      type: "task",
      from: payload.id,
      to: "registry",
      color: "#E67E80",
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
        RegistryScope.visible_registries(
          socket.assigns.public_mode,
          socket.assigns.current_user_id
        )
      )
      |> assign(:agent_registry_map, new_agent_registry_map)
      |> assign(:feed_by_registry, feed_by_registry)
      |> load_graph_and_push()
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
      color =
        case Enum.find(socket.assigns.agents, &(&1.id == agent_id)) do
          nil -> "#A7C080"
          agent -> agent.color
        end

      from_id =
        case Enum.find(socket.assigns.agents, &(&1.name == message.from || &1.id == message.from)) do
          nil -> nil
          agent -> agent.id
        end

      event = %{
        id: Ecto.UUID.generate(),
        inserted_at: DateTime.utc_now(),
        type: message.type,
        from: message.from,
        to: agent_id,
        color: color,
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
        |> assign(:feed_by_registry, feed_by_registry)
        |> recompute_feed()

      socket =
        if from_id do
          push_event(socket, "graph_pulse", %{from: from_id, to: agent_id, color: color})
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  def handle_event("select_registry", %{"registry" => registry}, socket) do
    {:noreply, push_patch(socket, to: ~p"/network?registry=#{registry}")}
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

  # Reloads agent graph data from the selected registry and updates assigns.
  defp load_graph(socket) do
    filter = RegistryScope.to_filter(socket.assigns.selected_registry)
    agents = Viche.Agents.list_agents_with_status(filter) |> Enum.map(&add_color/1)
    links = compute_links(agents)

    metrics_agents =
      if socket.assigns.public_mode do
        agents
      else
        Viche.Agents.list_agents_with_status(:all)
      end

    socket
    |> assign(:agents, agents)
    |> assign(:links, links)
    |> assign(:agent_count, length(metrics_agents))
  end

  # Reloads graph data and pushes a graph_update event to the client JS hook.
  defp load_graph_and_push(socket) do
    socket = load_graph(socket)

    push_event(socket, "graph_update", %{
      agents:
        Jason.encode!(
          Enum.map(socket.assigns.agents, fn a ->
            %{id: a.id, name: a.name, color: a.color, status: to_string(a.status)}
          end)
        ),
      links: Jason.encode!(socket.assigns.links)
    })
  end

  defp compute_links(agents) when length(agents) < 2, do: []

  defp compute_links(agents) do
    ids = Enum.map(agents, & &1.id)
    n = length(ids)

    for i <- 0..(n - 1), j <- (i + 1)..(n - 1), i != j, i + j < n + 3 do
      %{source: Enum.at(ids, i), target: Enum.at(ids, j)}
    end
    |> Enum.take(8)
  end

  defp add_color(agent) do
    Map.put(agent, :color, agent_color(agent.name))
  end

  defp agent_color(name) do
    colors = ["#A7C080", "#7FBBB3", "#D699B6", "#DBBC7F", "#83C092", "#E69875", "#E67E80"]
    Enum.at(colors, rem(:erlang.phash2(name), 7))
  end

  defp subscribe_to_all_agents(agents) do
    Enum.each(agents, fn agent ->
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{agent.id}")
    end)
  end
end
