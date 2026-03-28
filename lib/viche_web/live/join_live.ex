defmodule VicheWeb.JoinLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       expired: false,
       hash: nil,
       agent_name: nil,
       token: nil,
       show_config: :json,
       copied: false
     )}
  end

  @impl true
  def handle_params(%{"hash" => hash}, _uri, socket) do
    if Regex.match?(~r/^[a-zA-Z0-9]{6,}$/, hash) do
      token =
        "viche_tk_#{hash}_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

      {:noreply,
       assign(socket,
         expired: false,
         hash: hash,
         agent_name: "my-agent-#{hash}",
         token: token
       )}
    else
      {:noreply, assign(socket, expired: true)}
    end
  end

  @impl true
  def handle_event("show_config", %{"format" => format}, socket) do
    {:noreply, assign(socket, show_config: String.to_atom(format))}
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
