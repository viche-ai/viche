defmodule VicheWeb.SettingsLive do
  use VicheWeb, :live_view

  @default_settings %{
    registry_url: "https://viche.fly.dev",
    namespace: "global",
    agent_prefix: "my-agent",
    require_auth: false,
    live_feed: true,
    animate_graph: true
  }

  @impl true
  def mount(_params, _session, socket) do
    agents = Viche.Agents.list_agents_with_status()
    online = Enum.count(agents, &(&1.status == :online))

    socket =
      socket
      |> assign(:settings, @default_settings)
      |> assign(:token, "viche_tk_demo_x9k2m4n7")
      |> assign(:show_token, false)
      |> assign(:dirty, false)
      |> assign(:connection_status, :idle)
      |> assign(:theme, :dark)
      |> assign(:danger_confirm, nil)
      |> assign(:agent_count, length(agents))
      |> assign(:online_count, online)
      |> assign(:session_count, 3)
      |> assign(:messages_today, 1247)

    {:ok, socket}
  end

  @impl true
  def handle_event("field_changed", %{"field" => f, "value" => v}, socket) do
    key = String.to_existing_atom(f)
    settings = Map.put(socket.assigns.settings, key, v)
    {:noreply, assign(socket, settings: settings, dirty: true)}
  end

  def handle_event("toggle_setting", %{"key" => k}, socket) do
    key = String.to_existing_atom(k)
    settings = Map.update!(socket.assigns.settings, key, &(!&1))
    {:noreply, assign(socket, settings: settings, dirty: true)}
  end

  def handle_event("toggle_token_visibility", _params, socket) do
    {:noreply, assign(socket, show_token: !socket.assigns.show_token)}
  end

  def handle_event("test_connection", _params, socket) do
    Process.send_after(self(), :connection_result, 1500)
    {:noreply, assign(socket, connection_status: :testing)}
  end

  def handle_event("save_settings", _params, socket) do
    {:noreply, assign(socket, dirty: false)}
  end

  def handle_event("discard_changes", _params, socket) do
    {:noreply, assign(socket, settings: @default_settings, dirty: false)}
  end

  def handle_event("confirm_danger", %{"action" => a}, socket) do
    {:noreply, assign(socket, danger_confirm: String.to_existing_atom(a))}
  end

  def handle_event("cancel_danger", _params, socket) do
    {:noreply, assign(socket, danger_confirm: nil)}
  end

  def handle_event("execute_danger", %{"action" => "clear"}, socket) do
    {:noreply, assign(socket, danger_confirm: nil)}
  end

  def handle_event("execute_danger", %{"action" => "reset"}, socket) do
    {:noreply, assign(socket, settings: @default_settings, dirty: false, danger_confirm: nil)}
  end

  def handle_event("select_theme", %{"theme" => t}, socket) do
    {:noreply, assign(socket, theme: String.to_existing_atom(t), dirty: true)}
  end

  @impl true
  def handle_info(:connection_result, socket) do
    Process.send_after(self(), :reset_connection, 3000)
    {:noreply, assign(socket, connection_status: :connected)}
  end

  def handle_info(:reset_connection, socket) do
    {:noreply, assign(socket, connection_status: :idle)}
  end
end
