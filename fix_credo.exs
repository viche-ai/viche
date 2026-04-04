# 1. Fix agents.ex
content = File.read!("lib/viche/agents.ex")

old_with = """
    with {:ok, _record} <- Repo.insert(changeset) do
      child_opts = [
        id: agent_id,
        name: name,
        capabilities: caps,
        description: description,
        registries: registries
      ]

      child_opts =
        if polling_timeout_ms,
          do: Keyword.put(child_opts, :polling_timeout_ms, polling_timeout_ms),
          else: child_opts

      child_opts =
        if grace_period_ms,
          do: Keyword.put(child_opts, :grace_period_ms, grace_period_ms),
          else: child_opts

      child_spec = {AgentServer, child_opts}
      {:ok, _pid} = DynamicSupervisor.start_child(Viche.AgentSupervisor, child_spec)

      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      agent = AgentServer.get_state(via)

      Logger.info(
        "Agent \#{agent.id} registered (name: \#{inspect(agent.name)}, " <>
          "capabilities: \#{inspect(agent.capabilities)}, " <>
          "registries: \#{inspect(agent.registries)}, " <>
          "polling_timeout: \#{agent.polling_timeout_ms}ms)"
      )

      broadcast_agent_joined(agent)

      {:ok, agent}
    else
      {:error, changeset} -> {:error, changeset}
    end
"""

new_case = """
    case Repo.insert(changeset) do
      {:ok, _record} ->
        child_opts = [
          id: agent_id,
          name: name,
          capabilities: caps,
          description: description,
          registries: registries
        ]

        child_opts =
          if polling_timeout_ms,
            do: Keyword.put(child_opts, :polling_timeout_ms, polling_timeout_ms),
            else: child_opts

        child_opts =
          if grace_period_ms,
            do: Keyword.put(child_opts, :grace_period_ms, grace_period_ms),
            else: child_opts

        child_spec = {AgentServer, child_opts}
        {:ok, _pid} = DynamicSupervisor.start_child(Viche.AgentSupervisor, child_spec)

        via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
        agent = AgentServer.get_state(via)

        Logger.info(
          "Agent \#{agent.id} registered (name: \#{inspect(agent.name)}, " <>
            "capabilities: \#{inspect(agent.capabilities)}, " <>
            "registries: \#{inspect(agent.registries)}, " <>
            "polling_timeout: \#{agent.polling_timeout_ms}ms)"
        )

        broadcast_agent_joined(agent)

        {:ok, agent}

      {:error, changeset} ->
        {:error, changeset}
    end
"""

content = String.replace(content, old_with, new_case)
File.write!("lib/viche/agents.ex", content)

# 2. Fix InboxController
content = File.read!("lib/viche_web/controllers/inbox_controller.ex")

new_inbox = """
  @spec read_inbox(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def read_inbox(conn, %{"agent_id" => agent_id}) do
    user_id = conn.assigns[:current_user_id]

    if Agents.require_auth?() and is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "authentication_required"})
    else
      handle_read_inbox(conn, user_id, agent_id)
    end
  end

  defp handle_read_inbox(conn, user_id, agent_id) do
    case Agents.user_owns_agent?(user_id, agent_id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "agent_not_found"})

      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "not_owner"})

      true ->
        case Agents.drain_inbox(agent_id) do
          {:ok, messages} ->
            conn
            |> put_status(:ok)
            |> json(%{messages: Enum.map(messages, &serialize_message/1)})

          {:error, :agent_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "agent_not_found"})
        end
    end
  end
"""

content = String.replace(content, ~r/@spec read_inbox.*?end\n  end/s, new_inbox)
File.write!("lib/viche_web/controllers/inbox_controller.ex", content)

# 3. Fix RegistryController
content = File.read!("lib/viche_web/controllers/registry_controller.ex")

new_registry = """
  @spec deregister(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deregister(conn, %{"agent_id" => agent_id}) do
    user_id = conn.assigns[:current_user_id]

    if Agents.require_auth?() and is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "authentication_required"})
    else
      handle_deregister(conn, user_id, agent_id)
    end
  end

  defp handle_deregister(conn, user_id, agent_id) do
    case Agents.user_owns_agent?(user_id, agent_id) do
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "agent_not_found"})

      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "not_owner"})

      true ->
        case Agents.deregister(agent_id) do
          :ok ->
            json(conn, %{deregistered: true})

          {:error, :agent_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "agent_not_found"})
        end
    end
  end
"""

content = String.replace(content, ~r/@spec deregister.*?end\n  end/s, new_registry)
File.write!("lib/viche_web/controllers/registry_controller.ex", content)

IO.puts("Credo fixes applied")
