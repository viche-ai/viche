defmodule VicheWeb.HeartbeatController do
  @moduledoc """
  Handles agent heartbeat requests.

  A heartbeat resets the agent's `last_activity` timestamp and polling timeout
  timer without consuming messages. Useful for keeping idle long-poll agents alive.

  Thin HTTP adapter — all business logic lives in `Viche.Agents`.
  """

  use VicheWeb, :controller

  alias Viche.Agents

  @spec heartbeat(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def heartbeat(conn, %{"agent_id" => agent_id}) do
    case Agents.heartbeat(agent_id) do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok"})

      {:error, :agent_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "agent_not_found", message: "no agent found with the given ID"})
    end
  end
end
