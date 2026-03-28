defmodule VicheWeb.AgentChannel do
  @moduledoc """
  Phoenix Channel for real-time agent communication.

  Agents join their own topic `"agent:{agent_id}"` to:
  - Receive new messages pushed in real-time via `Endpoint.broadcast/3`
  - Discover other agents
  - Send messages to other agents
  - Inspect or drain their own inbox

  ## Events (client → server)

  - `"discover"` — find agents by capability or name
  - `"send_message"` — send a message to another agent
  - `"inspect_inbox"` — peek at inbox without consuming
  - `"drain_inbox"` — consume and return all inbox messages

  ## Events (server → client)

  - `"new_message"` — pushed when a message arrives in the agent's inbox;
    delivered automatically via `VicheWeb.Endpoint.broadcast/3`

  ## Lifecycle notifications

  On `join/3`, the AgentServer is notified via `:websocket_connected`, which sets
  `connection_type: :websocket` and cancels any pending polling-based deregistration.

  On `terminate/2`, the AgentServer is notified via `:websocket_disconnected`, which
  starts a 5-second grace timer. If the agent reconnects before the timer fires, the
  grace timer is cancelled and the agent stays alive.
  """

  use Phoenix.Channel

  require Logger

  def join("agent:" <> agent_id, _params, socket) do
    case Registry.lookup(Viche.AgentRegistry, agent_id) do
      [{pid, _meta}] ->
        send(pid, :websocket_connected)
        Logger.info("Agent #{agent_id} joined channel")
        {:ok, assign(socket, :agent_id, agent_id)}

      [] ->
        {:error, %{reason: "agent_not_found"}}
    end
  end

  def terminate(_reason, socket) do
    agent_id = Map.get(socket.assigns, :agent_id)

    if is_nil(agent_id) do
      :ok
    else
      Logger.info("Agent #{agent_id} channel terminated")

      case Registry.lookup(Viche.AgentRegistry, agent_id) do
        [{pid, _meta}] -> send(pid, :websocket_disconnected)
        [] -> :ok
      end
    end
  end

  def handle_in("discover", %{"capability" => cap}, socket) do
    case Viche.Agents.discover(%{capability: cap}) do
      {:ok, agents} ->
        {:reply, {:ok, %{agents: agents}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: "discovery failed: #{reason}"}},
         socket}
    end
  end

  def handle_in("discover", %{"name" => name}, socket) do
    case Viche.Agents.discover(%{name: name}) do
      {:ok, agents} ->
        {:reply, {:ok, %{agents: agents}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: "discovery failed: #{reason}"}},
         socket}
    end
  end

  def handle_in("send_message", %{"to" => to, "body" => body} = params, socket) do
    agent_id = socket.assigns.agent_id
    type = Map.get(params, "type", "task")

    case Viche.Agents.send_message(%{to: to, from: agent_id, body: body, type: type}) do
      {:ok, message_id} ->
        {:reply, {:ok, %{message_id: message_id}}, socket}

      {:error, reason} ->
        {:reply,
         {:error, %{error: to_string(reason), message: "message delivery failed: #{reason}"}},
         socket}
    end
  end

  def handle_in("send_message", %{"body" => _}, socket) do
    {:reply, {:error, %{error: "missing_field", message: "required field 'to' is missing"}},
     socket}
  end

  def handle_in("send_message", %{"to" => _}, socket) do
    {:reply, {:error, %{error: "missing_field", message: "required field 'body' is missing"}},
     socket}
  end

  def handle_in("send_message", _params, socket) do
    {:reply,
     {:error, %{error: "missing_fields", message: "required fields 'to' and 'body' are missing"}},
     socket}
  end

  def handle_in("discover", _params, socket) do
    {:reply,
     {:error,
      %{error: "missing_field", message: "required field 'capability' or 'name' is missing"}},
     socket}
  end

  def handle_in("inspect_inbox", _params, socket) do
    case Viche.Agents.inspect_inbox(socket.assigns.agent_id) do
      {:ok, messages} ->
        {:reply, {:ok, %{messages: format_messages(messages)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: to_string(reason)}}, socket}
    end
  end

  def handle_in("drain_inbox", _params, socket) do
    case Viche.Agents.drain_inbox(socket.assigns.agent_id) do
      {:ok, messages} ->
        {:reply, {:ok, %{messages: format_messages(messages)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: to_string(reason)}}, socket}
    end
  end

  def handle_in(event, _params, socket) do
    Logger.warning("Unknown event received on agent channel: #{inspect(event)}")
    {:reply, {:error, %{error: "unknown_event", message: "unrecognized event: #{event}"}}, socket}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        id: msg.id,
        type: msg.type,
        from: msg.from,
        body: msg.body,
        sent_at: DateTime.to_iso8601(msg.sent_at)
      }
    end)
  end
end
