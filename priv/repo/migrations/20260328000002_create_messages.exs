defmodule Viche.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :string, primary_key: true
      add :type, :string, null: false, default: "task"
      add :from, :string, null: false
      add :body, :text, null: false
      add :sent_at, :utc_datetime_usec, null: false
      add :delivered, :boolean, null: false, default: false
      add :agent_id, references(:agents, type: :string, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:messages, [:agent_id])
    create index(:messages, [:agent_id, :delivered])
  end
end
