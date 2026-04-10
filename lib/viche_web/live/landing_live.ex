defmodule VicheWeb.LandingLive do
  use VicheWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:app_url, Viche.Config.app_url())
      |> assign(:well_known_url, Viche.Config.well_known_url())
      |> assign(:host, Viche.Config.host())

    {:ok, socket, layout: false}
  end
end
