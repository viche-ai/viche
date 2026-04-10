defmodule Viche.Repo.Migrations.CreateTelemetryTables do
  use Ecto.Migration

  def change do
    # Single-row table storing an anonymous instance UUID.
    # Generated once on first boot, never changes.
    create table(:instance_info, primary_key: false) do
      add :instance_id, :uuid, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Stores telemetry reports received from self-hosted instances.
    # payload is a JSONB column so we can evolve the schema without migrations.
    create table(:telemetry_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :instance_id, :uuid, null: false
      add :payload, :map, null: false, default: %{}
      add :reported_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:telemetry_reports, [:instance_id])
    create index(:telemetry_reports, [:reported_at])
  end
end
