defmodule VicheWeb.RegistryController do
  @moduledoc """
  Handles agent registration in the Viche registry.
  """

  use VicheWeb, :controller

  alias Viche.AgentServer

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    capabilities = Map.get(params, "capabilities")

    if valid_capabilities?(capabilities) do
      agent_id = generate_unique_id()
      name = Map.get(params, "name")
      description = Map.get(params, "description")

      child_spec =
        {AgentServer,
         [
           id: agent_id,
           name: name,
           capabilities: capabilities,
           description: description
         ]}

      {:ok, _pid} = DynamicSupervisor.start_child(Viche.AgentSupervisor, child_spec)

      via = {:via, Registry, {Viche.AgentRegistry, agent_id}}
      agent = AgentServer.get_state(via)

      conn
      |> put_status(:created)
      |> json(%{
        id: agent.id,
        name: agent.name,
        capabilities: agent.capabilities,
        description: agent.description,
        inbox_url: "/inbox/#{agent.id}",
        registered_at: DateTime.to_iso8601(agent.registered_at)
      })
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "capabilities_required"})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec valid_capabilities?(term()) :: boolean()
  defp valid_capabilities?(capabilities) when is_list(capabilities) and capabilities != [],
    do: true

  defp valid_capabilities?(_), do: false

  @spec generate_unique_id() :: String.t()
  defp generate_unique_id do
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    case Registry.lookup(Viche.AgentRegistry, id) do
      [] -> id
      _ -> generate_unique_id()
    end
  end
end
