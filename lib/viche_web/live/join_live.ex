defmodule VicheWeb.JoinLive do
  use VicheWeb, :live_view

  @registry_url "https://viche.ai/.well-known/agent-registry"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, copied: false, registry_url: @registry_url)}
  end

  @impl true
  def handle_event("copy", _params, socket) do
    Process.send_after(self(), :reset_copied, 2000)
    {:noreply, assign(socket, copied: true)}
  end

  @impl true
  def handle_info(:reset_copied, socket) do
    {:noreply, assign(socket, copied: false)}
  end
end
