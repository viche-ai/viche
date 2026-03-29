defmodule VicheWeb.LoginLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{"email" => ""}, as: :login), state: :form),
     layout: false}
  end

  @impl true
  def handle_event("send_magic_link", %{"login" => %{"email" => email}}, socket) do
    email = String.trim(email)

    if valid_email?(email) do
      Viche.Auth.send_magic_link(email)
      {:noreply, assign(socket, state: :success)}
    else
      {:noreply,
       socket
       |> assign(form: to_form(%{"email" => email}, as: :login))
       |> put_flash(:error, "Please enter a valid email address")}
    end
  end

  defp valid_email?(email) do
    String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end
end
