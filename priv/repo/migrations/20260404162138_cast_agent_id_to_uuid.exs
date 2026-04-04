defmodule Viche.Repo.Migrations.CastAgentIdToUuid do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE agents ALTER COLUMN id TYPE uuid USING id::uuid")
  end

  def down do
    execute("ALTER TABLE agents ALTER COLUMN id TYPE character varying(255) USING id::character varying")
  end
end
