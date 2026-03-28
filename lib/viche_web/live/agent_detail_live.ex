defmodule VicheWeb.AgentDetailLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:task_input, "")
      |> assign(:response, nil)
      |> assign(:dispatch_history, [])
      |> assign(:agent, nil)
      |> load_sidebar_counts()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    all = Viche.Agents.list_agents() |> Enum.map(&augment_agent/1)
    agent = Enum.find(all, &(&1.id == id))

    if connected?(socket) && agent do
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{id}")
    end

    {:noreply, assign(socket, :agent, agent)}
  end

  @impl true
  def handle_event("task_input_changed", %{"task" => v}, socket) do
    {:noreply, assign(socket, :task_input, v)}
  end

  def handle_event("dispatch_task", %{"task" => task}, socket) do
    task = String.trim(task)

    if task != "" && socket.assigns.agent do
      agent = socket.assigns.agent

      Viche.Agents.send_message(%{
        to: agent.id,
        from: "mission-control",
        body: task,
        type: "task"
      })

      history_entry = %{task: task, result: "pending", elapsed_ms: 0}

      socket =
        socket
        |> assign(:response, %{status: :pending, messages: []})
        |> assign(:dispatch_history, [history_entry | socket.assigns.dispatch_history])

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_task", _params, socket) do
    {:noreply, assign(socket, task_input: "", response: nil)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "new_message", payload: p},
        socket
      ) do
    case socket.assigns.response do
      %{messages: msgs} = resp ->
        msg = %{type: p.type, body: p.body, at: "just now"}
        {:noreply, assign(socket, :response, %{resp | status: :done, messages: msgs ++ [msg]})}

      _ ->
        {:noreply, socket}
    end
  end

  # -- Helpers --

  defp load_sidebar_counts(socket) do
    all = Viche.Agents.list_agents() |> Enum.map(&augment_agent/1)
    online = Enum.count(all, &(&1.status in [:idle, :busy]))

    socket
    |> assign(:agent_count, length(all))
    |> assign(:online_count, online)
    |> assign(:session_count, 3)
    |> assign(:messages_today, 1247)
  end

  defp augment_agent(agent) do
    statuses = [:idle, :idle, :idle, :busy, :offline]
    status = Enum.at(statuses, :erlang.phash2(agent.name, 5))
    queue = if status == :busy, do: :erlang.phash2(agent.id, 6), else: 0
    Map.merge(agent, %{status: status, queue_depth: queue, last_seen: last_seen_mock(status)})
  end

  defp last_seen_mock(:idle), do: "just now"
  defp last_seen_mock(:busy), do: "#{:rand.uniform(30)}s ago"
  defp last_seen_mock(:offline), do: "#{:rand.uniform(60)}m ago"

  defp cap_icon("coding"), do: "⚡"
  defp cap_icon("testing"), do: "✓"
  defp cap_icon("refactor"), do: "↺"
  defp cap_icon("code-review"), do: "👁"
  defp cap_icon("debugging"), do: "🔍"
  defp cap_icon("web-search"), do: "🌐"
  defp cap_icon("writing"), do: "📝"
  defp cap_icon("security"), do: "🔒"
  defp cap_icon(_), do: "🤖"
end
