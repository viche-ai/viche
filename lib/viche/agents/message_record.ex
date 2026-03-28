defmodule Viche.Agents.MessageRecord do
  @moduledoc """
  Ecto schema for persisting messages to the database.

  Messages are written on send and read only during boot restoration
  to reload undelivered messages into agent inboxes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "messages" do
    field :type, :string, default: "task"
    field :from, :string
    field :body, :string
    field :sent_at, :utc_datetime_usec
    field :delivered, :boolean, default: false

    belongs_to :agent, Viche.Agents.AgentRecord, type: :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields ~w(id type from body sent_at agent_id)a
  @optional_fields ~w(delivered)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:agent_id)
  end
end
