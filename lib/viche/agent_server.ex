defmodule Viche.AgentServer do
  @moduledoc """
  GenServer representing a single registered agent.

  State is `%Viche.Agent{}`. Registered in `Viche.AgentRegistry` via a `:via` tuple,
  with agent metadata (name, capabilities, description) stored as the Registry value
  for efficient discovery.
  """

  use GenServer

  alias Viche.Agent

  @type start_opts :: [
          id: String.t(),
          name: String.t() | nil,
          capabilities: [String.t()],
          description: String.t() | nil
        ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name)
    capabilities = Keyword.get(opts, :capabilities, [])
    description = Keyword.get(opts, :description)

    meta = %{name: name, capabilities: capabilities, description: description}
    via = {:via, Registry, {Viche.AgentRegistry, agent_id, meta}}

    GenServer.start_link(__MODULE__, opts, name: via)
  end

  @spec get_state(GenServer.server()) :: Agent.t()
  def get_state(server) do
    GenServer.call(server, :get_state)
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

    agent = %Agent{
      id: agent_id,
      name: name,
      capabilities: capabilities,
      description: description,
      inbox: [],
      registered_at: DateTime.utc_now()
    }

    {:ok, agent}
  end

  @impl GenServer
  def handle_call(:get_state, _from, agent) do
    {:reply, agent, agent}
  end
end
