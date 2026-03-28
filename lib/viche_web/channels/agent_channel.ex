defmodule VicheWeb.AgentChannel do
  @moduledoc """
  Phoenix Channel for real-time agent communication.

  Agents join their own topic `"agent:{agent_id}"` to:
  - Receive new messages pushed in real-time via `Endpoint.broadcast/3`
  - Discover other agents
  - Send messages to other agents
  - Inspect or drain their own inbox

  Agents may also join `"registry:{token}"` topics to:
  - Receive `"agent_joined"` broadcasts when agents register in that namespace
  - Receive `"agent_left"` broadcasts when agents deregister from that namespace
  - Discover agents scoped to that registry via the `"discover"` event

  ## Events (client → server)

  - `"discover"` — find agents by capability or name (scoped to registry when on a registry topic)
  - `"send_message"` — send a message to another agent
  - `"inspect_inbox"` — peek at inbox without consuming
  - `"drain_inbox"` — consume and return all inbox messages

  ## Events (server → client)

  - `"new_message"` — pushed when a message arrives in the agent's inbox;
    delivered automatically via `VicheWeb.Endpoint.broadcast/3`
  - `"agent_joined"` — pushed on registry topics when a new agent registers
  - `"agent_left"` — pushed on registry topics when an agent deregisters

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

  def join("registry:" <> token, _params, socket) do
    agent_id = socket.assigns.agent_id

    case Registry.lookup(Viche.AgentRegistry, agent_id) do
      [{_pid, meta}] ->
        if token in (meta.registries || []) do
          Logger.info("Agent #{agent_id} joined registry channel: #{token}")
          {:ok, assign(socket, :registry_token, token)}
        else
          {:error, %{reason: "not_in_registry"}}
        end

      [] ->
        {:error, %{reason: "not_in_registry"}}
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
    query = build_discover_query(%{capability: cap}, socket)

    case Viche.Agents.discover(query) do
      {:ok, agents} ->
        {:reply, {:ok, %{agents: agents}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: "discovery failed: #{reason}"}},
         socket}
    end
  end

  def handle_in("discover", %{"name" => name}, socket) do
    query = build_discover_query(%{name: name}, socket)

    case Viche.Agents.discover(query) do
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

  # Scopes the discover query to the registry when on a registry channel.
  defp build_discover_query(base_query, socket) do
    case Map.get(socket.assigns, :registry_token) do
      nil -> base_query
      token -> Map.put(base_query, :registry, token)
    end
  end

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
