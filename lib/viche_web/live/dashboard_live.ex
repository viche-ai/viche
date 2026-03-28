defmodule VicheWeb.DashboardLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket = socket |> load_and_assign_agents()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "registry:global")
      Phoenix.PubSub.subscribe(Viche.PubSub, "dashboard:feed")
      subscribe_to_all_agents(socket.assigns.agents)
      Process.send_after(self(), :tick, 10_000)
    end

    socket =
      socket
      |> assign(:feed, [])
      |> assign(:messages_today, 0)
      |> assign(:queued_messages, total_queued_messages(socket.assigns.agents))
      |> assign(:paused, false)

    {:ok, socket}
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
          topic: "registry:global",
          event: "agent_joined",
          payload: payload
        },
        socket
      ) do
    event = %{
      type: "join",
      from: payload.name,
      to: "registry",
      body: "New agent registered. Capabilities: #{Enum.join(payload.capabilities, ", ")}",
      at: "just now"
    }

    Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{payload.id}")

    socket =
      socket
      |> load_and_assign_agents()
      |> update(:feed, fn feed -> [event | Enum.take(feed, 49)] end)

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "registry:global",
          event: "agent_left",
          payload: payload
        },
        socket
      ) do
    event = %{
      type: "leave",
      from: payload.id,
      to: "registry",
      body: "Agent disconnected",
      at: "just now"
    }

    socket =
      socket
      |> load_and_assign_agents()
      |> update(:feed, fn feed -> [event | Enum.take(feed, 49)] end)

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "agent:" <> _agent_id,
          event: "new_message",
          payload: message
        },
        socket
      ) do
    event = %{
      type: message.type,
      from: message.from,
      to: message[:to] || "unknown",
      body: message.body,
      at: "just now"
    }

    socket =
      socket
      |> update(:messages_today, &(&1 + 1))
      |> update(:feed, fn feed -> [event | Enum.take(feed, 49)] end)

    {:noreply, socket}
  end

  def handle_info({:feed_event, event}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      {:noreply, update(socket, :feed, fn feed -> [event | Enum.take(feed, 49)] end)}
    end
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("navigate", %{"to" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  # -- Helpers --

  defp load_and_assign_agents(socket) do
    agents = Viche.Agents.list_agents() |> Enum.map(&augment_agent/1)
    online = Enum.count(agents, &(&1.status in [:idle, :busy]))

    socket
    |> assign(:agents, agents)
    |> assign(:agent_count, length(agents))
    |> assign(:online_count, online)
  end

  defp augment_agent(agent) do
    statuses = [:idle, :idle, :idle, :busy, :offline]
    status = Enum.at(statuses, :erlang.phash2(agent.name, 5))
    queue = if status == :busy, do: :erlang.phash2(agent.id, 6), else: 0

    Map.merge(agent, %{
      status: status,
      queue_depth: queue,
      last_seen: last_seen_mock(status)
    })
  end

  defp last_seen_mock(:idle), do: "just now"
  defp last_seen_mock(:busy), do: "#{:rand.uniform(30)}s ago"
  defp last_seen_mock(:offline), do: "#{:rand.uniform(60)}m ago"

  defp subscribe_to_all_agents(agents) do
    Enum.each(agents, fn agent ->
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{agent.id}")
    end)
  end

  defp total_queued_messages(agents) do
    Enum.reduce(agents, 0, fn agent, acc ->
      case Viche.Agents.inspect_inbox(agent.id) do
        {:ok, msgs} -> acc + length(msgs)
        _ -> acc
      end
    end)
  end
end
