# Script to apply fixes

# 1. Fix lib/viche/agents.ex
content = File.read!("lib/viche/agents.ex")

# Move import Ecto.Query to top
content =
  String.replace(content, "  alias Viche.Repo\n", "  alias Viche.Repo\n  import Ecto.Query\n")

content = String.replace(content, "    import Ecto.Query\n\n", "")

# Fix user_owns_agent?
old_user_owns = """
  def user_owns_agent?(nil, _agent_id), do: false

  def user_owns_agent?(user_id, agent_id) do
    case get_agent_record(agent_id) do
      nil -> true
      %AgentRecord{user_id: nil} -> true
      %AgentRecord{user_id: ^user_id} -> true
      _ -> false
    end
  end
"""

new_user_owns = """
  def user_owns_agent?(user_id, agent_id) do
    case get_agent_record(agent_id) do
      nil -> false
      %AgentRecord{user_id: nil} -> true
      %AgentRecord{user_id: ^user_id} -> true
      _ -> false
    end
  end
"""

content = String.replace(content, old_user_owns, new_user_owns)

# Fix require_auth?
old_require_auth = """
  def require_auth? do
    System.get_env("REQUIRE_AUTH") == "true"
  end
"""

new_require_auth = """
  def require_auth? do
    Application.get_env(:viche, :require_auth, false)
  end
"""

content = String.replace(content, old_require_auth, new_require_auth)

# Fix Repo.insert!
old_insert = """
    # Persist ownership record to database
    %AgentRecord{}
    |> AgentRecord.changeset(%{
      id: agent_id,
      name: name,
      capabilities: caps,
      description: description,
      user_id: user_id
    })
    |> Repo.insert!()

    child_opts = [
"""

new_insert = """
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

    with {:ok, _record} <- Repo.insert(changeset) do
      child_opts = [
"""

content = String.replace(content, old_insert, new_insert)

# Fix the end of start_agent
old_end_start_agent = """
    broadcast_agent_joined(agent)

    {:ok, agent}
  end
"""

new_end_start_agent = """
      broadcast_agent_joined(agent)

      {:ok, agent}
    else
      {:error, changeset} -> {:error, changeset}
    end
  end
"""

content = String.replace(content, old_end_start_agent, new_end_start_agent)

# Update spec for register_agent
old_spec = """
  @spec register_agent(map()) ::
          {:ok, Agent.t()}
          | {:error, :capabilities_required}
          | {:error, :invalid_capabilities}
          | {:error, :invalid_name}
          | {:error, :invalid_description}
          | {:error, :invalid_registry_token}
"""

new_spec = """
  @spec register_agent(map()) ::
          {:ok, Agent.t()}
          | {:error, :capabilities_required}
          | {:error, :invalid_capabilities}
          | {:error, :invalid_name}
          | {:error, :invalid_description}
          | {:error, :invalid_registry_token}
          | {:error, Ecto.Changeset.t()}
"""

content = String.replace(content, old_spec, new_spec)

File.write!("lib/viche/agents.ex", content)

# 2. Fix lib/viche_web/controllers/inbox_controller.ex
content = File.read!("lib/viche_web/controllers/inbox_controller.ex")

content =
  String.replace(
    content,
    "not is_nil(user_id) and not Agents.user_owns_agent?(user_id, agent_id)",
    "not Agents.user_owns_agent?(user_id, agent_id)"
  )

File.write!("lib/viche_web/controllers/inbox_controller.ex", content)

# 3. Fix lib/viche_web/controllers/registry_controller.ex
content = File.read!("lib/viche_web/controllers/registry_controller.ex")

content =
  String.replace(
    content,
    "not is_nil(user_id) and not Agents.user_owns_agent?(user_id, agent_id)",
    "not Agents.user_owns_agent?(user_id, agent_id)"
  )

File.write!("lib/viche_web/controllers/registry_controller.ex", content)

# 4. Fix config/runtime.exs
content = File.read!("config/runtime.exs")

new_config = """
config :viche, VicheWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :viche, require_auth: System.get_env("REQUIRE_AUTH") == "true"
"""

content =
  String.replace(
    content,
    "config :viche, VicheWeb.Endpoint, http: [port: String.to_integer(System.get_env(\"PORT\", \"4000\"))]\n",
    new_config
  )

File.write!("config/runtime.exs", content)

# 5. Fix lib/viche_web/live/dashboard_live.ex
content = File.read!("lib/viche_web/live/dashboard_live.ex")

old_dashboard = """
    # Filter to show only the current user's agents on the dashboard.
    # When not logged in, show only claimed agents (user_id IS NOT NULL).
    user_id = socket.assigns[:current_user_id]

    owned_ids =
      if user_id, do: MapSet.new(Viche.Agents.list_agent_ids_for_user(user_id)), else: nil

    claimed_ids = MapSet.new(Viche.Agents.list_claimed_agent_ids())

    agents =
      if user_id do
        Enum.filter(all_agents, &MapSet.member?(owned_ids, &1.id))
      else
        Enum.filter(all_agents, &MapSet.member?(claimed_ids, &1.id))
      end

    metrics_agents =
      if socket.assigns.public_mode do
        agents
      else
        all_unfiltered = Viche.Agents.list_agents_with_status(:all)

        if user_id do
          Enum.filter(all_unfiltered, &MapSet.member?(owned_ids, &1.id))
        else
          Enum.filter(all_unfiltered, &MapSet.member?(claimed_ids, &1.id))
        end
      end
"""

new_dashboard = """
    # Filter to show only the current user's agents on the dashboard.
    # When not logged in, show only claimed agents (user_id IS NOT NULL).
    user_id = socket.assigns[:current_user_id]

    allowed_ids =
      if user_id do
        MapSet.new(Viche.Agents.list_agent_ids_for_user(user_id))
      else
        MapSet.new(Viche.Agents.list_claimed_agent_ids())
      end

    agents = Enum.filter(all_agents, &MapSet.member?(allowed_ids, &1.id))

    metrics_agents =
      if socket.assigns.public_mode do
        agents
      else
        all_unfiltered = Viche.Agents.list_agents_with_status(:all)
        Enum.filter(all_unfiltered, &MapSet.member?(allowed_ids, &1.id))
      end
"""

content = String.replace(content, old_dashboard, new_dashboard)
File.write!("lib/viche_web/live/dashboard_live.ex", content)

IO.puts("Fixes applied")
