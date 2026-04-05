defmodule VicheWeb.RegistryDetailLive do
  @moduledoc """
  LiveView for viewing a specific registry's details and well-known link.

  Shows the registry information and provides the customized well-known URL
  that agents can use to connect to this private network.
  """

  use VicheWeb, :live_view

  alias Viche.Agents
  alias Viche.Registries

  @impl true
  def mount(%{"id" => id}, session, socket) do
    user_id = session["user_id"]

    registry = Registries.get_registry(id)
    user_registries = if user_id, do: Registries.list_user_registries(user_id), else: []
    registry_tokens = Enum.map(user_registries, & &1.id)
    selected_registry = if registry, do: registry.id, else: "global"

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
       |> assign(:selected_registry, "global")
       |> assign(:registry_agent_count, 0)
       |> assign(:mobile_menu_open, false)
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
        |> assign(:selected_registry, selected_registry)
        |> assign(:registry_agent_count, registry_agent_count)
        |> assign(:mobile_menu_open, false)

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

  @impl true
  def handle_info(:reset_copied, socket) do
    {:noreply, assign(socket, :copied, false)}
  end
end
