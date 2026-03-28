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
    agent =
      case Viche.Agents.get_agent_with_status(id) do
        {:ok, a} -> a
        {:error, _} -> nil
      end

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
    all = Viche.Agents.list_agents_with_status()
    online = Enum.count(all, &(&1.status == :online))

    socket
    |> assign(:agent_count, length(all))
    |> assign(:online_count, online)
    |> assign(:session_count, 3)
    |> assign(:messages_today, 1247)
  end

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
