defmodule Viche.Agents do
  @moduledoc """
  Context module providing business logic for interacting with agents.

  Use these functions from IEx to talk to registered agents:

      Viche.Agents.list_agents()
      Viche.Agents.register_agent(%{capabilities: ["coding"], name: "my-agent"})
      Viche.Agents.send_message(%{to: "abc12345", from: "aris", body: "Hello!"})
      Viche.Agents.inspect_inbox("abc12345")
      Viche.Agents.drain_inbox("abc12345")
      Viche.Agents.discover(%{capability: "coding"})
      Viche.Agents.deregister("abc12345")
  """

  require Logger

  alias Viche.Agent
  alias Viche.AgentServer
  alias Viche.Message

  @typedoc "Agent map returned by list/discover functions."
  @type agent_info :: %{
          id: String.t(),
          name: String.t() | nil,
          capabilities: [String.t()],
          description: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns all registered agents as a list of lightweight info maps.
  """
  @spec list_agents() :: [agent_info()]
  def list_agents do
    Viche.AgentRegistry
    |> all_agents()
    |> Enum.map(&format_agent_public/1)
  end

  @doc """
  Returns all registered agents enriched with live status data from their GenServer state.

  Each agent map includes:
    - All fields from `list_agents/0` (id, name, capabilities, description)
    - `:status` — :online | :offline derived from last_activity vs polling_timeout_ms
    - `:last_activity` — DateTime or nil
    - `:registered_at` — DateTime
    - `:connection_type` — :websocket | :long_poll
    - `:queue_depth` — current inbox length
    - `:polling_timeout_ms` — the agent's configured timeout
  """
  @spec list_agents_with_status() :: [map()]
  def list_agents_with_status do
    Viche.AgentRegistry
    |> all_agents()
    |> Enum.map(fn {id, meta} ->
      via = {:via, Registry, {Viche.AgentRegistry, id}}

      try do
        agent = AgentServer.get_state(via)
        status = derive_status(agent)
        inbox_depth = length(agent.inbox)

        %{
          id: id,
          name: meta.name,
          capabilities: meta.capabilities,
          description: meta.description,
          status: status,
          last_activity: agent.last_activity,
          registered_at: agent.registered_at,
          connection_type: agent.connection_type,
          queue_depth: inbox_depth,
          polling_timeout_ms: agent.polling_timeout_ms
        }
      rescue
        _ ->
          %{
            id: id,
            name: meta.name,
            capabilities: meta.capabilities,
            description: meta.description,
            status: :offline,
            last_activity: nil,
            registered_at: nil,
            connection_type: :long_poll,
            queue_depth: 0,
            polling_timeout_ms: 60_000
          }
      end
    end)
  end

  @doc """
  Returns a single agent enriched with live status data.
  """
  @spec get_agent_with_status(String.t()) :: {:ok, map()} | {:error, :agent_not_found}
  def get_agent_with_status(agent_id) do
    case Registry.lookup(Viche.AgentRegistry, agent_id) do
      [] ->
        {:error, :agent_not_found}

      [{_pid, meta}] ->
        via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
        agent = AgentServer.get_state(via)
        status = derive_status(agent)

        {:ok,
         %{
           id: agent_id,
           name: meta.name,
           capabilities: meta.capabilities,
           description: meta.description,
           status: status,
           last_activity: agent.last_activity,
           registered_at: agent.registered_at,
           connection_type: agent.connection_type,
           queue_depth: length(agent.inbox),
           polling_timeout_ms: agent.polling_timeout_ms
         }}
    end
  end

  @doc """
  Registers a new agent and starts its GenServer.

  ## Parameters
    - `%{capabilities: [...], name: "...", description: "...", polling_timeout_ms: 60_000}`

  `name`, `description`, and `polling_timeout_ms` are optional; `capabilities` is required and
  must be a non-empty list.

  `polling_timeout_ms` defaults to `60_000` (60 seconds) and must be >= 5000 if provided.

  ## Returns
    - `{:ok, %Viche.Agent{}}` on success
    - `{:error, :capabilities_required}` when capabilities are missing or empty
  """
  @spec register_agent(map()) ::
          {:ok, Agent.t()}
          | {:error, :capabilities_required}
          | {:error, :invalid_capabilities}
          | {:error, :invalid_name}
          | {:error, :invalid_description}
          | {:error, :invalid_registry_token}
  def register_agent(%{capabilities: caps} = attrs) when is_list(caps) and caps != [] do
    with :ok <- validate_string_list(caps, :invalid_capabilities),
         :ok <- validate_optional_string(Map.get(attrs, :name), :invalid_name),
         :ok <- validate_optional_string(Map.get(attrs, :description), :invalid_description),
         {:ok, registries} <- normalize_and_validate_registries(Map.get(attrs, :registries)) do
      start_agent(attrs, caps, registries)
    end
  end

  def register_agent(_attrs), do: {:error, :capabilities_required}

  @doc """
  Deregisters an agent: stops its GenServer, purges inbox, removes from Registry.

  The agent can re-register later with a new ID but starts with clean state.

  ## Returns
    - `:ok` — agent was deregistered
    - `{:error, :agent_not_found}` — no agent with the given id
  """
  @spec deregister(String.t()) :: :ok | {:error, :agent_not_found}
  def deregister(agent_id) do
    case Registry.lookup(Viche.AgentRegistry, agent_id) do
      [{pid, meta}] ->
        broadcast_agent_left(agent_id, meta.registries || [])
        DynamicSupervisor.terminate_child(Viche.AgentSupervisor, pid)
        Logger.info("Agent #{agent_id} deregistered")
        :ok

      [] ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Discovers agents by capability or name, scoped to a registry namespace.

  ## Parameters
    - `%{capability: "*"}` — return all agents in the `"global"` namespace (default)
    - `%{capability: "*", registry: token}` — return all agents in the given namespace
    - `%{name: "*"}` — return all agents in the `"global"` namespace (default)
    - `%{name: "*", registry: token}` — return all agents in the given namespace
    - `%{capability: "..."}` — find agents in `"global"` with the given capability
    - `%{capability: "...", registry: token}` — find agents in the given namespace with the capability
    - `%{name: "..."}` — find agents in `"global"` with an exact name match
    - `%{name: "...", registry: token}` — find agents in the given namespace with an exact name match

  Discovery is namespace-scoped. When no `registry` key is provided, the `"global"` namespace
  is searched. Messaging remains cross-namespace (see `send_message/1`).

  ## Returns
    - `{:ok, [agent_info()]}` — list may be empty if no matches
    - `{:error, :query_required}` — when neither `:capability` nor `:name` is provided
  """
  @spec discover(map()) :: {:ok, [agent_info()]} | {:error, :query_required}
  def discover(query) do
    registry = Map.get(query, :registry, "global")

    case classify_query(query) do
      :all -> {:ok, agents_in_registry(registry)}
      {:capability, cap} -> {:ok, find_by_capability_in(cap, registry)}
      {:name, name} -> {:ok, find_by_name_in(name, registry)}
      :error -> {:error, :query_required}
    end
  end

  @doc """
  Sends a message to an agent's inbox.

  ## Parameters
    - `%{to: agent_id, from: sender, body: text}` — required keys
    - `:type` — optional, defaults to `"task"`. Must be one of `"task"`, `"result"`, `"ping"`.

  ## Returns
    - `{:ok, message_id}` — fire-and-forget; message_id starts with `"msg-"`
    - `{:error, :agent_not_found}` — no agent with the given id
    - `{:error, :invalid_message}` — from or body are missing/empty, or type is invalid
  """
  @spec send_message(map()) ::
          {:ok, String.t()} | {:error, :agent_not_found} | {:error, :invalid_message}
  def send_message(%{to: agent_id, from: from, body: body} = attrs)
      when is_binary(from) and from != "" and is_binary(body) and body != "" do
    type = Map.get(attrs, :type, "task")

    with true <- Message.valid_type?(type),
         :found <- lookup_agent(agent_id) do
      message = %Message{
        id: generate_message_id(),
        type: type,
        from: from,
        body: body,
        sent_at: DateTime.utc_now()
      }

      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      AgentServer.receive_message(via, message)

      Viche.MessageCounter.increment()

      VicheWeb.Endpoint.broadcast("agent:#{agent_id}", "new_message", %{
        id: message.id,
        type: message.type,
        from: message.from,
        body: message.body,
        sent_at: DateTime.to_iso8601(message.sent_at)
      })

      {:ok, message.id}
    else
      false -> {:error, :invalid_message}
      :not_found -> {:error, :agent_not_found}
    end
  end

  def send_message(_attrs), do: {:error, :invalid_message}

  @doc """
  Peeks at an agent's inbox WITHOUT consuming the messages.

  Calling this twice returns the same messages both times. Use `drain_inbox/1` to
  consume.

  ## Returns
    - `{:ok, [Message.t()]}` — messages oldest-first; list may be empty
    - `{:error, :agent_not_found}`
  """
  @spec inspect_inbox(String.t()) :: {:ok, [Message.t()]} | {:error, :agent_not_found}
  def inspect_inbox(agent_id) do
    case lookup_agent(agent_id) do
      :not_found ->
        {:error, :agent_not_found}

      :found ->
        via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
        {:ok, AgentServer.inspect_inbox(via)}
    end
  end

  @doc """
  Drains an agent's inbox, consuming all messages atomically.

  Subsequent calls return an empty list until new messages arrive.

  ## Returns
    - `{:ok, [Message.t()]}` — messages oldest-first; list may be empty
    - `{:error, :agent_not_found}`
  """
  @spec drain_inbox(String.t()) :: {:ok, [Message.t()]} | {:error, :agent_not_found}
  def drain_inbox(agent_id) do
    case lookup_agent(agent_id) do
      :not_found ->
        {:error, :agent_not_found}

      :found ->
        via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
        {:ok, AgentServer.drain_inbox(via)}
    end
  end

  @token_regex ~r/^[a-zA-Z0-9._-]+$/

  @doc """
  Returns `true` if `token` is a valid registry token: 4–256 characters,
  alphanumeric with `.`, `_`, and `-` only.
  """
  @spec valid_token?(String.t()) :: boolean()
  def valid_token?(token) when is_binary(token) do
    byte_size(token) >= 4 and byte_size(token) <= 256 and Regex.match?(@token_regex, token)
  end

  def valid_token?(_), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec derive_status(Agent.t()) :: :online | :offline
  defp derive_status(%Agent{connection_type: :websocket}), do: :online
  defp derive_status(%Agent{last_activity: nil}), do: :offline

  defp derive_status(%Agent{last_activity: last_activity, polling_timeout_ms: timeout_ms}) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), last_activity, :millisecond)
    if elapsed_ms < timeout_ms * 2, do: :online, else: :offline
  end

  @spec all_agents(atom()) :: [{String.t(), map()}]
  defp all_agents(registry) do
    Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
  end

  @spec classify_query(map()) ::
          :all | {:capability, String.t()} | {:name, String.t()} | :error
  defp classify_query(%{capability: "*"}), do: :all
  defp classify_query(%{name: "*"}), do: :all

  defp classify_query(%{capability: cap}) when is_binary(cap) and cap != "",
    do: {:capability, cap}

  defp classify_query(%{name: name}) when is_binary(name) and name != "", do: {:name, name}
  defp classify_query(_), do: :error

  @spec agents_in_registry(String.t()) :: [agent_info()]
  defp agents_in_registry(registry) do
    for {id, meta} <- all_agents(Viche.AgentRegistry),
        registry in agent_registries(meta) do
      format_agent_public({id, meta})
    end
  end

  @spec find_by_capability_in(String.t(), String.t()) :: [agent_info()]
  defp find_by_capability_in(capability, registry) do
    for {id, meta} <- all_agents(Viche.AgentRegistry),
        registry in agent_registries(meta),
        capability in meta.capabilities do
      format_agent_public({id, meta})
    end
  end

  @spec find_by_name_in(String.t(), String.t()) :: [agent_info()]
  defp find_by_name_in(name, registry) do
    for {id, meta} <- all_agents(Viche.AgentRegistry),
        registry in agent_registries(meta),
        meta.name == name do
      format_agent_public({id, meta})
    end
  end

  @spec agent_registries(map()) :: [String.t()]
  defp agent_registries(meta), do: meta.registries || []

  @spec format_agent_public({String.t(), map()}) :: agent_info()
  defp format_agent_public({id, meta}) do
    %{
      id: id,
      name: meta.name,
      capabilities: meta.capabilities,
      description: meta.description
    }
  end

  @spec lookup_agent(String.t()) :: :found | :not_found
  defp lookup_agent(agent_id) do
    case Registry.lookup(Viche.AgentRegistry, agent_id) do
      [] -> :not_found
      _ -> :found
    end
  end

  @spec generate_unique_id() :: String.t()
  defp generate_unique_id do
    Ecto.UUID.generate()
  end

  @spec generate_message_id() :: String.t()
  defp generate_message_id do
    "msg-#{Ecto.UUID.generate()}"
  end

  @spec validate_string_list([term()], atom()) :: :ok | {:error, atom()}
  defp validate_string_list(list, error_key) do
    if Enum.all?(list, &is_binary/1), do: :ok, else: {:error, error_key}
  end

  @spec validate_optional_string(term(), atom()) :: :ok | {:error, atom()}
  defp validate_optional_string(nil, _error_key), do: :ok
  defp validate_optional_string(value, _error_key) when is_binary(value), do: :ok
  defp validate_optional_string(_value, error_key), do: {:error, error_key}

  @spec normalize_and_validate_registries(term()) ::
          {:ok, [String.t()]} | {:error, :invalid_registry_token}
  defp normalize_and_validate_registries(nil), do: {:ok, ["global"]}
  defp normalize_and_validate_registries([]), do: {:ok, ["global"]}

  defp normalize_and_validate_registries(registries) when is_list(registries) do
    if Enum.all?(registries, &valid_token?/1),
      do: {:ok, registries},
      else: {:error, :invalid_registry_token}
  end

  defp normalize_and_validate_registries(_), do: {:error, :invalid_registry_token}

  @spec start_agent(map(), [String.t()], [String.t()]) :: {:ok, Agent.t()}
  defp start_agent(attrs, caps, registries) do
    name = Map.get(attrs, :name)
    description = Map.get(attrs, :description)
    polling_timeout_ms = Map.get(attrs, :polling_timeout_ms)
    agent_id = generate_unique_id()

    child_opts = [
      id: agent_id,
      name: name,
      capabilities: caps,
      description: description,
      registries: registries
    ]

    child_opts =
      if polling_timeout_ms,
        do: Keyword.put(child_opts, :polling_timeout_ms, polling_timeout_ms),
        else: child_opts

    child_spec = {AgentServer, child_opts}
    {:ok, _pid} = DynamicSupervisor.start_child(Viche.AgentSupervisor, child_spec)

    via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
    agent = AgentServer.get_state(via)

    Logger.info(
      "Agent #{agent.id} registered (name: #{inspect(agent.name)}, " <>
        "capabilities: #{inspect(agent.capabilities)}, " <>
        "registries: #{inspect(agent.registries)}, " <>
        "polling_timeout: #{agent.polling_timeout_ms}ms)"
    )

    broadcast_agent_joined(agent)

    {:ok, agent}
  end

  @spec broadcast_agent_joined(Agent.t()) :: :ok
  defp broadcast_agent_joined(agent) do
    payload = %{
      id: agent.id,
      name: agent.name,
      capabilities: agent.capabilities,
      description: agent.description
    }

    Enum.each(agent.registries, fn registry ->
      VicheWeb.Endpoint.broadcast("registry:#{registry}", "agent_joined", payload)
    end)
  end

  @spec broadcast_agent_left(String.t(), [String.t()]) :: :ok
  defp broadcast_agent_left(agent_id, registries) do
    Enum.each(registries, fn registry ->
      VicheWeb.Endpoint.broadcast("registry:#{registry}", "agent_left", %{id: agent_id})
    end)
  end
end
