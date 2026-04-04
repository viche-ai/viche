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
          user_id: binary() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agents" do
    field :name, :string
    field :capabilities, {:array, :string}, default: []
    field :description, :string

    belongs_to :user, Viche.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:id, :name, :capabilities, :description, :user_id])
    |> validate_required([:id, :capabilities])
    |> foreign_key_constraint(:user_id)
  end
end
