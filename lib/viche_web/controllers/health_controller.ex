defmodule VicheWeb.HealthController do
  @moduledoc """
  Simple health check endpoint for load balancer and uptime monitoring.

  Returns a plain-text "ok" with HTTP 200 when the application is running.
  Intentionally has no authentication or database dependency so it stays
  fast and reliable under any conditions.
  """

  use VicheWeb, :controller

  @spec check(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def check(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
