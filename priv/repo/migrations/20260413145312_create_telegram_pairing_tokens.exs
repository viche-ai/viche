defmodule Viche.Repo.Migrations.CreateTelegramPairingTokens do
  use Ecto.Migration

  def change do
    create table(:telegram_pairing_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :uuid, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:telegram_pairing_tokens, [:token_hash])
    create index(:telegram_pairing_tokens, [:agent_id])
  end
end
