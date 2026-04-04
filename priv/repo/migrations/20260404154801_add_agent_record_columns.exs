defmodule Viche.Repo.Migrations.AddAgentRecordColumns do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add_if_not_exists :registries, {:array, :string}, default: ["global"]
      add_if_not_exists :polling_timeout_ms, :integer, default: 60_000
      add_if_not_exists :registered_at, :utc_datetime_usec
      add_if_not_exists :deregistered_at, :utc_datetime_usec
    end
  end
end
