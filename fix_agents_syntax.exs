content = File.read!("lib/viche/agents.ex")

old_start_agent = """
  defp start_agent(attrs, caps, registries) do
    name = Map.get(attrs, :name)
    description = Map.get(attrs, :description)
    polling_timeout_ms = Map.get(attrs, :polling_timeout_ms)
    grace_period_ms = Map.get(attrs, :grace_period_ms)
    owner_id = Map.get(attrs, :owner_id)
    agent_id = generate_unique_id()

    # Persist ownership record to database
    changeset =
      %AgentRecord{}
      |> AgentRecord.changeset(%{
        id: agent_id,
        name: name,
        capabilities: caps,
        description: description,
        user_id: owner_id
      })

    case Repo.insert(changeset) do
      {:ok, _record} ->
        child_opts = [
          id: agent_id,
          name: name,
          capabilities: caps,
          description: description,
          registries: registries,
          owner_id: owner_id
        ]
    user_id = Map.get(attrs, :user_id)
    agent_id = generate_unique_id()

    # Persist ownership record to database
    changeset =
      %AgentRecord{}
      |> AgentRecord.changeset(%{
        id: agent_id,
        name: name,
        capabilities: caps,
        description: description,
        user_id: user_id
      })

    case Repo.insert(changeset) do
      {:ok, _record} ->
        child_opts = [
          id: agent_id,
          name: name,
          capabilities: caps,
          description: description,
          registries: registries
        ]
"""

new_start_agent = """
  defp start_agent(attrs, caps, registries) do
    name = Map.get(attrs, :name)
    description = Map.get(attrs, :description)
    polling_timeout_ms = Map.get(attrs, :polling_timeout_ms)
    grace_period_ms = Map.get(attrs, :grace_period_ms)
    # The fix for #21 introduces `owner_id` (so we should respect it), and #47 uses `user_id`.
    # Let's use `user_id` as the primary, and fallback to `owner_id` from #21 if present.
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, :owner_id)
    agent_id = generate_unique_id()

    # Persist ownership record to database
    changeset =
      %AgentRecord{}
      |> AgentRecord.changeset(%{
        id: agent_id,
        name: name,
        capabilities: caps,
        description: description,
        user_id: user_id
      })

    case Repo.insert(changeset) do
      {:ok, _record} ->
        child_opts = [
          id: agent_id,
          name: name,
          capabilities: caps,
          description: description,
          registries: registries,
          owner_id: user_id
        ]
"""

content = String.replace(content, old_start_agent, new_start_agent)
File.write!("lib/viche/agents.ex", content)
