defmodule Viche.Agents.AgentRecord do
  @moduledoc """
  Ecto schema for persisting agent registrations to the database.

  This is the durable record that survives restarts. The in-memory
  `Viche.Agent` struct and `Viche.AgentServer` GenServer remain the
  source of truth for live state (inbox, connection_type, etc.).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "agents" do
    field :name, :string
    field :capabilities, {:array, :string}, default: []
    field :description, :string
    field :registries, {:array, :string}, default: ["global"]
    field :polling_timeout_ms, :integer, default: 60_000
    field :registered_at, :utc_datetime_usec
    field :deregistered_at, :utc_datetime_usec

    has_many :messages, Viche.Agents.MessageRecord, foreign_key: :agent_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(id capabilities registered_at)a
  @optional_fields ~w(name description registries polling_timeout_ms deregistered_at)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
