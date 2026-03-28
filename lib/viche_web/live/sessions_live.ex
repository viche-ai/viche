defmodule VicheWeb.SessionsLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "registry:global")
      subscribe_to_all_agents()
      Process.send_after(self(), :tick, 5_000)
    end

    socket =
      socket
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_messages, [])
      |> assign(:messages_today, 0)
      |> load_inboxes()

    {:ok, socket}
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

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 5_000)
    {:noreply, load_inboxes(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "agent_joined", payload: payload}, socket) do
    Phoenix.PubSub.subscribe(Viche.PubSub, "agent:#{payload.id}")
    {:noreply, load_inboxes(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "agent_left"}, socket) do
    {:noreply, load_inboxes(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "new_message"}, socket) do
    {:noreply,
     socket
     |> update(:messages_today, &(&1 + 1))
     |> load_inboxes()}
  end

  # Catch-all for other broadcasts
  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  # -- Private --

  defp load_inboxes(socket) do
    agents = Viche.Agents.list_agents()

    inbox_agents =
      agents
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

    online =
      Enum.count(agents, fn a ->
        statuses = [:idle, :idle, :idle, :busy, :offline]
        Enum.at(statuses, :erlang.phash2(a.name, 5)) in [:idle, :busy]
      end)

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
    |> assign(:all_agents, agents)
    |> assign(:agent_count, length(agents))
    |> assign(:online_count, online)
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
