defmodule Viche.Repo.Migrations.CreateAuthTokens do
  use Ecto.Migration

  def change do
    create table(:auth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :context, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:auth_tokens, [:user_id])
    create unique_index(:auth_tokens, [:token_hash])
    create index(:auth_tokens, [:context])
  end
end
