defmodule Viche.Repo.Migrations.CastAgentIdToUuid do
  use Ecto.Migration

  def up do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'messages') THEN ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_agent_id_fkey; ALTER TABLE messages ALTER COLUMN agent_id TYPE uuid USING agent_id::uuid; END IF; END $$"
    )

    execute("ALTER TABLE agents ALTER COLUMN id TYPE uuid USING id::uuid")

    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'messages') THEN ALTER TABLE messages ADD CONSTRAINT messages_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE; END IF; END $$"
    )
  end

  def down do
    execute(
      "ALTER TABLE agents ALTER COLUMN id TYPE character varying(255) USING id::character varying"
    )

    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'messages') THEN ALTER TABLE messages ALTER COLUMN agent_id TYPE character varying(255) USING agent_id::character varying; END IF; END $$"
    )
  end
end
