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

    case validate_polling_timeout(polling_timeout_ms) do
      {:error, :invalid_polling_timeout} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_polling_timeout"})

      :ok ->
        attrs = %{
          capabilities: Map.get(params, "capabilities"),
          name: Map.get(params, "name"),
          description: Map.get(params, "description"),
          polling_timeout_ms: polling_timeout_ms
        }

        case Agents.register_agent(attrs) do
          {:ok, agent} ->
            conn
            |> put_status(:created)
            |> json(%{
              id: agent.id,
              name: agent.name,
              capabilities: agent.capabilities,
              description: agent.description,
              inbox_url: "/inbox/#{agent.id}",
              registered_at: DateTime.to_iso8601(agent.registered_at),
              polling_timeout_ms: agent.polling_timeout_ms
            })

          {:error, :capabilities_required} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "capabilities_required"})
        end
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
    cond do
      cap = params["capability"] -> %{capability: cap}
      name = params["name"] -> %{name: name}
      true -> %{}
    end
  end
end
