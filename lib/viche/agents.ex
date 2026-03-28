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
  """

  alias Viche.Agent
  alias Viche.AgentServer
  alias Viche.Message

  @typedoc "Lightweight agent map returned by list/discover functions."
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
    |> Enum.map(&format_agent/1)
  end

  @doc """
  Registers a new agent and starts its GenServer.

  ## Parameters
    - `%{capabilities: [...], name: "...", description: "..."}`

  `name` and `description` are optional; `capabilities` is required and must be
  a non-empty list.

  ## Returns
    - `{:ok, %Viche.Agent{}}` on success
    - `{:error, :capabilities_required}` when capabilities are missing or empty
  """
  @spec register_agent(map()) :: {:ok, Agent.t()} | {:error, :capabilities_required}
  def register_agent(%{capabilities: caps} = attrs)
      when is_list(caps) and caps != [] do
    agent_id = generate_unique_id()
    name = Map.get(attrs, :name)
    description = Map.get(attrs, :description)

    child_spec =
      {AgentServer, [id: agent_id, name: name, capabilities: caps, description: description]}

    {:ok, _pid} = DynamicSupervisor.start_child(Viche.AgentSupervisor, child_spec)

    via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
    agent = AgentServer.get_state(via)
    {:ok, agent}
  end

  def register_agent(_attrs), do: {:error, :capabilities_required}

  @doc """
  Discovers agents by capability or name.

  ## Parameters
    - `%{capability: "..."}` — find agents that have the given capability
    - `%{name: "..."}` — find agents with an exact name match

  ## Returns
    - `{:ok, [agent_info()]}` — list may be empty if no matches
    - `{:error, :query_required}` — when neither `:capability` nor `:name` is provided
  """
  @spec discover(map()) :: {:ok, [agent_info()]} | {:error, :query_required}
  def discover(%{capability: cap}) when is_binary(cap) and cap != "" do
    {:ok, find_by_capability(cap)}
  end

  def discover(%{name: name}) when is_binary(name) and name != "" do
    {:ok, find_by_name(name)}
  end

  def discover(_query), do: {:error, :query_required}

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec all_agents(atom()) :: [{String.t(), map()}]
  defp all_agents(registry) do
    Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
  end

  @spec find_by_capability(String.t()) :: [agent_info()]
  defp find_by_capability(capability) do
    for {id, meta} <- all_agents(Viche.AgentRegistry),
        capability in meta.capabilities do
      format_agent({id, meta})
    end
  end

  @spec find_by_name(String.t()) :: [agent_info()]
  defp find_by_name(name) do
    for {id, meta} <- all_agents(Viche.AgentRegistry),
        meta.name == name do
      format_agent({id, meta})
    end
  end

  @spec format_agent({String.t(), map()}) :: agent_info()
  defp format_agent({id, meta}) do
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
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    case Registry.lookup(Viche.AgentRegistry, id) do
      [] -> id
      _ -> generate_unique_id()
    end
  end

  @spec generate_message_id() :: String.t()
  defp generate_message_id do
    hex = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "msg-#{hex}"
  end
end
