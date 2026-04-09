defmodule VicheWeb.RegistryDetailLive do
  @moduledoc """
  LiveView for viewing a specific registry's details and well-known link.

  Shows the registry information and provides the customized well-known URL
  that agents can use to connect to this private network.
  """

  use VicheWeb, :live_view

  alias Viche.Agents
  alias Viche.Auth.Email
  alias Viche.Mailer
  alias Viche.Registries

  @impl true
  def mount(%{"id" => id}, session, socket) do
    user_id = session["user_id"]

    registry = Registries.get_registry(id)
    user_registries = if user_id, do: Registries.list_user_registries(user_id), else: []
    registry_tokens = Enum.map(user_registries, & &1.id)
    registry_names = Map.new(user_registries, fn r -> {r.id, r.name} end)
    selected_registry = if registry, do: registry.id, else: "global"

    agent_count = length(Agents.list_agents_with_status(:all))

    registry_agent_count =
      if registry do
        Agents.registry_agent_counts()
        |> Map.get(registry.id, 0)
      else
        0
      end

    # Authorization check - redirect non-owners
    if registry && registry.owner_id != user_id do
      {:ok,
       socket
       |> assign(:current_user_id, user_id)
       |> assign(:registry, nil)
       |> assign(:is_owner, false)
       |> assign(:copied, false)
       |> assign(:registry_tokens, registry_tokens)
       |> assign(:registry_names, registry_names)
       |> assign(:selected_registry, "global")
       |> assign(:agent_count, agent_count)
       |> assign(:registry_agent_count, 0)
       |> assign(:mobile_menu_open, false)
       |> assign(:show_invite_modal, false)
       |> put_flash(:error, "You don't have access to this registry")
       |> push_navigate(to: ~p"/registries")}
    else
      socket =
        socket
        |> assign(:current_user_id, user_id)
        |> assign(:registry, registry)
        |> assign(:is_owner, registry != nil)
        |> assign(:copied, false)
        |> assign(:registry_tokens, registry_tokens)
        |> assign(:registry_names, registry_names)
        |> assign(:selected_registry, selected_registry)
        |> assign(:agent_count, agent_count)
        |> assign(:registry_agent_count, registry_agent_count)
        |> assign(:mobile_menu_open, false)
        |> assign(:show_invite_modal, false)

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"id" => _id}, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("copy_url", _params, socket) do
    Process.send_after(self(), :reset_copied, 2000)
    {:noreply, assign(socket, :copied, true)}
  end

  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  def handle_event("navigate", %{"to" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("open_invite_modal", _params, socket) do
    {:noreply, assign(socket, :show_invite_modal, true)}
  end

  def handle_event("close_invite_modal", _params, socket) do
    {:noreply, assign(socket, :show_invite_modal, false)}
  end

  def handle_event("send_invitations", %{"emails" => raw_emails}, socket) do
    emails = parse_email_list(raw_emails)

    if emails == [] do
      {:noreply, put_flash(socket, :error, "Please enter at least one email address")}
    else
      ok_count =
        send_all_invitations(emails, socket.assigns.registry, socket.assigns.current_user_id)

      socket =
        socket
        |> assign(:show_invite_modal, false)
        |> put_flash(:info, "#{ok_count} invitation(s) sent successfully")

      {:noreply, socket}
    end
  end

  defp parse_email_list(raw) do
    raw
    |> String.split(~r/[,\n]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp send_all_invitations(emails, registry, invited_by_id) do
    Enum.count(emails, fn email ->
      case Registries.create_invitation(registry.id, invited_by_id, email) do
        {:ok, invitation} ->
          send_invitation_email(email, registry, invitation.token)
          true

        {:error, _} ->
          false
      end
    end)
  end

  defp send_invitation_email(email, registry, token) do
    Task.start(fn ->
      Email.registry_invitation(email, registry, token)
      |> Mailer.deliver()
    end)
  end

  @impl true
  def handle_info(:reset_copied, socket) do
    {:noreply, assign(socket, :copied, false)}
  end
end
