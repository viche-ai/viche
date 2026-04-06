defmodule Viche.Repo.Migrations.CreateRegistries do
  use Ecto.Migration

  def change do
    create table(:registries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :is_private, :boolean, default: true, null: false
      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:registries, [:owner_id])
    create index(:registries, [:slug], unique: true)
  end
end
