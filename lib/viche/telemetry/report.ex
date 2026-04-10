defmodule Viche.Telemetry.Report do
  @moduledoc """
  Schema for telemetry reports received from self-hosted Viche instances.

  The `payload` column is a JSONB map, allowing the telemetry shape to evolve
  without requiring database migrations.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: binary() | nil,
          instance_id: Ecto.UUID.t() | nil,
          payload: map(),
          reported_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "telemetry_reports" do
    field :instance_id, Ecto.UUID
    field :payload, :map, default: %{}
    field :reported_at, :utc_datetime_usec

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:instance_id, :payload, :reported_at])
    |> validate_required([:instance_id, :payload, :reported_at])
  end
end
