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
    if String.match?(hash, ~r/^[a-zA-Z0-9]{4,}$/) do
      token =
        case Viche.JoinTokens.get(hash) do
          {:ok, data} -> data.token
          _ -> Viche.JoinTokens.create(hash)
        end

      agent_name = "my-agent-#{hash}"

      {:noreply,
       assign(socket,
         expired: false,
         hash: hash,
         token: token,
         agent_name: agent_name,
         show_config: :json,
         copied: false
       )}
    else
      {:noreply,
       assign(socket,
         expired: true,
         hash: hash,
         token: nil,
         agent_name: nil,
         show_config: :json,
         copied: false
       )}
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
