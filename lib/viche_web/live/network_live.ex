defmodule VicheWeb.NetworkLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "registry:global")
      Process.send_after(self(), :tick, 3_000)
    end

    agents = Viche.Agents.list_agents() |> Enum.map(&augment_agent/1)
    links = compute_links(agents)
    online = Enum.count(agents, &(&1.status in [:idle, :busy]))

    socket =
      socket
      |> assign(:agents, agents)
      |> assign(:links, links)
      |> assign(:feed, seed_feed())
      |> assign(:paused, false)
      |> assign(:agent_count, length(agents))
      |> assign(:online_count, online)
      |> assign(:session_count, 3)
      |> assign(:messages_today, 1247)

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 3_000)
    agents = Viche.Agents.list_agents() |> Enum.map(&augment_agent/1)
    links = compute_links(agents)
    online = Enum.count(agents, &(&1.status in [:idle, :busy]))

    socket =
      socket
      |> assign(:agents, agents)
      |> assign(:links, links)
      |> assign(:agent_count, length(agents))
      |> assign(:online_count, online)
      |> push_event("graph_update", %{
        agents:
          Jason.encode!(
            Enum.map(agents, fn a ->
              %{id: a.id, name: a.name, color: a.color, status: to_string(a.status)}
            end)
          ),
        links: Jason.encode!(links)
      })

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
      color: "#A7C080",
      at: "just now"
    }

    agents = Viche.Agents.list_agents() |> Enum.map(&augment_agent/1)
    links = compute_links(agents)
    online = Enum.count(agents, &(&1.status in [:idle, :busy]))

    socket =
      socket
      |> assign(:agents, agents)
      |> assign(:links, links)
      |> assign(:agent_count, length(agents))
      |> assign(:online_count, online)
      |> push_event("graph_update", %{
        agents:
          Jason.encode!(
            Enum.map(agents, fn a ->
              %{id: a.id, name: a.name, color: a.color, status: to_string(a.status)}
            end)
          ),
        links: Jason.encode!(links)
      })
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
      type: "task",
      from: payload.id,
      to: "registry",
      color: "#E67E80",
      at: "just now"
    }

    agents = Viche.Agents.list_agents() |> Enum.map(&augment_agent/1)
    links = compute_links(agents)
    online = Enum.count(agents, &(&1.status in [:idle, :busy]))

    socket =
      socket
      |> assign(:agents, agents)
      |> assign(:links, links)
      |> assign(:agent_count, length(agents))
      |> assign(:online_count, online)
      |> push_event("graph_update", %{
        agents:
          Jason.encode!(
            Enum.map(agents, fn a ->
              %{id: a.id, name: a.name, color: a.color, status: to_string(a.status)}
            end)
          ),
        links: Jason.encode!(links)
      })
      |> update(:feed, fn feed -> [event | Enum.take(feed, 49)] end)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # -- Helpers --

  defp compute_links(agents) do
    ids = Enum.map(agents, & &1.id)
    n = length(ids)

    for i <- 0..(n - 1), j <- (i + 1)..(n - 1), i != j, i + j < n + 3 do
      %{source: Enum.at(ids, i), target: Enum.at(ids, j)}
    end
    |> Enum.take(8)
  end

  defp augment_agent(agent) do
    statuses = [:idle, :idle, :idle, :busy, :offline]
    status = Enum.at(statuses, :erlang.phash2(agent.name, 5))

    Map.merge(agent, %{
      status: status,
      queue_depth: 0,
      last_seen: "just now",
      color: agent_color(agent.name)
    })
  end

  defp agent_color(name) do
    colors = ["#A7C080", "#7FBBB3", "#D699B6", "#DBBC7F", "#83C092", "#E69875", "#E67E80"]
    Enum.at(colors, rem(:erlang.phash2(name), 7))
  end

  defp seed_feed do
    [
      %{type: "task", from: "geth-hivemind", to: "claude-code-1", color: "#A7C080", at: "just now"},
      %{type: "ack", from: "claude-code-1", to: "geth-hivemind", color: "#7FBBB3", at: "4s ago"},
      %{type: "join", from: "demo-agent", to: "registry", color: "#DBBC7F", at: "2m ago"}
    ]
  end
end
