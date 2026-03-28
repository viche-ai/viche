defmodule VicheWeb.DemoLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Viche.PubSub, "demo:joins")
      Process.send_after(self(), :fake_join, :rand.uniform(5000) + 5000)
    end

    {:ok, assign(socket, join_count: 0, qr_hash: "a8f3c2")}
  end

  @impl true
  def handle_info(:fake_join, socket) do
    count = socket.assigns.join_count

    if count < 50 do
      Process.send_after(self(), :fake_join, :rand.uniform(5000) + 4000)
      {:noreply, assign(socket, join_count: count + 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "new_join"}, socket) do
    {:noreply, assign(socket, join_count: socket.assigns.join_count + 1)}
  end
end
