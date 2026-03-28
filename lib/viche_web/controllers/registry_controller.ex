defmodule VicheWeb.RegistryController do
  @moduledoc """
  Handles agent registration and discovery in the Viche registry.

  Thin HTTP adapter — all business logic lives in `Viche.Agents`.
  """

  use VicheWeb, :controller

  alias Viche.Agents

  @min_polling_timeout_ms 5_000

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    polling_timeout_ms = Map.get(params, "polling_timeout_ms")
    registries = Map.get(params, "registries")

    with :ok <- validate_polling_timeout(polling_timeout_ms),
         attrs = %{
           capabilities: Map.get(params, "capabilities"),
           name: Map.get(params, "name"),
           description: Map.get(params, "description"),
           polling_timeout_ms: polling_timeout_ms,
           registries: registries
         },
         {:ok, agent} <- Agents.register_agent(attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        id: agent.id,
        name: agent.name,
        capabilities: agent.capabilities,
        description: agent.description,
        registries: agent.registries,
        inbox_url: "/inbox/#{agent.id}",
        registered_at: DateTime.to_iso8601(agent.registered_at),
        polling_timeout_ms: agent.polling_timeout_ms
      })
    else
      {:error, :invalid_polling_timeout} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_polling_timeout"})

      {:error, :capabilities_required} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "capabilities_required"})

      {:error, :invalid_capabilities} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_capabilities"})

      {:error, :invalid_name} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_name"})

      {:error, :invalid_description} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_description"})

      {:error, :invalid_registry_token} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_registry_token"})
    end
  end

  @spec discover(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def discover(conn, params) do
    query = build_discover_query(params)

    case Agents.discover(query) do
      {:ok, agents} ->
        json(conn, %{agents: agents})

      {:error, :query_required} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "query_required",
          message: "Provide ?capability= or ?name= parameter"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec validate_polling_timeout(nil | integer() | term()) ::
          :ok | {:error, :invalid_polling_timeout}
  defp validate_polling_timeout(nil), do: :ok

  defp validate_polling_timeout(ms) when is_integer(ms) and ms >= @min_polling_timeout_ms,
    do: :ok

  defp validate_polling_timeout(_), do: {:error, :invalid_polling_timeout}

  @spec build_discover_query(map()) :: map()
  defp build_discover_query(params) do
    base =
      cond do
        cap = params["capability"] -> %{capability: cap}
        name = params["name"] -> %{name: name}
        true -> %{}
      end

    # "registry" takes precedence over "token" (legacy alias)
    registry = params["registry"] || params["token"]

    if registry, do: Map.put(base, :registry, registry), else: base
  end
end
