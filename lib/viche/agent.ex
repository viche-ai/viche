defmodule Viche.Agent do
  @moduledoc """
  Data model for a registered agent in the Viche registry.

  An agent is an autonomous process identified by a unique 8-character hex ID,
  supervised by `Viche.AgentSupervisor`, and registered in `Viche.AgentRegistry`.
  """

  @type connection_type :: :websocket | :long_poll

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          capabilities: [String.t()],
          description: String.t() | nil,
          inbox: list(),
          registered_at: DateTime.t(),
          connection_type: connection_type(),
          last_activity: DateTime.t() | nil,
          polling_timeout_ms: pos_integer()
        }

  @default_polling_timeout_ms 60_000

  defstruct [
    :id,
    :name,
    :capabilities,
    :description,
    :registered_at,
    inbox: [],
    connection_type: :long_poll,
    last_activity: nil,
    polling_timeout_ms: @default_polling_timeout_ms
  ]
end
