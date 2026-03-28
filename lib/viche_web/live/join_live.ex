defmodule VicheWeb.JoinLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    token = "viche_tk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    agent_name = "my-agent-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    {:ok,
     assign(socket,
       token: token,
       agent_name: agent_name,
       show_config: :json,
       copied: false
     )}
  end

  @impl true
  def handle_event("show_config", %{"format" => f}, socket) do
    {:noreply, assign(socket, show_config: String.to_atom(f))}
  end

  def handle_event("copy_config", _params, socket) do
    Process.send_after(self(), :reset_copied, 2000)
    {:noreply, assign(socket, copied: true)}
  end

  def handle_event("copied", _params, socket) do
    Process.send_after(self(), :reset_copied, 2000)
    {:noreply, assign(socket, copied: true)}
  end

  @impl true
  def handle_info(:reset_copied, socket) do
    {:noreply, assign(socket, copied: false)}
  end
end
