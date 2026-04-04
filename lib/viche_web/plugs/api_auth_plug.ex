defmodule VicheWeb.ApiAuthPlug do
  @moduledoc """
  API authentication plug.

  Reads the `Authorization: Bearer <token>` header, validates the raw token
  against the `auth_tokens` table (context `"api"`), and assigns the resolved
  user and token record to `conn.assigns`.

  On success sets:
  - `conn.assigns.current_user`      — the `%Viche.Accounts.User{}` record
  - `conn.assigns.current_api_token` — the `%Viche.Accounts.AuthToken{}` record

  On failure returns `401` with a JSON error body and halts the pipeline.

  ## Legacy / self-hosted mode

  Setting `REQUIRE_AUTH=false` (or `REQUIRE_AUTH=0`) skips all auth checks.
  This is intended for self-hosted deployments and local development where auth
  is not yet configured.
  """

  import Plug.Conn

  alias Viche.Accounts
  alias Viche.Auth

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    if auth_required?() do
      authenticate(conn)
    else
      conn
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp authenticate(conn) do
    case extract_token(conn) do
      {:ok, raw_token} ->
        validate_token(conn, raw_token)

      :error ->
        unauthorized(conn, "Missing or malformed Authorization header. Expected: Bearer <token>")
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp validate_token(conn, raw_token) do
    case Auth.verify_api_token(raw_token) do
      {:ok, auth_token} ->
        user = Accounts.get_user_by_token_record(auth_token)

        conn
        |> assign(:current_user, user)
        |> assign(:current_api_token, auth_token)

      {:error, :invalid_token} ->
        unauthorized(conn, "Invalid or expired API token.")
    end
  end

  defp unauthorized(conn, message) do
    body = Jason.encode!(%{error: "unauthorized", message: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end

  # Checks whether authentication is enforced.
  #
  # Precedence (highest to lowest):
  #   1. Application config `:viche, :require_auth` (useful in tests / releases)
  #   2. `REQUIRE_AUTH` environment variable
  #   3. Default: `true`
  defp auth_required? do
    case Application.get_env(:viche, :require_auth, :not_set) do
      :not_set -> System.get_env("REQUIRE_AUTH", "true") not in ~w(false 0)
      value -> value
    end
  end
end
