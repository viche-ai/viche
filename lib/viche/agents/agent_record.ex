defmodule Viche.Agents.AgentRecord do
  @moduledoc """
  Ecto schema for the agents table.

  Persists agent ownership so that agents can be tied to a user account.
  The in-memory `Viche.Agent` struct and its GenServer remain the source of
  truth for runtime state (inbox, connection_type, etc.); this record only
  tracks the durable ownership mapping.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary() | nil,
          name: String.t() | nil,
          capabilities: [String.t()],
          description: String.t() | nil,
          registries: [String.t()],
          polling_timeout_ms: integer(),
          registered_at: DateTime.t() | nil,
          deregistered_at: DateTime.t() | nil,
          user_id: binary() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agents" do
    field :name, :string
    field :capabilities, {:array, :string}, default: []
    field :description, :string
    field :registries, {:array, :string}, default: ["global"]
    field :polling_timeout_ms, :integer, default: 60_000
    field :registered_at, :utc_datetime_usec
    field :deregistered_at, :utc_datetime_usec

    belongs_to :user, Viche.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :name,
      :capabilities,
      :description,
      :registries,
      :polling_timeout_ms,
      :registered_at,
      :deregistered_at,
      :user_id
    ])
    |> validate_required([:id, :capabilities, :registries, :polling_timeout_ms, :registered_at])
    |> foreign_key_constraint(:user_id)
  end
end
