defmodule VicheWeb.SignupLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       step: 1,
       state: :form,
       name: "",
       email: "",
       username: "",
       usecase: nil,
       errors: %{}
     ), layout: false}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    case socket.assigns.step do
      1 ->
        errors = validate_step1(socket.assigns)

        if errors == %{} do
          {:noreply, assign(socket, step: 2, errors: %{})}
        else
          {:noreply, assign(socket, errors: errors)}
        end

      2 ->
        errors = validate_step2(socket.assigns)

        if errors == %{} do
          {:noreply, assign(socket, step: 3, errors: %{})}
        else
          {:noreply, assign(socket, errors: errors)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("prev_step", _params, socket) do
    {:noreply, assign(socket, step: max(1, socket.assigns.step - 1), errors: %{})}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply,
     assign(socket,
       name: params["name"] || socket.assigns.name,
       email: params["email"] || socket.assigns.email,
       username: params["username"] || socket.assigns.username
     )}
  end

  @impl true
  def handle_event("select_usecase", %{"value" => value}, socket) do
    {:noreply,
     assign(socket, usecase: value, errors: Map.delete(socket.assigns.errors, :usecase))}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    errors = validate_step3(socket.assigns)

    if errors != %{} do
      {:noreply, assign(socket, errors: errors)}
    else
      %{email: email, name: name, username: username} = socket.assigns
      attrs = %{name: String.trim(name), username: String.trim(username)}

      case Viche.Auth.send_magic_link(String.trim(email), attrs) do
        {:ok, _user} ->
          {:noreply, assign(socket, state: :success)}

        {:error, changeset} ->
          errors = changeset_to_errors(changeset)
          {:noreply, assign(socket, errors: errors)}
      end
    end
  end

  defp validate_step1(assigns) do
    errors = %{}
    name = String.trim(assigns.name)
    email = String.trim(assigns.email)

    errors = if name == "", do: Map.put(errors, :name, "Please enter your name"), else: errors

    errors =
      if String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/),
        do: errors,
        else: Map.put(errors, :email, "Please enter a valid email address")

    errors
  end

  defp validate_step2(assigns) do
    username = String.trim(assigns.username)

    if String.match?(username, ~r/^[a-zA-Z0-9_]{1,30}$/),
      do: %{},
      else: %{username: "Username must be 1-30 chars, letters/numbers/underscores only"}
  end

  defp validate_step3(assigns) do
    if is_nil(assigns.usecase),
      do: %{usecase: "Please select how you plan to use Viche"},
      else: %{}
  end

  defp changeset_to_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.into(%{}, fn {key, [msg | _]} -> {key, msg} end)
  end
end
