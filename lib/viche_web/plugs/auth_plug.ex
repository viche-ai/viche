defmodule VicheWeb.AuthPlug do
  @moduledoc """
  Browser authentication plug.

  Reads `user_id` from the session, loads the corresponding user, and assigns
  it to `conn.assigns.current_user`. If no valid session is present the
  connection is halted and the browser is redirected to `/auth/login`.

  ## Legacy / self-hosted mode

  Setting the `REQUIRE_AUTH` environment variable to `"false"` (or `"0"`)
  skips all authentication checks. This is intended for self-hosted deployments
  and local development where auth is not yet configured.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  alias Viche.Accounts.User
  alias Viche.Repo

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
    case get_session(conn, :user_id) do
      nil ->
        halt_and_redirect(conn)

      user_id ->
        case Repo.get(User, user_id) do
          nil ->
            halt_and_redirect(conn)

          user ->
            assign(conn, :current_user, user)
        end
    end
  end

  defp halt_and_redirect(conn) do
    conn
    |> put_flash(:error, "You must be logged in to access this page.")
    |> redirect(to: "/auth/login")
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
