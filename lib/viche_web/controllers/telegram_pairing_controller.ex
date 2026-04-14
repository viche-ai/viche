defmodule VicheWeb.TelegramPairingController do
  use VicheWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias Viche.Telegram

  plug :fetch_current_user when action in [:create]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case Telegram.pairing_enabled?() do
      false ->
        conn
        |> put_flash(:error, "Telegram pairing is disabled on this Viche instance.")
        |> redirect(to: ~p"/dashboard")

      true ->
        case Telegram.get_valid_pairing(token) do
          {:ok, _pairing, link} ->
            maybe_render_pairing(conn, token, link)

          {:error, :invalid_token} ->
            conn
            |> put_flash(:error, "That Telegram pairing link is invalid or expired.")
            |> redirect(to: ~p"/dashboard")
        end
    end
  end

  def show(conn, _params) do
    conn
    |> put_flash(:error, "Missing pairing token.")
    |> redirect(to: ~p"/dashboard")
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"pairing" => %{"token" => token} = params}) do
    registry_ids = List.wrap(Map.get(params, "registry_ids", []))
    user = conn.assigns.current_user

    case Telegram.pairing_enabled?() do
      false ->
        conn
        |> put_flash(:error, "Telegram pairing is disabled on this Viche instance.")
        |> redirect(to: ~p"/dashboard")

      true ->
        case Telegram.pair_agent(token, user.id, registry_ids) do
          {:ok, %{joined_registries: joined}} ->
            conn
            |> put_flash(:info, success_message(length(joined)))
            |> redirect(to: ~p"/dashboard")

          {:error, :not_allowed_registry} ->
            conn
            |> put_flash(:error, "You can only select registries you own or belong to.")
            |> redirect(to: ~p"/telegram/pair?token=#{token}")

          {:error, :already_claimed} ->
            conn
            |> put_flash(:error, "That Telegram agent has already been claimed.")
            |> redirect(to: ~p"/dashboard")

          {:error, :invalid_token} ->
            conn
            |> put_flash(:error, "That Telegram pairing link is invalid or expired.")
            |> redirect(to: ~p"/dashboard")

          {:error, :agent_not_found} ->
            conn
            |> put_flash(:error, "The Telegram agent is no longer available.")
            |> redirect(to: ~p"/dashboard")
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid pairing request.")
    |> redirect(to: ~p"/dashboard")
  end

  defp maybe_render_pairing(conn, token, link) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> put_session(:pending_pairing_token, token)
        |> put_flash(:info, "Please log in to finish pairing your Telegram agent.")
        |> redirect(to: ~p"/login")

      user_id ->
        registries = Telegram.available_registries_for_user(user_id)
        form = to_form(%{"token" => token, "registry_ids" => []}, as: :pairing)

        render(conn, :show,
          form: form,
          registries: registries,
          link: link,
          token: token
        )
    end
  end

  defp fetch_current_user(conn, _opts) do
    cond do
      not Telegram.pairing_enabled?() ->
        conn
        |> put_flash(:error, "Telegram pairing is disabled on this Viche instance.")
        |> redirect(to: ~p"/dashboard")
        |> halt()

      Map.has_key?(conn.assigns, :current_user) ->
        conn

      true ->
        conn
        |> put_flash(:error, "You must be logged in to access that page.")
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end

  defp success_message(0), do: "Telegram agent paired and claimed successfully."

  defp success_message(count) do
    "Telegram agent paired, claimed, and joined #{count} registries."
  end
end
