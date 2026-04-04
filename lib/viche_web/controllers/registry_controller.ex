defmodule VicheWeb.RegistryController do
  @moduledoc """
  Handles agent registration and discovery in the Viche registry.

  Thin HTTP adapter — all business logic lives in `Viche.Agents`.
  """

  use VicheWeb, :controller

  alias Viche.Agents

  @min_polling_timeout_ms 5_000
  @min_grace_period_ms 1_000

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    user_id = conn.assigns[:current_user_id]

    if Agents.require_auth?() and is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "authentication_required"})
    else
      do_register(conn, params, user_id)
    end
  end

  defp do_register(conn, params, user_id) do
    polling_timeout_ms = Map.get(params, "polling_timeout_ms")
    grace_period_ms = Map.get(params, "grace_period_ms")
    registries = Map.get(params, "registries")

    with :ok <- validate_polling_timeout(polling_timeout_ms),
         :ok <- validate_grace_period(grace_period_ms),
         attrs = %{
           capabilities: Map.get(params, "capabilities"),
           name: Map.get(params, "name"),
           description: Map.get(params, "description"),
           polling_timeout_ms: polling_timeout_ms,
           grace_period_ms: grace_period_ms,
           registries: registries,
           user_id: user_id
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
        polling_timeout_ms: agent.polling_timeout_ms,
        grace_period_ms: agent.grace_period_ms
      })
    else
      {:error, :invalid_polling_timeout} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_polling_timeout"})

      {:error, :invalid_grace_period} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_grace_period"})

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

  @spec discover(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def discover(conn, params) do
    token = params["registry"] || params["token"]

    case validate_discover_token(token) do
      {:error, :invalid_token} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_token",
          details: "Token must be 4-256 characters, alphanumeric with . _ -"
        })

      :ok ->
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

  @spec validate_grace_period(nil | integer() | term()) ::
          :ok | {:error, :invalid_grace_period}
  defp validate_grace_period(nil), do: :ok

  defp validate_grace_period(ms) when is_integer(ms) and ms >= @min_grace_period_ms,
    do: :ok

  defp validate_grace_period(_), do: {:error, :invalid_grace_period}

  @spec validate_discover_token(nil | String.t()) ::
          :ok | {:error, :invalid_token}
  defp validate_discover_token(nil), do: :ok

  defp validate_discover_token(token) do
    if Agents.valid_token?(token) do
      :ok
    else
      {:error, :invalid_token}
    end
  end

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
