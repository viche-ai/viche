defmodule VicheWeb.RegistryJoinController do
  use VicheWeb, :controller

  alias Viche.Registries

  @doc """
  GET /registries/join?token=<invite_token>

  Accepts a registry invitation. If the user is logged in, they are added
  as a member and redirected to the registry. If not, the token is stored
  in the session and the user is sent to login; after auth they are
  redirected back here automatically.
  """
  def join(conn, %{"token" => token}) do
    case Registries.get_invitation_by_token(token) do
      nil ->
        conn
        |> put_flash(:error, "This invitation link is invalid or has already been used.")
        |> redirect(to: ~p"/dashboard")

      invitation ->
        accept_or_redirect(conn, invitation, token)
    end
  end

  def join(conn, _params) do
    conn
    |> put_flash(:error, "Invalid invitation link.")
    |> redirect(to: ~p"/dashboard")
  end

  defp accept_or_redirect(conn, invitation, token) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> put_session(:pending_invite_token, token)
        |> put_flash(:info, "Please log in to accept the invitation.")
        |> redirect(to: ~p"/login")

      user_id ->
        accept_invitation(conn, invitation, user_id)
    end
  end

  defp accept_invitation(conn, invitation, user_id) do
    case Registries.accept_invitation(invitation, user_id) do
      {:ok, _member} ->
        conn
        |> delete_session(:pending_invite_token)
        |> put_flash(:info, "You've joined #{invitation.registry.name}!")
        |> redirect(to: ~p"/registries/#{invitation.registry_id}")

      {:error, _} ->
        conn
        |> put_flash(:info, "You're already a member of this registry.")
        |> redirect(to: ~p"/registries/#{invitation.registry_id}")
    end
  end
end
