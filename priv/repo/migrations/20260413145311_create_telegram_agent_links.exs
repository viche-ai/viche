defmodule Viche.Repo.Migrations.CreateTelegramAgentLinks do
  use Ecto.Migration

  def change do
    create table(:telegram_agent_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :uuid, on_delete: :delete_all), null: false
      add :bot_id, :bigint, null: false
      add :telegram_user_id, :bigint, null: false
      add :chat_id, :bigint, null: false
      add :telegram_username, :string
      add :telegram_name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:telegram_agent_links, [:agent_id])
    create unique_index(:telegram_agent_links, [:bot_id, :telegram_user_id])
    create index(:telegram_agent_links, [:chat_id])
  end
end
