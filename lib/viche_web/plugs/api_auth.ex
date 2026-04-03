defmodule VicheWeb.Plugs.ApiAuth do
  @moduledoc """
  Plug that optionally extracts the current user from a Bearer API token.

  If a valid `Authorization: Bearer <token>` header is present, the plug
  assigns `:current_user_id` on the connection. If the header is absent or
  the token is invalid, `:current_user_id` is set to `nil`.

  This plug never halts the connection — downstream controllers decide
  whether authentication is required based on `REQUIRE_AUTH` and the
  specific endpoint's scoping rules.
  """

  import Plug.Conn

  alias Viche.Auth

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_bearer_token(conn) do
      nil ->
        assign(conn, :current_user_id, nil)

      raw_token ->
        case Auth.verify_api_token(raw_token) do
          {:ok, auth_token} ->
            assign(conn, :current_user_id, auth_token.user_id)

          {:error, :invalid_token} ->
            assign(conn, :current_user_id, nil)
        end
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end
end
