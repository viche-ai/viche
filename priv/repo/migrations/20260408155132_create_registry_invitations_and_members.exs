defmodule Viche.Repo.Migrations.CreateRegistryInvitationsAndMembers do
  use Ecto.Migration

  def change do
    create table(:registry_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, default: "member", null: false

      add :registry_id, references(:registries, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:registry_members, [:registry_id])
    create index(:registry_members, [:user_id])
    create unique_index(:registry_members, [:registry_id, :user_id])

    create table(:registry_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :token, :string, null: false
      add :accepted_at, :utc_datetime_usec

      add :registry_id, references(:registries, type: :binary_id, on_delete: :delete_all),
        null: false

      add :invited_by_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:registry_invitations, [:registry_id])
    create index(:registry_invitations, [:email])
    create unique_index(:registry_invitations, [:token])
  end
end
