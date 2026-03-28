defmodule Viche.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string
      add :capabilities, {:array, :string}, null: false, default: []
      add :description, :text
      add :registries, {:array, :string}, null: false, default: ["global"]
      add :polling_timeout_ms, :integer, null: false, default: 60_000
      add :registered_at, :utc_datetime_usec, null: false
      add :deregistered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agents, [:deregistered_at])
    create index(:agents, [:registries], using: :gin)
  end
end
