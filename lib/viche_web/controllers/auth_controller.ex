defmodule VicheWeb.AuthController do
  use VicheWeb, :controller

  alias Viche.Accounts
  alias Viche.Auth

  @doc """
  POST /auth/login — accepts `%{"email" => email}`, sends a magic link,
  and returns 200 regardless of whether the email exists (to prevent enumeration).
  """
  def login(conn, %{"email" => email}) do
    Auth.send_magic_link(email)

    conn
    |> put_status(:ok)
    |> json(%{message: "If that email is registered, a login link has been sent."})
  end

  def login(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "email is required"})
  end

  @doc """
  GET /auth/confirm?token=<raw_token> — consumes the magic link token,
  sets the user_id in the session, and redirects to the dashboard.

  Called by VerifyLive after the verification animation completes.
  """
  def confirm(conn, %{"token" => raw_token}) do
    case Auth.verify_magic_link_token(raw_token) do
      {:ok, auth_token} ->
        user = Accounts.get_user_by_token_record(auth_token)
        pending_invite = get_session(conn, :pending_invite_token)
        pending_pairing = get_session(conn, :pending_pairing_token)

        redirect_to =
          cond do
            pending_pairing -> ~p"/telegram/pair?token=#{pending_pairing}"
            pending_invite -> ~p"/registries/join?token=#{pending_invite}"
            true -> ~p"/dashboard"
          end

        conn
        |> put_session(:user_id, user.id)
        |> delete_session(:pending_invite_token)
        |> delete_session(:pending_pairing_token)
        |> configure_session(renew: true)
        |> redirect(to: redirect_to)

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Invalid or expired link — please request a new one.")
        |> redirect(to: ~p"/login")
    end
  end

  def confirm(conn, _params) do
    conn
    |> redirect(to: ~p"/login")
  end

  @doc """
  DELETE /auth/logout — clears the session and redirects to /.
  """
  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end
end
