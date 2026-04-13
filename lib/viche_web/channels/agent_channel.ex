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

  - `"discover"` — find agents by capability or name; optional `"registry"` payload key scopes
    results (payload registry takes precedence over channel topic context)
  - `"send_message"` — send a message to another agent; payload must contain `"to"` (recipient
    agent ID), `"body"` (string), and optionally `"type"` (`"task"` | `"result"` | `"ping"`).
    The `"from"` field is **not accepted** — the sender is always derived from the authenticated
    socket (`socket.assigns.agent_id`). Any client-supplied `"from"` is silently dropped.
  - `"inspect_inbox"` — peek at inbox without consuming
  - `"drain_inbox"` — consume and return all inbox messages
  - `"join_registry"` — dynamically join a registry; payload must contain `"token"`
  - `"list_registries"` — list the registries the agent currently belongs to

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

  def join("agent:register", params, socket) do
    with {:ok, attrs} <- validate_register_params(params),
         {:ok, agent} <- Viche.Agents.register_agent_for_websocket(attrs) do
      Logger.info("Agent #{agent.id} registered and joined channel")
      {:ok, %{agent_id: agent.id}, assign(socket, :agent_id, agent.id)}
    else
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  def join("agent:" <> agent_id, _params, socket) do
    with :ok <- authorize_agent_join(socket, agent_id),
         :ok <- Viche.Agents.websocket_connected(agent_id) do
      Logger.info("Agent #{agent_id} joined channel")
      {:ok, assign(socket, :agent_id, agent_id)}
    else
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  def join("registry:" <> token, params, socket) do
    agent_id =
      Map.get(socket.assigns, :agent_id) || Map.get(params, "agent_id")

    case agent_id do
      nil ->
        Logger.warning(
          "Registry join refused for registry:#{token} — reason: agent_id_required (no agent_id in socket or params)"
        )

        {:error, %{reason: "agent_id_required"}}

      id ->
        case Viche.Agents.authorize_registry_join(id, token) do
          :ok ->
            Logger.info("Agent #{id} joined registry channel: #{token}")
            {:ok, socket |> assign(:agent_id, id) |> assign(:registry_token, token)}

          {:error, reason} ->
            Logger.warning(
              "Registry join refused for agent #{id} on registry:#{token} — reason: #{reason}"
            )

            {:error, %{reason: to_string(reason)}}
        end
    end
  end

  def terminate(_reason, socket) do
    agent_id = Map.get(socket.assigns, :agent_id)

    if is_nil(agent_id) do
      :ok
    else
      Logger.info("Agent #{agent_id} channel terminated")
      _ = Viche.Agents.websocket_disconnected(agent_id)
    end
  end

  def handle_in("discover", %{"capability" => cap} = params, socket) do
    %{capability: cap}
    |> maybe_add_registry(params, socket)
    |> handle_discover(socket)
  end

  def handle_in("discover", %{"name" => name} = params, socket) do
    %{name: name}
    |> maybe_add_registry(params, socket)
    |> handle_discover(socket)
  end

  def handle_in("send_message", %{"to" => to, "body" => body} = params, socket) do
    from = socket.assigns.agent_id
    type = Map.get(params, "type", "task")

    case Viche.Agents.send_message(%{to: to, from: from, body: body, type: type}) do
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

  def handle_in("broadcast_message", %{"registry" => registry, "body" => body} = params, socket) do
    from = socket.assigns.agent_id
    type = Map.get(params, "type", "task")

    case Viche.Agents.broadcast_message(%{from: from, registry: registry, body: body, type: type}) do
      {:ok, %{recipients: recipients} = result} ->
        {:reply, {:ok, %{recipients: recipients, failed: Map.get(result, :failed, [])}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: "broadcast failed: #{reason}"}},
         socket}
    end
  end

  def handle_in("broadcast_message", %{"body" => _}, socket) do
    {:reply, {:error, %{error: "missing_field", message: "required field 'registry' is missing"}},
     socket}
  end

  def handle_in("broadcast_message", %{"registry" => _}, socket) do
    {:reply, {:error, %{error: "missing_field", message: "required field 'body' is missing"}},
     socket}
  end

  def handle_in("broadcast_message", _params, socket) do
    {:reply,
     {:error,
      %{error: "missing_fields", message: "required fields 'registry' and 'body' are missing"}},
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

  def handle_in("heartbeat", _params, socket) do
    case Viche.Agents.heartbeat(socket.assigns.agent_id) do
      :ok ->
        {:reply, {:ok, %{status: "ok"}}, socket}

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

  def handle_in("deregister", %{"registry" => token}, socket) do
    agent_id = socket.assigns.agent_id

    case Viche.Agents.deregister_from_registries(agent_id, %{registry: token}) do
      {:ok, agent} ->
        {:reply, {:ok, %{registries: agent.registries}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: "deregister failed: #{reason}"}},
         socket}
    end
  end

  def handle_in("deregister", _params, socket) do
    agent_id = socket.assigns.agent_id

    case Viche.Agents.deregister_from_registries(agent_id, %{}) do
      {:ok, agent} ->
        {:reply, {:ok, %{registries: agent.registries}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: "deregister failed: #{reason}"}},
         socket}
    end
  end

  def handle_in("join_registry", %{"token" => token}, socket) do
    agent_id = socket.assigns.agent_id

    case Viche.Agents.join_registry(agent_id, token) do
      {:ok, agent} ->
        {:reply, {:ok, %{registries: agent.registries}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason)}}, socket}
    end
  end

  def handle_in("join_registry", _params, socket) do
    {:reply, {:error, %{error: "missing_field", field: "token"}}, socket}
  end

  def handle_in("list_registries", _params, socket) do
    agent_id = socket.assigns.agent_id

    case Viche.Agents.list_agent_registries_for(agent_id) do
      {:ok, registries} ->
        {:reply, {:ok, %{registries: registries}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason)}}, socket}
    end
  end

  def handle_in(event, _params, socket) do
    Logger.warning("Unknown event received on agent channel: #{inspect(event)}")
    {:reply, {:error, %{error: "unknown_event", message: "unrecognized event: #{event}"}}, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "new_message", payload: payload}, socket) do
    push(socket, "new_message", payload)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Priority: payload "registry" (binary) > socket.assigns.registry_token > omit
  # (no registry key → Agents.discover defaults to "global")
  defp maybe_add_registry(query, params, socket) do
    registry = Map.get(params, "registry") || Map.get(socket.assigns, :registry_token)

    if is_binary(registry) and byte_size(registry) > 0 do
      Map.put(query, :registry, registry)
    else
      query
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

  defp handle_discover(query, socket) do
    case Viche.Agents.discover(query) do
      {:ok, agents} ->
        {:reply, {:ok, %{agents: agents}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: to_string(reason), message: "discovery failed: #{reason}"}},
         socket}
    end
  end

  defp validate_register_params(params) when is_map(params) do
    capabilities = Map.get(params, "capabilities")

    cond do
      not is_list(capabilities) or capabilities == [] ->
        {:error, :capabilities_required}

      Enum.any?(capabilities, &(not is_binary(&1) or &1 == "")) ->
        {:error, :invalid_capabilities}

      true ->
        attrs =
          %{capabilities: capabilities}
          |> maybe_put_attr(params, :name, "name")
          |> maybe_put_attr(params, :description, "description")
          |> maybe_put_attr(params, :registries, "registries")

        {:ok, attrs}
    end
  end

  defp validate_register_params(_), do: {:error, :invalid_params}

  defp maybe_put_attr(attrs, params, key, source_key) do
    if Map.has_key?(params, source_key) do
      Map.put(attrs, key, Map.get(params, source_key))
    else
      attrs
    end
  end

  defp authorize_agent_join(socket, agent_id) do
    case Map.get(socket.assigns, :agent_id) do
      ^agent_id -> :ok
      nil -> {:error, :agent_id_required}
      _other -> {:error, :unauthorized_agent}
    end
  end
end
