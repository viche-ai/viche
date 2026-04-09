defmodule VicheWeb.SignupLive do
  use VicheWeb, :live_view

  alias Viche.Accounts
  alias Viche.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "metrics:messages")
      :timer.send_interval(10_000, :refresh_agents)
    end

    agents_online =
      Viche.Agents.list_agents_with_status()
      |> Enum.count(fn agent -> agent.status == :online end)

    changeset = User.changeset(%User{}, %{})

    {:ok,
     assign(socket,
       step: 1,
       state: :form,
       usecase: nil,
       usecase_error: nil,
       usecase_other_text: "",
       form: to_form(changeset, as: "user"),
       agents_online: agents_online,
       messages_today: Viche.MessageCounter.get()
     ), layout: false}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> User.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "user"))}
  end

  @impl true
  def handle_event("next_step", %{"user" => params}, socket) do
    changeset = User.changeset(%User{}, params)

    case socket.assigns.step do
      1 ->
        step_changeset = Ecto.Changeset.validate_required(changeset, [:name])

        if step1_valid?(step_changeset) do
          {:noreply, assign(socket, step: 2, form: to_form(changeset, as: "user"))}
        else
          {:noreply,
           assign(socket, form: to_form(%{step_changeset | action: :validate}, as: "user"))}
        end

      2 ->
        step_changeset = Ecto.Changeset.validate_required(changeset, [:username])

        username = Ecto.Changeset.get_change(step_changeset, :username)

        step_changeset =
          if username && !Keyword.has_key?(step_changeset.errors, :username) &&
               Accounts.username_taken?(username) do
            Ecto.Changeset.add_error(step_changeset, :username, "has already been taken")
          else
            step_changeset
          end

        if Keyword.has_key?(step_changeset.errors, :username) do
          {:noreply,
           assign(socket, form: to_form(%{step_changeset | action: :validate}, as: "user"))}
        else
          {:noreply, assign(socket, step: 3, form: to_form(changeset, as: "user"))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("prev_step", _params, socket) do
    {:noreply, assign(socket, step: max(1, socket.assigns.step - 1))}
  end

  @impl true
  def handle_event("select_usecase", %{"value" => value}, socket) do
    {:noreply, assign(socket, usecase: value, usecase_error: nil)}
  end

  @impl true
  def handle_event("set_usecase_other", %{"value" => v}, socket) do
    {:noreply, assign(socket, usecase_other_text: v)}
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    if is_nil(socket.assigns.usecase) do
      {:noreply, assign(socket, usecase_error: "Please select how you plan to use Viche")}
    else
      submit_signup(params, socket)
    end
  end

  defp submit_signup(params, socket) do
    email = String.trim(params["email"] || "") |> String.downcase()
    name = String.trim(params["name"] || "")
    username = String.trim(params["username"] || "")

    if Accounts.get_user_by_email(email) do
      changeset =
        %User{}
        |> User.changeset(params)
        |> Ecto.Changeset.add_error(
          :email,
          "An account with this email already exists, please log in."
        )
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, form: to_form(changeset, as: "user"), step: 1)}
    else
      case Viche.Auth.send_magic_link(email, %{name: name, username: username}) do
        {:ok, _user} ->
          {:noreply, assign(socket, state: :success)}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(%{changeset | action: :validate}, as: "user"))}
      end
    end
  end

  @impl true
  def handle_info({:messages_today, count}, socket) do
    {:noreply, assign(socket, messages_today: count)}
  end

  @impl true
  def handle_info(:refresh_agents, socket) do
    agents_online =
      Viche.Agents.list_agents_with_status()
      |> Enum.count(fn agent -> agent.status == :online end)

    {:noreply, assign(socket, agents_online: agents_online)}
  end

  defp step1_valid?(changeset) do
    !Keyword.has_key?(changeset.errors, :name) && !Keyword.has_key?(changeset.errors, :email)
  end
end
