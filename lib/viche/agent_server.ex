defmodule Viche.AgentServer do
  @moduledoc """
  GenServer representing a single registered agent.

  State is `{%Viche.Agent{}, meta}` where `meta` holds internal timer references
  (`grace_timer_ref`). Registered in `Viche.AgentRegistry` via a `:via` tuple,
  with agent metadata (name, capabilities, description) stored as the Registry value
  for efficient discovery.

  ## Deregistration modes

  - **WebSocket grace period**: When an agent's channel disconnects, a grace timer
    fires `:deregister_grace_expired` after `grace_period_ms`. A reconnect within
    that window cancels the timer.
  - **Long-poll inactivity**: Agents that haven't drained their inbox within
    `polling_timeout_ms` milliseconds are stopped automatically.
  """

  use GenServer

  require Logger

  alias Viche.Agent
  alias Viche.Message

  @type start_opts :: [
          id: String.t(),
          name: String.t() | nil,
          capabilities: [String.t()],
          description: String.t() | nil,
          registries: [String.t()] | nil,
          polling_timeout_ms: pos_integer() | nil,
          inbox: [Message.t()],
          registered_at: DateTime.t() | nil
        ]

  # Never restart — dynamic agents re-register with a new ID on crash
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name)
    capabilities = Keyword.get(opts, :capabilities, [])
    description = Keyword.get(opts, :description)
    registries = Keyword.get(opts, :registries, ["global"])

    meta = %{
      name: name,
      capabilities: capabilities,
      description: description,
      registries: registries
    }

    via = {:via, Registry, {Viche.AgentRegistry, agent_id, meta}}

    GenServer.start_link(__MODULE__, opts, name: via)
  end

  @spec get_state(GenServer.server()) :: Agent.t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @spec receive_message(GenServer.server(), Message.t()) :: :ok
  def receive_message(server, %Message{} = message) do
    GenServer.call(server, {:receive_message, message})
  end

  @spec drain_inbox(GenServer.server()) :: [Message.t()]
  def drain_inbox(server) do
    GenServer.call(server, :drain_inbox)
  end

  @spec inspect_inbox(GenServer.server()) :: [Message.t()]
  def inspect_inbox(server) do
    GenServer.call(server, :inspect_inbox)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name)
    capabilities = Keyword.get(opts, :capabilities, [])
    description = Keyword.get(opts, :description)
    registries = Keyword.get(opts, :registries, ["global"])
    polling_timeout_ms = Keyword.get(opts, :polling_timeout_ms, 60_000)
    inbox = Keyword.get(opts, :inbox, [])

    registered_at = Keyword.get(opts, :registered_at) || DateTime.utc_now()

    agent = %Agent{
      id: agent_id,
      name: name,
      capabilities: capabilities,
      description: description,
      registries: registries,
      inbox: inbox,
      registered_at: registered_at,
      last_activity: registered_at,
      polling_timeout_ms: polling_timeout_ms
    }

    Process.send_after(self(), :check_polling_timeout, polling_timeout_ms)

    Logger.info(
      "AgentServer started for #{agent_id} " <>
        "(connection_type: #{agent.connection_type}, polling_timeout: #{polling_timeout_ms}ms)"
    )

    {:ok, {agent, %{grace_timer_ref: nil}}}
  end

  @impl GenServer
  def handle_call(:get_state, _from, {%Agent{} = agent, meta}) do
    {:reply, agent, {agent, meta}}
  end

  @impl GenServer
  def handle_call({:receive_message, %Message{} = message}, _from, {%Agent{} = agent, meta}) do
    updated = %Agent{agent | inbox: agent.inbox ++ [message]}
    {:reply, :ok, {updated, meta}}
  end

  @impl GenServer
  def handle_call(:drain_inbox, _from, {%Agent{inbox: inbox} = agent, meta}) do
    updated = %Agent{agent | inbox: [], last_activity: DateTime.utc_now()}
    reschedule_polling_timeout(updated)
    Logger.debug("Agent #{agent.id} inbox drained, last_activity updated")
    {:reply, inbox, {updated, meta}}
  end

  @impl GenServer
  def handle_call(:inspect_inbox, _from, {%Agent{inbox: inbox} = agent, meta}) do
    {:reply, inbox, {agent, meta}}
  end

  @impl GenServer
  def handle_info(:websocket_connected, {%Agent{} = agent, %{grace_timer_ref: ref} = meta}) do
    cancel_grace_timer(ref)
    updated_agent = %Agent{agent | connection_type: :websocket}

    if ref do
      Logger.info("Agent #{agent.id} WebSocket connected, grace timer cancelled")
    else
      Logger.info("Agent #{agent.id} WebSocket connected")
    end

    {:noreply, {updated_agent, %{meta | grace_timer_ref: nil}}}
  end

  @impl GenServer
  def handle_info(:websocket_disconnected, {%Agent{} = agent, meta}) do
    grace_ms = grace_period_ms()
    ref = Process.send_after(self(), :deregister_grace_expired, grace_ms)
    Logger.debug("Agent #{agent.id} WebSocket disconnected, grace period started (#{grace_ms}ms)")
    {:noreply, {agent, %{meta | grace_timer_ref: ref}}}
  end

  @impl GenServer
  def handle_info(:deregister_grace_expired, {%Agent{} = agent, meta}) do
    # Returning {:stop, :normal} terminates the process cleanly.
    # The :via Registry entry is automatically removed on process exit.
    # The DynamicSupervisor records the child as stopped (restart: :temporary means no restart).
    Logger.info("Agent #{agent.id} grace period expired, deregistering")
    {:stop, :normal, {agent, meta}}
  end

  @impl GenServer
  def handle_info(:check_polling_timeout, {%Agent{connection_type: :websocket} = agent, meta}) do
    # WebSocket agents use the grace period mechanism instead of polling timeout
    {:noreply, {agent, meta}}
  end

  @impl GenServer
  def handle_info(:check_polling_timeout, {%Agent{} = agent, meta}) do
    elapsed = DateTime.diff(DateTime.utc_now(), agent.last_activity, :millisecond)
    remaining = agent.polling_timeout_ms - elapsed

    if remaining <= 0 do
      Logger.info("Agent #{agent.id} polling timeout fired, deregistering")
      {:stop, :normal, {agent, meta}}
    else
      Logger.debug("Agent #{agent.id} polling timeout check, #{remaining}ms remaining")
      Process.send_after(self(), :check_polling_timeout, remaining)
      {:noreply, {agent, meta}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec reschedule_polling_timeout(Agent.t()) :: reference() | :ok
  defp reschedule_polling_timeout(%Agent{
         connection_type: :long_poll,
         polling_timeout_ms: timeout
       }) do
    Process.send_after(self(), :check_polling_timeout, timeout)
  end

  defp reschedule_polling_timeout(_agent), do: :ok

  # Cancels a grace period timer ref and flushes any stale :deregister_grace_expired
  # message that may have already been delivered to the mailbox before cancel ran.
  # Without the flush, a reconnect arriving just as the timer fires would still
  # process the stale message and kill a live agent.
  @spec cancel_grace_timer(reference() | nil) :: :ok
  defp cancel_grace_timer(nil), do: :ok

  defp cancel_grace_timer(ref) do
    if Process.cancel_timer(ref) == false do
      receive do
        :deregister_grace_expired -> :ok
      after
        0 -> :ok
      end
    end

    :ok
  end

  @spec grace_period_ms() :: pos_integer()
  defp grace_period_ms, do: Application.get_env(:viche, :grace_period_ms, 5_000)
end
