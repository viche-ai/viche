defmodule Viche.Agent do
  @moduledoc """
  Data model for a registered agent in the Viche registry.

  An agent is an autonomous process identified by a unique 8-character hex ID,
  supervised by `Viche.AgentSupervisor`, and registered in `Viche.AgentRegistry`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          capabilities: [String.t()],
          description: String.t() | nil,
          inbox: list(),
          registered_at: DateTime.t()
        }

  defstruct [:id, :name, :capabilities, :description, :registered_at, inbox: []]
end
