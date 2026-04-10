defmodule VicheWeb.RegistriesLive do
  @moduledoc """
  LiveView for managing user's private registries.

  Allows logged-in users to create, view, and manage their private registries.
  """

  use VicheWeb, :live_view

  alias Viche.Agents
  alias Viche.Registries
  alias Viche.Registries.Registry

  @impl true
  def mount(_params, session, socket) do
    user_id = session["user_id"]

    socket =
      if user_id do
        registries = Registries.list_user_registries(user_id)
        registry_tokens = Enum.map(registries, & &1.id)
        agent_counts = Agents.registry_agent_counts()

        agent_count = length(Agents.list_agents_with_status(:all))

        registry_names = Map.new(registries, fn r -> {r.id, r.name} end)

        socket
        |> assign(:current_user_id, user_id)
        |> assign(:registries, registries)
        |> assign(:registry_tokens, registry_tokens)
        |> assign(:registry_names, registry_names)
        |> assign(:selected_registry, "global")
        |> assign(:agent_counts, agent_counts)
        |> assign(:agent_count, agent_count)
        |> assign(:show_create_modal, false)
        |> assign(:show_delete_modal, false)
        |> assign(:registry_to_delete, nil)
        |> assign(:form, to_form(Registry.changeset(%Registry{}, %{}), as: :registry))
        |> assign(:copied_id, nil)
        |> assign(:mobile_menu_open, false)
      else
        agent_count = length(Agents.list_agents_with_status(:all))

        socket
        |> assign(:current_user_id, nil)
        |> assign(:registries, [])
        |> assign(:registry_tokens, [])
        |> assign(:registry_names, %{})
        |> assign(:selected_registry, "global")
        |> assign(:agent_counts, %{})
        |> assign(:agent_count, agent_count)
        |> assign(:mobile_menu_open, false)
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: true)}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:form, to_form(Registry.changeset(%Registry{}, %{}), as: :registry))}
  end

  def handle_event("validate_create", %{"registry" => registry_params}, socket) do
    # phx-change sends all form fields, so we need to merge carefully
    # to preserve existing values when incoming params are empty strings
    existing_params =
      case socket.assigns.form do
        %Phoenix.HTML.Form{params: params} when is_map(params) -> params
        _ -> %{}
      end

    # Keep keys consistently as strings to avoid mixed-key maps
    merged_params =
      Map.merge(existing_params, registry_params, fn _key, existing, new ->
        if new in ["", nil], do: existing, else: new
      end)

    changeset =
      %Registry{}
      |> Registry.changeset(merged_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :registry))}
  end

  def handle_event("create_registry", %{"registry" => registry_params}, socket) do
    user_id = socket.assigns.current_user_id

    case Registries.create_registry(user_id, registry_params) do
      {:ok, _registry} ->
        registries = Registries.list_user_registries(user_id)
        registry_tokens = Enum.map(registries, & &1.id)
        agent_counts = Agents.registry_agent_counts()

        {:noreply,
         socket
         |> assign(:registries, registries)
         |> assign(:registry_tokens, registry_tokens)
         |> assign(:agent_counts, agent_counts)
         |> assign(:show_create_modal, false)
         |> put_flash(:info, "Registry created successfully!")
         |> assign(:form, to_form(Registry.changeset(%Registry{}, %{}), as: :registry))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: :registry))
         |> put_flash(:error, "Failed to create registry")}
    end
  end

  def handle_event("open_delete_modal", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, true)
     |> assign(:registry_to_delete, Registries.get_registry(id))}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:registry_to_delete, nil)}
  end

  def handle_event("delete_registry", %{"id" => id}, socket) do
    registry = Registries.get_user_registry(id, socket.assigns.current_user_id)

    case registry && Registries.delete_registry(registry) do
      {:ok, _} ->
        registries = Registries.list_user_registries(socket.assigns.current_user_id)
        registry_tokens = Enum.map(registries, & &1.id)
        agent_counts = Agents.registry_agent_counts()

        {:noreply,
         socket
         |> assign(:registries, registries)
         |> assign(:registry_tokens, registry_tokens)
         |> assign(:agent_counts, agent_counts)
         |> assign(:show_delete_modal, false)
         |> assign(:registry_to_delete, nil)
         |> put_flash(:info, "Registry deleted")}

      _ ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> assign(:registry_to_delete, nil)
         |> put_flash(:error, "Failed to delete registry")}
    end
  end

  def handle_event("copy_url", %{"id" => id}, socket) do
    Process.send_after(self(), :reset_copied, 2000)
    {:noreply, assign(socket, :copied_id, id)}
  end

  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  def handle_event("select_registry", %{"registry" => _registry}, socket) do
    # Registry selection is handled by parent LiveViews
    {:noreply, socket}
  end

  @impl true
  def handle_info(:reset_copied, socket) do
    {:noreply, assign(socket, :copied_id, nil)}
  end
end
