defmodule VicheWeb.AgentDetailLive do
  use VicheWeb, :live_view

  alias VicheWeb.Live.RegistryScope

  @impl true
  def mount(_params, session, socket) do
    public_mode = Application.get_env(:viche, :public_mode, false)
    user_id = session["user_id"]

    socket =
      socket
      |> assign(:task_input, "")
      |> assign(:response, nil)
      |> assign(:dispatch_history, [])
      |> assign(:agent, nil)
      |> assign(:selected_registry, "global")
      |> assign(:public_mode, public_mode)
      |> assign(:current_user_id, user_id)
      |> assign(:registries, RegistryScope.visible_registries(public_mode, user_id))
      |> assign(:mobile_menu_open, false)
      |> load_sidebar_counts()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    agent =
      case Viche.Agents.get_agent_with_status(id) do
        {:ok, a} -> a
        {:error, _} -> nil
      end

    if connected?(socket) && agent do
      Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{id}")
    end

    registry =
      if socket.assigns.public_mode do
        "global"
      else
        params
        |> Map.get("registry", "global")
        |> RegistryScope.normalize(socket.assigns.registries)
      end

    socket =
      socket
      |> assign(:agent, agent)
      |> assign(:selected_registry, registry)

    {:noreply, socket}
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

  def handle_event("select_registry", %{"registry" => registry}, socket) do
    path =
      case socket.assigns.agent do
        nil -> ~p"/agents?registry=#{registry}"
        agent -> ~p"/agents/#{agent.id}?registry=#{registry}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
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
    all =
      if socket.assigns.public_mode do
        Viche.Agents.list_agents_with_status("global")
      else
        Viche.Agents.list_agents_with_status(:all)
      end

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
